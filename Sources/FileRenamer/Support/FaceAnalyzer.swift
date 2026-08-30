import CoreGraphics
import Foundation
import RenameKit
import Vision

struct FaceAnalysisCandidate: Sendable {
    let itemID: UUID
    let analysisURL: URL
}

struct AnalyzedFace: Identifiable, Sendable {
    let id: FaceDescriptorID
    let normalizedBoundingBox: CGRect
    let captureQuality: Float?
    let alignmentMethod: FaceAlignmentMethod?
    let eligibility: FaceEligibilityTier
    let ineligibilityReason: FaceIneligibilityReason?
    let embedding: FaceEmbedding?
}

struct FaceAnalysisBatch: Sendable {
    let facesByItemID: [UUID: [AnalyzedFace]]
    let unreadableItemIDs: Set<UUID>

    static let empty = FaceAnalysisBatch(facesByItemID: [:], unreadableItemIDs: [])
}

/// Performs all file access, Vision work, alignment, and embedding away from the
/// main actor. Matching and workspace presentation intentionally live elsewhere.
actor FaceAnalyzer {
    static let shared = FaceAnalyzer()

    private struct FileKey: Hashable {
        let path: String
        let size: Int64
        let modificationMilliseconds: Int64
    }

    private struct CacheKey: Hashable {
        let file: FileKey
        let eligibilityPolicy: FaceEligibilityPolicy
        let pipelineContract: FacePipelineContract
    }

    private struct CachedFace: Sendable {
        let normalizedBoundingBox: CGRect
        let captureQuality: Float?
        let alignmentMethod: FaceAlignmentMethod?
        let eligibility: FaceEligibilityTier
        let ineligibilityReason: FaceIneligibilityReason?
        let embedding: FaceEmbedding?
    }

    private struct DetectedFace {
        let observation: VNFaceObservation
        let captureQuality: Float?
    }

    private var cache: [CacheKey: [CachedFace]] = [:]
    private var loadedProvider: MobileFaceNetEmbedder?

    func analyze(
        candidates: [FaceAnalysisCandidate],
        eligibilityPolicy: FaceEligibilityPolicy
    ) throws -> FaceAnalysisBatch {
        try Task.checkCancellation()
        guard !candidates.isEmpty else { return .empty }

        let provider = try embeddingProvider()
        var facesByItemID: [UUID: [AnalyzedFace]] = [:]
        var unreadableItemIDs = Set<UUID>()
        var activeKeys = Set<CacheKey>()

        for (candidateIndex, candidate) in candidates.enumerated() {
            if candidateIndex.isMultiple(of: 8) { try Task.checkCancellation() }
            do {
                let (key, cachedFaces) = try withSecurityScopedAccess(to: candidate.analysisURL) {
                    let fileKey = try makeFileKey(for: candidate.analysisURL)
                    let cacheKey = CacheKey(
                        file: fileKey,
                        eligibilityPolicy: eligibilityPolicy,
                        pipelineContract: provider.contract
                    )
                    if let cached = cache[cacheKey] {
                        return (cacheKey, cached)
                    }
                    let analyzed = try analyzeFile(
                        at: candidate.analysisURL,
                        eligibilityPolicy: eligibilityPolicy,
                        provider: provider
                    )
                    cache[cacheKey] = analyzed
                    return (cacheKey, analyzed)
                }
                activeKeys.insert(key)
                facesByItemID[candidate.itemID] = cachedFaces.enumerated().map { index, face in
                    AnalyzedFace(
                        id: FaceDescriptorID(itemID: candidate.itemID, faceIndex: index),
                        normalizedBoundingBox: face.normalizedBoundingBox,
                        captureQuality: face.captureQuality,
                        alignmentMethod: face.alignmentMethod,
                        eligibility: face.eligibility,
                        ineligibilityReason: face.ineligibilityReason,
                        embedding: face.embedding
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                unreadableItemIDs.insert(candidate.itemID)
            }
        }

        pruneCache(keeping: activeKeys)
        return FaceAnalysisBatch(
            facesByItemID: facesByItemID,
            unreadableItemIDs: unreadableItemIDs
        )
    }

    func clearCache() {
        cache.removeAll()
    }

    private func analyzeFile(
        at url: URL,
        eligibilityPolicy: FaceEligibilityPolicy,
        provider: FaceEmbeddingProvider
    ) throws -> [CachedFace] {
        try Task.checkCancellation()
        let image = try FaceImageLoader.loadOrientedImage(at: url)
        let observations = try detectFaces(in: image)
        let imageSize = CGSize(width: image.width, height: image.height)

        return try observations.map { detectedFace in
            try Task.checkCancellation()
            let observation = detectedFace.observation
            let faceRect = FaceGeometry.imageRect(
                normalizedVisionRect: observation.boundingBox,
                imageSize: imageSize
            )
            let faceSide = min(faceRect.width, faceRect.height)
            guard let aligned = FaceAligner.align(image: image, observation: observation) else {
                return CachedFace(
                    normalizedBoundingBox: observation.boundingBox,
                    captureQuality: detectedFace.captureQuality,
                    alignmentMethod: nil,
                    eligibility: .displayOnly,
                    ineligibilityReason: .alignmentFailed,
                    embedding: nil
                )
            }

            let decision = eligibilityPolicy.decision(
                faceSide: faceSide,
                quality: detectedFace.captureQuality,
                hasFivePointAlignment: aligned.method == .fivePoint
            )
            guard decision.tier != .displayOnly else {
                return CachedFace(
                    normalizedBoundingBox: observation.boundingBox,
                    captureQuality: detectedFace.captureQuality,
                    alignmentMethod: aligned.method,
                    eligibility: decision.tier,
                    ineligibilityReason: decision.reason,
                    embedding: nil
                )
            }

            do {
                return CachedFace(
                    normalizedBoundingBox: observation.boundingBox,
                    captureQuality: detectedFace.captureQuality,
                    alignmentMethod: aligned.method,
                    eligibility: decision.tier,
                    ineligibilityReason: nil,
                    embedding: try provider.embedding(for: aligned.image)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return CachedFace(
                    normalizedBoundingBox: observation.boundingBox,
                    captureQuality: detectedFace.captureQuality,
                    alignmentMethod: aligned.method,
                    eligibility: .displayOnly,
                    ineligibilityReason: .embeddingFailed,
                    embedding: nil
                )
            }
        }
    }

    private func embeddingProvider() throws -> MobileFaceNetEmbedder {
        if let loadedProvider { return loadedProvider }
        let provider = try MobileFaceNetEmbedder()
        loadedProvider = provider
        return provider
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
            let capture = qualityResults.min {
                boundingBoxDistance($0.boundingBox, landmark.boundingBox)
                    < boundingBoxDistance($1.boundingBox, landmark.boundingBox)
            }
            return DetectedFace(
                observation: landmark,
                captureQuality: capture?.faceCaptureQuality
            )
        }
    }

    private func makeFileKey(for url: URL) throws -> FileKey {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return FileKey(
            path: url.standardizedFileURL.path,
            size: Int64(values.fileSize ?? 0),
            modificationMilliseconds: Int64(
                (values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1_000
            )
        )
    }

    private func withSecurityScopedAccess<T>(
        to url: URL,
        operation: () throws -> T
    ) throws -> T {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        return try operation()
    }

    private func boundingBoxDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.midX - rhs.midX) + abs(lhs.midY - rhs.midY)
            + abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
    }

    private func pruneCache(keeping keys: Set<CacheKey>) {
        guard cache.count > 2_000 else { return }
        cache = cache.filter { keys.contains($0.key) }
    }
}
