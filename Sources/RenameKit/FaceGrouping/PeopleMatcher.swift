import Foundation

public struct PeopleMatchCandidate: Equatable, Hashable, Sendable {
    public let personID: UUID
    public let score: Float

    public init(personID: UUID, score: Float) {
        self.personID = personID
        self.score = score
    }
}

public enum PeopleMatchDecision: Equatable, Sendable {
    case accepted(personID: UUID, score: Float)
    case ambiguous(candidates: [PeopleMatchCandidate])
    case unconfirmed
}

/// Pure, conservative known-person matching. A close vector is evidence, not a
/// decision: prototype agreement, runner-up separation, rejections, and source-
/// photo constraints all have to agree before a name is accepted.
public struct PeopleMatcher: Sendable {
    public let policy: FaceGroupingPolicy

    public init(policy sensitivity: FaceGroupingSensitivity) {
        policy = sensitivity.policy
    }

    public init(policy: FaceGroupingPolicy) {
        self.policy = policy
    }

    public func decide(
        embedding: FaceEmbedding,
        people: [PersonProfileSnapshot],
        blockedPersonIDs: Set<UUID>
    ) throws -> PeopleMatchDecision {
        let scored = try people.compactMap { person -> ScoredPerson? in
            let compatiblePositives = person.positives.filter {
                $0.embedding.contract == embedding.contract
            }
            guard !compatiblePositives.isEmpty else { return nil }
            let distances = try compatiblePositives.map {
                try embedding.cosineDistance(to: $0.embedding)
            }.sorted()
            let nearest = distances.prefix(2)
            let score = nearest.reduce(0, +) / Float(nearest.count)
            let nearestRejection = try person.rejections
                .filter { $0.embedding.contract == embedding.contract }
                .map { try embedding.cosineDistance(to: $0.embedding) }
                .min()
            return ScoredPerson(
                candidate: PeopleMatchCandidate(personID: person.id, score: score),
                nearestRejection: nearestRejection
            )
        }.sorted(by: Self.scoreOrder)

        guard let best = scored.first,
              best.candidate.score <= policy.knownPersonMaximumDistance,
              !blockedPersonIDs.contains(best.candidate.personID),
              best.nearestRejection.map({ $0 > policy.rejectionMaximumDistance }) ?? true
        else { return .unconfirmed }

        if scored.count > 1 {
            let gap = scored[1].candidate.score - best.candidate.score
            if gap < policy.knownPersonAmbiguityMargin {
                let candidates = scored.prefix { scoredPerson in
                    scoredPerson.candidate.score - best.candidate.score
                        < policy.knownPersonAmbiguityMargin
                }.map(\.candidate)
                return .ambiguous(candidates: candidates)
            }
        }
        return .accepted(
            personID: best.candidate.personID,
            score: best.candidate.score
        )
    }

    private struct ScoredPerson {
        let candidate: PeopleMatchCandidate
        let nearestRejection: Float?
    }

    private static func scoreOrder(_ lhs: ScoredPerson, _ rhs: ScoredPerson) -> Bool {
        if lhs.candidate.score != rhs.candidate.score {
            return lhs.candidate.score < rhs.candidate.score
        }
        return lhs.candidate.personID.uuidString < rhs.candidate.personID.uuidString
    }
}
