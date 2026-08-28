import CoreGraphics
import Foundation
import RenameKit
import Vision

struct FaceClassificationCandidate: Sendable {
    let itemID: UUID
    let analysisURL: URL
}

enum FaceEligibility: String, Hashable, Sendable {
    case embedded
    case tooSmall
    case lowCaptureQuality
    case alignmentFailed
    case embeddingFailed
}

struct ClassifiedFace: Identifiable, Sendable {
    let id: FaceDescriptorID
    let normalizedBoundingBox: CGRect
    let captureQuality: Float?
    let alignmentMethod: FaceAlignmentMethod?
    let eligibility: FaceEligibility
    let embedding: FaceEmbedding?
    let knownPersonMatch: PersonMatch?
}

struct FaceCandidateCluster: Identifiable, Hashable, Sendable {
    let members: [FaceDescriptorID]

    var id: String {
        members.map { "\($0.itemID.uuidString):\($0.faceIndex)" }.joined(separator: "|")
    }
}

struct OfflineFaceClassificationResult: Sendable {
    let facesByItemID: [UUID: [ClassifiedFace]]
    let unknownClusters: [FaceCandidateCluster]
    let unknownOutliers: [FaceDescriptorID]
    let unreadableItemIDs: Set<UUID>

    static let empty = OfflineFaceClassificationResult(
        facesByItemID: [:],
        unknownClusters: [],
        unknownOutliers: [],
        unreadableItemIDs: []
    )
}

struct OfflineFaceClassifierConfiguration: Sendable {
    let minimumFaceSide: CGFloat
    let minimumCaptureQuality: Float
    let knownPersonMaximumDistance: Float
    let clusterEpsilon: Float
    let clusterMinimumPoints: Int

    static let standard = OfflineFaceClassifierConfiguration(
        minimumFaceSide: 40,
        minimumCaptureQuality: 0.20,
        knownPersonMaximumDistance: 0.36,
        clusterEpsilon: 0.42,
        clusterMinimumPoints: 2
    )
}

/// A local-only actor separate from SimilarImageDetector and all file operations.
actor OfflineFaceClassifier {
    static let shared = OfflineFaceClassifier()

    private struct FileKey: Hashable {
        let path: String
        let size: Int64
        let modificationMilliseconds: Int64
    }

    private struct CachedFace: Sendable {
        let normalizedBoundingBox: CGRect
        let captureQuality: Float?
        let alignmentMethod: FaceAlignmentMethod?
        let eligibility: FaceEligibility
        let embedding: FaceEmbedding?
    }

    private struct CacheKey: Hashable {
        let file: FileKey
        let minimumFaceSide: CGFloat
        let minimumCaptureQuality: Float
    }

    private struct PreparedCandidate {
        let candidate: FaceClassificationCandidate
        let key: FileKey
    }

    private struct DetectedFace {
        let observation: VNFaceObservation
        let captureQuality: Float?
    }

    private var cache: [CacheKey: [CachedFace]] = [:]
    private var loadedEmbedder: MobileFaceNetEmbedder?

    func scan(
        candidates: [FaceClassificationCandidate],
        knownPeople: [PersonProfileSnapshot],
        configuration: OfflineFaceClassifierConfiguration
    ) throws -> OfflineFaceClassificationResult {
        try Task.checkCancellation()
        let prepared = candidates.compactMap(prepare)
        guard !prepared.isEmpty else { return .empty }

        let embedder = try embedder()
        var facesByItemID: [UUID: [ClassifiedFace]] = [:]
        var orderedFaces: [ClassifiedFace] = []
        var unreadable = Set<UUID>()
        for (candidateIndex, preparedCandidate) in prepared.enumerated() {
            if candidateIndex.isMultiple(of: 8) { try Task.checkCancellation() }
            do {
                let cachedFaces = try cachedFaces(
                    for: preparedCandidate,
                    configuration: configuration,
                    embedder: embedder
                )
                let classifiedFaces = try cachedFaces.enumerated().map {
                    faceIndex, face in
                    let knownMatch = try face.embedding.flatMap {
                        try bestKnownMatch(
                            for: $0,
                            people: knownPeople,
                            maximumDistance: configuration.knownPersonMaximumDistance
                        )
                    }
                    return ClassifiedFace(
                        id: FaceDescriptorID(
                            itemID: preparedCandidate.candidate.itemID,
                            faceIndex: faceIndex
                        ),
                        normalizedBoundingBox: face.normalizedBoundingBox,
                        captureQuality: face.captureQuality,
                        alignmentMethod: face.alignmentMethod,
                        eligibility: face.eligibility,
                        embedding: face.embedding,
                        knownPersonMatch: knownMatch
                    )
                }
                facesByItemID[preparedCandidate.candidate.itemID] = classifiedFaces
                orderedFaces.append(contentsOf: classifiedFaces)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                unreadable.insert(preparedCandidate.candidate.itemID)
            }
        }

        let unknown = orderedFaces
            .filter { $0.embedding != nil && $0.knownPersonMatch == nil }
        let distanceTable = try makeDistanceTable(unknown)
        let clustered = FaceDensityClusterer().cluster(
            ids: unknown.map(\.id),
            epsilon: configuration.clusterEpsilon,
            minimumPoints: configuration.clusterMinimumPoints,
            distances: distanceTable
        )
        pruneCache(keeping: Set(prepared.map(\.key)))
        return OfflineFaceClassificationResult(
            facesByItemID: facesByItemID,
            unknownClusters: clustered.clusters.map {
                FaceCandidateCluster(members: $0)
            },
            unknownOutliers: clustered.outliers,
            unreadableItemIDs: unreadable
        )
    }

    func clearCache() {
        cache.removeAll()
    }

    private func prepare(_ candidate: FaceClassificationCandidate) -> PreparedCandidate? {
        guard FileKinds.isImage(candidate.analysisURL),
              let values = try? candidate.analysisURL.resourceValues(
                  forKeys: [.fileSizeKey, .contentModificationDateKey]
              )
        else { return nil }
        return PreparedCandidate(
            candidate: candidate,
            key: FileKey(
                path: candidate.analysisURL.standardizedFileURL.path,
                size: Int64(values.fileSize ?? 0),
                modificationMilliseconds: Int64(
                    (values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1_000
                )
            )
        )
    }

    private func cachedFaces(
        for prepared: PreparedCandidate,
        configuration: OfflineFaceClassifierConfiguration,
        embedder: MobileFaceNetEmbedder
    ) throws -> [CachedFace] {
        let cacheKey = CacheKey(
            file: prepared.key,
            minimumFaceSide: configuration.minimumFaceSide,
            minimumCaptureQuality: configuration.minimumCaptureQuality
        )
        if let cached = cache[cacheKey] { return cached }
        try Task.checkCancellation()
        let image = try FaceImageLoader.loadOrientedImage(at: prepared.candidate.analysisURL)
        let observations = try detectFaces(in: image)
        let imageSize = CGSize(width: image.width, height: image.height)

        var result: [CachedFace] = []
        result.reserveCapacity(observations.count)
        for detectedFace in observations {
            try Task.checkCancellation()
            let observation = detectedFace.observation
            let faceRect = FaceGeometry.imageRect(
                normalizedVisionRect: observation.boundingBox,
                imageSize: imageSize
            )
            guard FaceGeometry.isLargeEnough(
                faceRect: faceRect,
                minimumSide: configuration.minimumFaceSide
            ) else {
                result.append(CachedFace(
                    normalizedBoundingBox: observation.boundingBox,
                    captureQuality: detectedFace.captureQuality,
                    alignmentMethod: nil,
                    eligibility: .tooSmall,
                    embedding: nil
                ))
                continue
            }
            if let quality = detectedFace.captureQuality,
               quality < configuration.minimumCaptureQuality {
                result.append(CachedFace(
                    normalizedBoundingBox: observation.boundingBox,
                    captureQuality: quality,
                    alignmentMethod: nil,
                    eligibility: .lowCaptureQuality,
                    embedding: nil
                ))
                continue
            }
            guard let aligned = FaceAligner.align(image: image, observation: observation) else {
                result.append(CachedFace(
                    normalizedBoundingBox: observation.boundingBox,
                    captureQuality: detectedFace.captureQuality,
                    alignmentMethod: nil,
                    eligibility: .alignmentFailed,
                    embedding: nil
                ))
                continue
            }
            do {
                result.append(CachedFace(
                    normalizedBoundingBox: observation.boundingBox,
                    captureQuality: detectedFace.captureQuality,
                    alignmentMethod: aligned.method,
                    eligibility: .embedded,
                    embedding: try embedder.embedding(for: aligned.image)
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result.append(CachedFace(
                    normalizedBoundingBox: observation.boundingBox,
                    captureQuality: detectedFace.captureQuality,
                    alignmentMethod: aligned.method,
                    eligibility: .embeddingFailed,
                    embedding: nil
                ))
            }
        }
        cache[cacheKey] = result
        return result
    }

    private func embedder() throws -> MobileFaceNetEmbedder {
        if let loadedEmbedder { return loadedEmbedder }
        let embedder = try MobileFaceNetEmbedder()
        loadedEmbedder = embedder
        return embedder
    }

    private func detectFaces(in image: CGImage) throws -> [DetectedFace] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let detection = VNDetectFaceRectanglesRequest()
        try handler.perform([detection])
        guard let detected = detection.results, !detected.isEmpty else { return [] }

        let landmarks = VNDetectFaceLandmarksRequest()
        landmarks.inputFaceObservations = detected
        let quality = VNDetectFaceCaptureQualityRequest()
        quality.inputFaceObservations = detected
        try handler.perform([landmarks, quality])

        let landmarkResults = landmarks.results ?? detected
        let qualityResults = quality.results ?? []
        return landmarkResults.map { landmark in
            let capture = qualityResults.min(by: {
                boundingBoxDistance($0.boundingBox, landmark.boundingBox)
                    < boundingBoxDistance($1.boundingBox, landmark.boundingBox)
            })
            return DetectedFace(
                observation: landmark,
                captureQuality: capture?.faceCaptureQuality
            )
        }
    }

    private func boundingBoxDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.midX - rhs.midX) + abs(lhs.midY - rhs.midY)
            + abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
    }

    private func bestKnownMatch(
        for embedding: FaceEmbedding,
        people: [PersonProfileSnapshot],
        maximumDistance: Float
    ) throws -> PersonMatch? {
        guard maximumDistance.isFinite, maximumDistance >= 0 else { return nil }
        var best: PersonMatch?
        for person in people where person.embedding.model == embedding.model {
            let distance = try embedding.cosineDistance(to: person.embedding)
            if distance <= maximumDistance, distance < (best?.distance ?? .infinity) {
                best = PersonMatch(person: person, distance: distance)
            }
        }
        return best
    }

    private func makeDistanceTable(
        _ faces: [ClassifiedFace]
    ) throws -> [FaceDescriptorPair: Float] {
        guard faces.count > 1 else { return [:] }
        var result: [FaceDescriptorPair: Float] = [:]
        for leftIndex in 0..<(faces.count - 1) {
            if leftIndex.isMultiple(of: 32) { try Task.checkCancellation() }
            for rightIndex in (leftIndex + 1)..<faces.count {
                guard let left = faces[leftIndex].embedding,
                      let right = faces[rightIndex].embedding
                else { continue }
                result[FaceDescriptorPair(faces[leftIndex].id, faces[rightIndex].id)]
                    = try left.cosineDistance(to: right)
            }
        }
        return result
    }

    private func pruneCache(keeping keys: Set<FileKey>) {
        guard cache.count > 2_000 else { return }
        cache = cache.filter { keys.contains($0.key.file) }
    }
}
