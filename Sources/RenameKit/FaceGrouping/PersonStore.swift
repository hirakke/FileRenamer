import Foundation
import SwiftData

public enum PersonStoreError: Error, Equatable, Sendable {
    case emptyDisplayName
    case noEmbeddings
    case personNotFound(UUID)
}

/// Main-actor SwiftData gateway for the small, local-only named-person database.
///
/// Source URLs and face crops are intentionally absent from the schema.
@MainActor
public final class PersonStore {
    public let container: ModelContainer
    private let context: ModelContext

    public init(container: ModelContainer) {
        self.container = container
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    public func people() throws -> [PersonProfileSnapshot] {
        try profiles()
            .map { try $0.snapshot() }
            .sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.createdAt < $1.createdAt
            }
    }

    @discardableResult
    public func savePerson(
        displayName: String,
        embeddings: [FaceEmbedding],
        now: Date = Date()
    ) throws -> PersonProfileSnapshot {
        let name = try normalisedName(displayName)
        guard !embeddings.isEmpty else { throw PersonStoreError.noEmbeddings }
        let centroid = try FaceEmbedding.centroid(of: embeddings)
        let profile = PersonProfile(
            displayName: name,
            embedding: centroid,
            sampleCount: embeddings.count,
            createdAt: now,
            updatedAt: now
        )
        context.insert(profile)
        try context.save()
        return try profile.snapshot()
    }

    @discardableResult
    public func renamePerson(
        id: UUID,
        displayName: String,
        now: Date = Date()
    ) throws -> PersonProfileSnapshot {
        let name = try normalisedName(displayName)
        guard let profile = try profile(id: id) else {
            throw PersonStoreError.personNotFound(id)
        }
        profile.displayName = name
        profile.updatedAt = now
        try context.save()
        return try profile.snapshot()
    }

    public func deletePerson(id: UUID) throws {
        guard let profile = try profile(id: id) else {
            throw PersonStoreError.personNotFound(id)
        }
        context.delete(profile)
        try context.save()
    }

    public func deleteAllPeople() throws {
        for profile in try profiles() {
            context.delete(profile)
        }
        try context.save()
    }

    public func bestMatch(
        for embedding: FaceEmbedding,
        maximumDistance: Float
    ) throws -> PersonMatch? {
        guard maximumDistance.isFinite, maximumDistance >= 0 else { return nil }

        var best: PersonMatch?
        for person in try people() where person.embedding.model == embedding.model {
            let distance = try embedding.cosineDistance(to: person.embedding)
            guard distance <= maximumDistance,
                  distance < (best?.distance ?? .infinity)
            else { continue }
            best = PersonMatch(person: person, distance: distance)
        }
        return best
    }

    private func profiles() throws -> [PersonProfile] {
        try context.fetch(FetchDescriptor<PersonProfile>())
    }

    private func profile(id: UUID) throws -> PersonProfile? {
        try profiles().first { $0.id == id }
    }

    private func normalisedName(_ displayName: String) throws -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PersonStoreError.emptyDisplayName }
        return trimmed
    }
}
