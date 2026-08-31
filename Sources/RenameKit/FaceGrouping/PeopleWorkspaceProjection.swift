import Foundation

public struct PeopleCandidateCluster: Identifiable, Hashable, Sendable {
    public let members: [FaceDescriptorID]

    public init(members: [FaceDescriptorID]) {
        self.members = members
    }

    public var id: String {
        members.map { "\($0.itemID.uuidString):\($0.faceIndex)" }
            .joined(separator: "|")
    }
}

public struct PeopleClassificationResult: Equatable, Sendable {
    public let faceIDsByItemID: [UUID: [FaceDescriptorID]]
    public let namedAssignments: [UUID: [FaceDescriptorID]]
    public let unnamedClusters: [PeopleCandidateCluster]
    public let unconfirmedFaceIDs: [FaceDescriptorID]

    public init(
        faceIDsByItemID: [UUID: [FaceDescriptorID]],
        namedAssignments: [UUID: [FaceDescriptorID]],
        unnamedClusters: [PeopleCandidateCluster],
        unconfirmedFaceIDs: [FaceDescriptorID]
    ) {
        self.faceIDsByItemID = faceIDsByItemID
        self.namedAssignments = namedAssignments
        self.unnamedClusters = unnamedClusters
        self.unconfirmedFaceIDs = unconfirmedFaceIDs
    }

    public static let empty = PeopleClassificationResult(
        faceIDsByItemID: [:],
        namedAssignments: [:],
        unnamedClusters: [],
        unconfirmedFaceIDs: []
    )
}

public enum PeopleGroupID: Hashable, Codable, Sendable {
    case person(UUID)
    case candidate(String)
}

public struct PeopleGroupProjection: Identifiable, Hashable, Sendable {
    public let id: PeopleGroupID
    public let displayName: String?
    public let faceIDs: [FaceDescriptorID]
    public let itemIDs: [UUID]
    public let representativeFaceID: FaceDescriptorID

    public init(
        id: PeopleGroupID,
        displayName: String?,
        faceIDs: [FaceDescriptorID],
        itemIDs: [UUID],
        representativeFaceID: FaceDescriptorID
    ) {
        self.id = id
        self.displayName = displayName
        self.faceIDs = faceIDs
        self.itemIDs = itemIDs
        self.representativeFaceID = representativeFaceID
    }
}

public struct UnconfirmedFaceProjection: Identifiable, Hashable, Sendable {
    public var id: FaceDescriptorID { faceID }
    public let faceID: FaceDescriptorID
    public let itemID: UUID

    public init(faceID: FaceDescriptorID) {
        self.faceID = faceID
        itemID = faceID.itemID
    }
}

public struct PeopleWorkspaceProjection: Equatable, Sendable {
    public let groups: [PeopleGroupProjection]
    public let unconfirmed: [UnconfirmedFaceProjection]

    public init(
        groups: [PeopleGroupProjection],
        unconfirmed: [UnconfirmedFaceProjection]
    ) {
        self.groups = groups
        self.unconfirmed = unconfirmed
    }

    public static let empty = PeopleWorkspaceProjection(groups: [], unconfirmed: [])

    public static func make(
        orderedItemIDs: [UUID],
        result: PeopleClassificationResult,
        people: [PersonProfileSnapshot]
    ) -> PeopleWorkspaceProjection {
        let orderedFaces = orderedItemIDs.flatMap { itemID in
            (result.faceIDsByItemID[itemID] ?? [])
                .sorted { $0.faceIndex < $1.faceIndex }
        }
        let rank = Dictionary(uniqueKeysWithValues: orderedFaces.enumerated().map {
            ($0.element, $0.offset)
        })
        let peopleByID = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })

        var groups: [PeopleGroupProjection] = []
        for (personID, assignments) in result.namedAssignments {
            if let group = makeGroup(
                id: .person(personID),
                displayName: peopleByID[personID]?.displayName,
                faceIDs: assignments,
                orderedItemIDs: orderedItemIDs,
                rank: rank
            ) {
                groups.append(group)
            }
        }
        for cluster in result.unnamedClusters where cluster.members.count >= 2 {
            if let group = makeGroup(
                id: .candidate(cluster.id),
                displayName: nil,
                faceIDs: cluster.members,
                orderedItemIDs: orderedItemIDs,
                rank: rank
            ) {
                groups.append(group)
            }
        }
        groups.sort { lhs, rhs in
            let leftRank = rank[lhs.representativeFaceID] ?? .max
            let rightRank = rank[rhs.representativeFaceID] ?? .max
            if leftRank != rightRank { return leftRank < rightRank }
            return stableID(lhs.id) < stableID(rhs.id)
        }

        let groupedFaceIDs = Set(groups.flatMap(\.faceIDs))
        var unconfirmedIDs = Set(result.unconfirmedFaceIDs)
        for faceID in orderedFaces where !groupedFaceIDs.contains(faceID) {
            unconfirmedIDs.insert(faceID)
        }
        let unconfirmed = orderedFaces.compactMap { faceID in
            unconfirmedIDs.contains(faceID)
                ? UnconfirmedFaceProjection(faceID: faceID)
                : nil
        }
        return PeopleWorkspaceProjection(groups: groups, unconfirmed: unconfirmed)
    }

    private static func makeGroup(
        id: PeopleGroupID,
        displayName: String?,
        faceIDs: [FaceDescriptorID],
        orderedItemIDs: [UUID],
        rank: [FaceDescriptorID: Int]
    ) -> PeopleGroupProjection? {
        var seenFaces = Set<FaceDescriptorID>()
        let orderedFaceIDs = faceIDs
            .filter { seenFaces.insert($0).inserted }
            .sorted {
                let leftRank = rank[$0] ?? .max
                let rightRank = rank[$1] ?? .max
                if leftRank != rightRank { return leftRank < rightRank }
                if $0.itemID != $1.itemID {
                    return $0.itemID.uuidString < $1.itemID.uuidString
                }
                return $0.faceIndex < $1.faceIndex
            }
        guard let representativeFaceID = orderedFaceIDs.first else { return nil }
        let includedItemIDs = Set(orderedFaceIDs.map(\.itemID))
        let itemIDs = orderedItemIDs.filter { includedItemIDs.contains($0) }
        return PeopleGroupProjection(
            id: id,
            displayName: displayName,
            faceIDs: orderedFaceIDs,
            itemIDs: itemIDs,
            representativeFaceID: representativeFaceID
        )
    }

    private static func stableID(_ id: PeopleGroupID) -> String {
        switch id {
        case let .person(personID): "person:\(personID.uuidString)"
        case let .candidate(candidateID): "candidate:\(candidateID)"
        }
    }
}
