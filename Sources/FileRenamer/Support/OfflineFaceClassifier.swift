import CoreGraphics
import Foundation
import RenameKit

typealias FaceClassificationCandidate = FaceAnalysisCandidate

struct ClassifiedFace: Identifiable, Sendable {
    let id: FaceDescriptorID
    let normalizedBoundingBox: CGRect
    let captureQuality: Float?
    let alignmentMethod: FaceAlignmentMethod?
    let eligibility: FaceEligibilityTier
    let ineligibilityReason: FaceIneligibilityReason?
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
    let eligibilityPolicy: FaceEligibilityPolicy
    let knownPersonMaximumDistance: Float
    let clusterEpsilon: Float
    let clusterMinimumPoints: Int

    init(sensitivity: FaceGroupingSensitivity) {
        let groupingPolicy = sensitivity.policy
        eligibilityPolicy = FaceEligibilityPolicy(sensitivity: sensitivity)
        knownPersonMaximumDistance = groupingPolicy.knownPersonMaximumDistance
        clusterEpsilon = groupingPolicy.clusterEpsilon
        clusterMinimumPoints = groupingPolicy.clusterMinimumPoints
    }

    static let standard = OfflineFaceClassifierConfiguration(sensitivity: .standard)
}

/// Orchestrates analysis and the current compatibility matcher. Vision, file
/// access, and embedding are isolated in `FaceAnalyzer`; matching moves to the
/// pure multi-prototype matcher in the next implementation phase.
actor OfflineFaceClassifier {
    static let shared = OfflineFaceClassifier()

    func scan(
        candidates: [FaceClassificationCandidate],
        knownPeople: [PersonProfileSnapshot],
        configuration: OfflineFaceClassifierConfiguration
    ) async throws -> OfflineFaceClassificationResult {
        let batch = try await FaceAnalyzer.shared.analyze(
            candidates: candidates,
            eligibilityPolicy: configuration.eligibilityPolicy
        )
        try Task.checkCancellation()

        var facesByItemID: [UUID: [ClassifiedFace]] = [:]
        var orderedFaces: [ClassifiedFace] = []
        for candidate in candidates {
            let analyzed = batch.facesByItemID[candidate.itemID] ?? []
            let classified = try analyzed.map { face in
                let match = try face.embedding.flatMap {
                    try bestKnownMatch(
                        for: $0,
                        people: knownPeople,
                        maximumDistance: configuration.knownPersonMaximumDistance
                    )
                }
                return ClassifiedFace(
                    id: face.id,
                    normalizedBoundingBox: face.normalizedBoundingBox,
                    captureQuality: face.captureQuality,
                    alignmentMethod: face.alignmentMethod,
                    eligibility: face.eligibility,
                    ineligibilityReason: face.ineligibilityReason,
                    embedding: face.embedding,
                    knownPersonMatch: match
                )
            }
            facesByItemID[candidate.itemID] = classified
            orderedFaces.append(contentsOf: classified)
        }

        let unknown = orderedFaces.filter { $0.embedding != nil && $0.knownPersonMatch == nil }
        let distances = try makeDistanceTable(unknown)
        let clustered = FaceDensityClusterer().cluster(
            ids: unknown.map(\.id),
            epsilon: configuration.clusterEpsilon,
            minimumPoints: configuration.clusterMinimumPoints,
            distances: distances
        )
        return OfflineFaceClassificationResult(
            facesByItemID: facesByItemID,
            unknownClusters: clustered.clusters.map(FaceCandidateCluster.init(members:)),
            unknownOutliers: clustered.outliers,
            unreadableItemIDs: batch.unreadableItemIDs
        )
    }

    func clearCache() async {
        await FaceAnalyzer.shared.clearCache()
    }

    private func bestKnownMatch(
        for embedding: FaceEmbedding,
        people: [PersonProfileSnapshot],
        maximumDistance: Float
    ) throws -> PersonMatch? {
        guard maximumDistance.isFinite, maximumDistance >= 0 else { return nil }
        var best: PersonMatch?
        for person in people where person.embedding.contract == embedding.contract {
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
                result[FaceDescriptorPair(faces[leftIndex].id, faces[rightIndex].id)] =
                    try left.cosineDistance(to: right)
            }
        }
        return result
    }
}
