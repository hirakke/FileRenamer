import Foundation
import RenameKit

extension AppModel {
    func similarityBadge(for itemID: UUID) -> SimilarityBadge? {
        guard let matches = similarImageMatchesByItemID[itemID], !matches.isEmpty else { return nil }
        return SimilarityBadge(
            count: matches.count,
            containsExactMatch: matches.contains { $0.kind == .exact }
        )
    }

    /// Connected components of the match graph, in list order.
    ///
    /// Rebuilt on demand rather than cached: the input is at most a few hundred
    /// items, and a stale group list would be far worse than a recomputation.
    var duplicateGroups: [DuplicateGroup] {
        guard !similarImageMatchesByItemID.isEmpty else { return [] }

        var parent: [UUID: UUID] = [:]
        func find(_ id: UUID) -> UUID {
            var root = id
            while let next = parent[root], next != root { root = next }
            // Path compression keeps repeated lookups flat.
            var cursor = id
            while let next = parent[cursor], next != root {
                parent[cursor] = root
                cursor = next
            }
            return root
        }
        func union(_ lhs: UUID, _ rhs: UUID) {
            let left = find(lhs)
            let right = find(rhs)
            guard left != right else { return }
            parent[left] = right
        }

        for (itemID, matches) in similarImageMatchesByItemID {
            parent[itemID] = parent[itemID] ?? itemID
            for match in matches {
                parent[match.otherItemID] = parent[match.otherItemID] ?? match.otherItemID
                union(itemID, match.otherItemID)
            }
        }

        // Walking `items` rather than the dictionary keeps groups, and the pictures
        // inside them, in the order the user already sees.
        var membersByRoot: [UUID: [RenameItem]] = [:]
        var rootOrder: [UUID] = []
        for item in items where parent[item.id] != nil {
            let root = find(item.id)
            if membersByRoot[root] == nil { rootOrder.append(root) }
            membersByRoot[root, default: []].append(item)
        }

        return rootOrder.compactMap { root in
            guard let members = membersByRoot[root], members.count > 1 else { return nil }
            let memberIDs = Set(members.map(\.id))
            let containsExact = members.contains { item in
                (similarImageMatchesByItemID[item.id] ?? []).contains {
                    $0.kind == .exact && memberIDs.contains($0.otherItemID)
                }
            }
            return DuplicateGroup(id: root, items: members, containsExactMatch: containsExact)
        }
    }

    var duplicateGroupCount: Int { duplicateGroups.count }

    /// True when at least one group is byte-identical rather than merely alike.
    /// Drives the colour of the aggregate badge: the stronger verdict wins.
    var hasExactDuplicates: Bool {
        similarImageMatchesByItemID.values.contains { matches in
            matches.contains { $0.kind == .exact }
        }
    }

    func showSimilarImages(for itemID: UUID) {
        let groups = duplicateGroups
        guard let focused = groups.first(where: { group in
            group.items.contains { $0.id == itemID }
        }) else { return }
        similarityReview = SimilarityReview(groups: groups, focusedGroupID: focused.id)
    }

    func showFirstSimilarImageGroup() {
        let groups = duplicateGroups
        guard let first = groups.first else { return }
        similarityReview = SimilarityReview(groups: groups, focusedGroupID: first.id)
    }
}
