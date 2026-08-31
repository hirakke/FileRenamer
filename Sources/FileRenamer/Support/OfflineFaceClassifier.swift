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
    let namedAssignments: [UUID: [FaceDescriptorID]]
    let unknownClusters: [FaceCandidateCluster]
    let unconfirmedFaceIDs: [FaceDescriptorID]
    let unreadableItemIDs: Set<UUID>

    static let empty = OfflineFaceClassificationResult(
        facesByItemID: [:],
        namedAssignments: [:],
        unknownClusters: [],
        unconfirmedFaceIDs: [],
        unreadableItemIDs: []
    )
}

struct OfflineFaceClassifierConfiguration: Sendable {
    let eligibilityPolicy: FaceEligibilityPolicy
    let matchingPolicy: FaceGroupingPolicy
    let clusterEpsilon: Float
    let clusterMinimumPoints: Int

    init(sensitivity: FaceGroupingSensitivity) {
        let groupingPolicy = sensitivity.policy
        eligibilityPolicy = FaceEligibilityPolicy(sensitivity: sensitivity)
        matchingPolicy = groupingPolicy
        clusterEpsilon = groupingPolicy.clusterEpsilon
        clusterMinimumPoints = groupingPolicy.clusterMinimumPoints
    }

    static let standard = OfflineFaceClassifierConfiguration(sensitivity: .standard)
}

/// Orchestrates local analysis, conservative known-person matching, and
/// cannot-link clustering without moving file or UI work onto this actor.
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

        let peopleByID = Dictionary(uniqueKeysWithValues: knownPeople.map { ($0.id, $0) })
        let matcher = PeopleMatcher(policy: configuration.matchingPolicy)
        var facesByItemID: [UUID: [ClassifiedFace]] = [:]
        var orderedFaces: [ClassifiedFace] = []
        var namedAssignments: [UUID: [FaceDescriptorID]] = [:]
        var ambiguousFaceIDs = Set<FaceDescriptorID>()
        var displayOnlyFaceIDs = Set<FaceDescriptorID>()
        for candidate in candidates {
            let analyzed = (batch.facesByItemID[candidate.itemID] ?? [])
                .sorted { $0.id.faceIndex < $1.id.faceIndex }
            var blockedPersonIDs = Set<UUID>()
            var classified: [ClassifiedFace] = []
            classified.reserveCapacity(analyzed.count)
            for face in analyzed {
                var match: PersonMatch?
                if let embedding = face.embedding,
                   face.eligibility != .displayOnly {
                    let decision = try matcher.decide(
                        embedding: embedding,
                        people: knownPeople,
                        blockedPersonIDs: blockedPersonIDs
                    )
                    switch decision {
                    case let .accepted(personID, score):
                        if let person = peopleByID[personID] {
                            match = PersonMatch(person: person, distance: score)
                            blockedPersonIDs.insert(personID)
                            namedAssignments[personID, default: []].append(face.id)
                        }
                    case .ambiguous:
                        ambiguousFaceIDs.insert(face.id)
                    case .unconfirmed:
                        break
                    }
                } else {
                    displayOnlyFaceIDs.insert(face.id)
                }
                classified.append(ClassifiedFace(
                    id: face.id,
                    normalizedBoundingBox: face.normalizedBoundingBox,
                    captureQuality: face.captureQuality,
                    alignmentMethod: face.alignmentMethod,
                    eligibility: face.eligibility,
                    ineligibilityReason: face.ineligibilityReason,
                    embedding: face.embedding,
                    knownPersonMatch: match
                ))
            }
            facesByItemID[candidate.itemID] = classified
            orderedFaces.append(contentsOf: classified)
        }

        let unknown = orderedFaces.filter {
            $0.eligibility != .displayOnly
                && $0.embedding != nil
                && $0.knownPersonMatch == nil
        }
        let distances = try makeDistanceTable(unknown)
        let cannotLink = makeSamePhotoCannotLinks(unknown)
        let clustered = FaceDensityClusterer().cluster(
            ids: unknown.map(\.id),
            epsilon: configuration.clusterEpsilon,
            minimumPoints: configuration.clusterMinimumPoints,
            distances: distances,
            cannotLink: cannotLink
        )
        let outlierIDs = Set(clustered.outliers)
        var seenUnconfirmed = Set<FaceDescriptorID>()
        let unconfirmedFaceIDs = orderedFaces.compactMap { face -> FaceDescriptorID? in
            let isUnconfirmed = displayOnlyFaceIDs.contains(face.id)
                || ambiguousFaceIDs.contains(face.id)
                || outlierIDs.contains(face.id)
            guard isUnconfirmed, seenUnconfirmed.insert(face.id).inserted else { return nil }
            return face.id
        }
        return OfflineFaceClassificationResult(
            facesByItemID: facesByItemID,
            namedAssignments: namedAssignments,
            unknownClusters: clustered.clusters.map(FaceCandidateCluster.init(members:)),
            unconfirmedFaceIDs: unconfirmedFaceIDs,
            unreadableItemIDs: batch.unreadableItemIDs
        )
    }

    func clearCache() async {
        await FaceAnalyzer.shared.clearCache()
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

    private func makeSamePhotoCannotLinks(
        _ faces: [ClassifiedFace]
    ) -> Set<FaceDescriptorPair> {
        var result = Set<FaceDescriptorPair>()
        for itemFaces in Dictionary(grouping: faces, by: { $0.id.itemID }).values
            where itemFaces.count > 1 {
            for leftIndex in 0..<(itemFaces.count - 1) {
                for rightIndex in (leftIndex + 1)..<itemFaces.count {
                    result.insert(FaceDescriptorPair(
                        itemFaces[leftIndex].id,
                        itemFaces[rightIndex].id
                    ))
                }
            }
        }
        return result
    }
}
