import Foundation

public enum FacePrototypeSelector {
    public static func stableOrder(
        _ lhs: PersonEmbeddingSample,
        _ rhs: PersonEmbeddingSample
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    public static func select(
        existing: [PersonEmbeddingSample],
        adding: [PersonEmbeddingSample],
        limit: Int,
        nearDuplicateDistance: Float
    ) throws -> [PersonEmbeddingSample] {
        guard limit > 0 else { return [] }
        let ordered = (existing + adding).sorted(by: stableOrder)
        guard let first = ordered.first else { return [] }
        guard let incompatible = ordered.first(where: {
            $0.embedding.contract != first.embedding.contract
        }) else {
            return try retainDiverseSamples(
                ordered,
                limit: limit,
                nearDuplicateDistance: max(0, nearDuplicateDistance)
            )
        }
        throw FaceEmbeddingError.incompatiblePipelines(
            first.embedding.contract,
            incompatible.embedding.contract
        )
    }

    private static func retainDiverseSamples(
        _ ordered: [PersonEmbeddingSample],
        limit: Int,
        nearDuplicateDistance: Float
    ) throws -> [PersonEmbeddingSample] {
        var unique: [PersonEmbeddingSample] = []
        for sample in ordered {
            let isNearDuplicate = try unique.contains { retained in
                try sample.embedding.cosineDistance(to: retained.embedding)
                    < nearDuplicateDistance
            }
            if !isNearDuplicate { unique.append(sample) }
        }
        guard unique.count > limit else { return unique }

        var selected = [unique[0]]
        var remaining = Array(unique.dropFirst())
        while selected.count < limit, !remaining.isEmpty {
            var bestIndex = 0
            var bestMinimumDistance = -Float.infinity
            for (index, candidate) in remaining.enumerated() {
                let minimumDistance = try selected.reduce(Float.infinity) { partial, retained in
                    min(partial, try candidate.embedding.cosineDistance(to: retained.embedding))
                }
                if minimumDistance > bestMinimumDistance
                    || (minimumDistance == bestMinimumDistance
                        && stableOrder(candidate, remaining[bestIndex])) {
                    bestIndex = index
                    bestMinimumDistance = minimumDistance
                }
            }
            selected.append(remaining.remove(at: bestIndex))
        }
        return selected.sorted(by: stableOrder)
    }
}
