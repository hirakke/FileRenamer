import Foundation
import SwiftData

public enum PersonStoreError: Error, Equatable, Sendable {
    case emptyDisplayName
    case noEmbeddings
    case personNotFound(UUID)
}

private struct PersonStoreProfileArchive: Hashable, Sendable {
    let id: UUID
    let displayName: String
    let legacyEmbedding: FaceEmbedding
    let legacySampleCount: Int
    let schemaVersion: Int
    let positives: [PersonEmbeddingSample]
    let rejections: [PersonEmbeddingSample]
    let createdAt: Date
    let updatedAt: Date
}

public struct PersonStoreSnapshot: Hashable, Sendable {
    public let people: [PersonProfileSnapshot]
    fileprivate let archives: [PersonStoreProfileArchive]
}

/// Main-actor SwiftData gateway for the small, local-only named-person database.
/// Source URLs and face crops are intentionally absent from the schema.
@MainActor
public final class PersonStore {
    public static let positiveLimit = 12
    public static let rejectionLimit = 24
    public static let nearDuplicateDistance: Float = 0.02

    public let container: ModelContainer
    private let context: ModelContext

    public init(container: ModelContainer) {
        self.container = container
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    /// Creates the app-wide on-device store. CloudKit is explicitly disabled so
    /// named-person embeddings never leave this Mac through SwiftData syncing.
    public static func localPersistent() throws -> PersonStore {
        let schema = Schema([PersonProfile.self, PersonEmbeddingRecord.self])
        let configuration = ModelConfiguration(
            "NamedPeople",
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: schema,
            configurations: configuration
        )
        return PersonStore(container: container)
    }

    public func people() throws -> [PersonProfileSnapshot] {
        try profiles()
            .map { try $0.snapshot() }
            .sorted(by: Self.profileOrder)
    }

    @discardableResult
    public func createPerson(
        displayName: String,
        prototype: PersonEmbeddingSample,
        now: Date = Date()
    ) throws -> PersonProfileSnapshot {
        let name = try normalisedName(displayName)
        return try atomicMutation {
            let profile = PersonProfile(
                displayName: name,
                embedding: prototype.embedding,
                sampleCount: 1,
                createdAt: now,
                updatedAt: now
            )
            profile.schemaVersion = 2
            profile.positiveRecords = [
                PersonEmbeddingRecord(kind: .positive, sample: prototype)
            ]
            context.insert(profile)
            return try profile.snapshot()
        }
    }

    @discardableResult
    public func addPrototype(
        personID: UUID,
        sample: PersonEmbeddingSample,
        now: Date = Date()
    ) throws -> PersonProfileSnapshot {
        try atomicMutation {
            guard let profile = try profile(id: personID) else {
                throw PersonStoreError.personNotFound(personID)
            }
            let selected = try FacePrototypeSelector.select(
                existing: try profile.positiveRecords.map { try $0.sample() },
                adding: [sample],
                limit: Self.positiveLimit,
                nearDuplicateDistance: Self.nearDuplicateDistance
            )
            try replaceRecords(on: profile, kind: .positive, with: selected)
            if let first = selected.first {
                profile.copyLegacyColumns(from: first.embedding, sampleCount: selected.count)
                profile.schemaVersion = 2
            }
            profile.updatedAt = now
            return try profile.snapshot()
        }
    }

    @discardableResult
    public func addRejection(
        personID: UUID,
        sample: PersonEmbeddingSample,
        now: Date = Date()
    ) throws -> PersonProfileSnapshot {
        try atomicMutation {
            guard let profile = try profile(id: personID) else {
                throw PersonStoreError.personNotFound(personID)
            }
            let selected = try FacePrototypeSelector.select(
                existing: try profile.rejectionRecords.map { try $0.sample() },
                adding: [sample],
                limit: Self.rejectionLimit,
                nearDuplicateDistance: Self.nearDuplicateDistance
            )
            try replaceRecords(on: profile, kind: .rejection, with: selected)
            profile.updatedAt = now
            return try profile.snapshot()
        }
    }

    @discardableResult
    public func renamePerson(
        id: UUID,
        displayName: String,
        now: Date = Date()
    ) throws -> PersonProfileSnapshot {
        let name = try normalisedName(displayName)
        return try atomicMutation {
            guard let profile = try profile(id: id) else {
                throw PersonStoreError.personNotFound(id)
            }
            profile.displayName = name
            profile.updatedAt = now
            return try profile.snapshot()
        }
    }

    @discardableResult
    public func mergePeople(
        sourceIDs: Set<UUID>,
        destinationID: UUID,
        now: Date = Date()
    ) throws -> PersonProfileSnapshot {
        try atomicMutation {
            guard let destination = try profile(id: destinationID) else {
                throw PersonStoreError.personNotFound(destinationID)
            }
            let effectiveSourceIDs = sourceIDs.subtracting([destinationID])
            let sources = try effectiveSourceIDs.map { id in
                guard let source = try profile(id: id) else {
                    throw PersonStoreError.personNotFound(id)
                }
                return source
            }

            let positives = try FacePrototypeSelector.select(
                existing: try destination.positiveRecords.map { try $0.sample() },
                adding: try sources.flatMap { try $0.positiveRecords.map { try $0.sample() } },
                limit: Self.positiveLimit,
                nearDuplicateDistance: Self.nearDuplicateDistance
            )
            let rejections = try FacePrototypeSelector.select(
                existing: try destination.rejectionRecords.map { try $0.sample() },
                adding: try sources.flatMap { try $0.rejectionRecords.map { try $0.sample() } },
                limit: Self.rejectionLimit,
                nearDuplicateDistance: Self.nearDuplicateDistance
            )
            try replaceRecords(on: destination, kind: .positive, with: positives)
            try replaceRecords(on: destination, kind: .rejection, with: rejections)
            if let first = positives.first {
                destination.copyLegacyColumns(from: first.embedding, sampleCount: positives.count)
                destination.schemaVersion = 2
            }
            destination.updatedAt = now
            for source in sources { context.delete(source) }
            return try destination.snapshot()
        }
    }

    public func snapshot() throws -> PersonStoreSnapshot {
        let storedProfiles = try profiles()
        let archives = try storedProfiles.map { profile in
            PersonStoreProfileArchive(
                id: profile.id,
                displayName: profile.displayName,
                legacyEmbedding: try profile.legacyEmbedding(),
                legacySampleCount: profile.sampleCount,
                schemaVersion: profile.schemaVersion,
                positives: try profile.positiveRecords
                    .map { try $0.sample() }
                    .sorted(by: FacePrototypeSelector.stableOrder),
                rejections: try profile.rejectionRecords
                    .map { try $0.sample() }
                    .sorted(by: FacePrototypeSelector.stableOrder),
                createdAt: profile.createdAt,
                updatedAt: profile.updatedAt
            )
        }
        return PersonStoreSnapshot(
            people: try storedProfiles.map { try $0.snapshot() }.sorted(by: Self.profileOrder),
            archives: archives
        )
    }

    public func restore(_ snapshot: PersonStoreSnapshot) throws {
        try atomicMutation {
            for profile in try profiles() { context.delete(profile) }
            for archive in snapshot.archives {
                let profile = PersonProfile(
                    id: archive.id,
                    displayName: archive.displayName,
                    embedding: archive.legacyEmbedding,
                    sampleCount: archive.legacySampleCount,
                    createdAt: archive.createdAt,
                    updatedAt: archive.updatedAt
                )
                profile.schemaVersion = archive.schemaVersion
                profile.positiveRecords = archive.positives.map {
                    PersonEmbeddingRecord(kind: .positive, sample: $0)
                }
                profile.rejectionRecords = archive.rejections.map {
                    PersonEmbeddingRecord(kind: .rejection, sample: $0)
                }
                context.insert(profile)
            }
        }
    }

    // Compatibility entry point for the existing naming sheet while its UI is
    // migrated to explicit prototype actions.
    @discardableResult
    public func savePerson(
        displayName: String,
        embeddings: [FaceEmbedding],
        now: Date = Date()
    ) throws -> PersonProfileSnapshot {
        let name = try normalisedName(displayName)
        guard !embeddings.isEmpty else { throw PersonStoreError.noEmbeddings }
        let samples = embeddings.map {
            PersonEmbeddingSample(embedding: $0, captureQuality: nil, createdAt: now)
        }
        let selected = try FacePrototypeSelector.select(
            existing: [],
            adding: samples,
            limit: Self.positiveLimit,
            nearDuplicateDistance: Self.nearDuplicateDistance
        )
        guard let first = selected.first else { throw PersonStoreError.noEmbeddings }
        return try atomicMutation {
            let profile = PersonProfile(
                displayName: name,
                embedding: first.embedding,
                sampleCount: selected.count,
                createdAt: now,
                updatedAt: now
            )
            profile.schemaVersion = 2
            profile.positiveRecords = selected.map {
                PersonEmbeddingRecord(kind: .positive, sample: $0)
            }
            context.insert(profile)
            return try profile.snapshot()
        }
    }

    public func deletePerson(id: UUID) throws {
        try atomicMutation {
            guard let profile = try profile(id: id) else {
                throw PersonStoreError.personNotFound(id)
            }
            context.delete(profile)
        }
    }

    public func deleteAllPeople() throws {
        try atomicMutation {
            for profile in try profiles() { context.delete(profile) }
        }
    }

    public func bestMatch(
        for embedding: FaceEmbedding,
        maximumDistance: Float
    ) throws -> PersonMatch? {
        guard maximumDistance.isFinite, maximumDistance >= 0 else { return nil }
        var best: PersonMatch?
        for person in try people() {
            let compatible = person.positives.filter { $0.embedding.contract == embedding.contract }
            guard let distance = try compatible.map({
                try embedding.cosineDistance(to: $0.embedding)
            }).min(), distance <= maximumDistance,
                distance < (best?.distance ?? .infinity)
            else { continue }
            best = PersonMatch(person: person, distance: distance)
        }
        return best
    }

    private func replaceRecords(
        on profile: PersonProfile,
        kind: PersonEmbeddingKind,
        with samples: [PersonEmbeddingSample]
    ) throws {
        let current = kind == .positive ? profile.positiveRecords : profile.rejectionRecords
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let selectedIDs = Set(samples.map(\.id))
        for record in current where !selectedIDs.contains(record.id) {
            context.delete(record)
        }
        let records = samples.map { sample in
            currentByID[sample.id] ?? PersonEmbeddingRecord(kind: kind, sample: sample)
        }
        if kind == .positive {
            profile.positiveRecords = records
        } else {
            profile.rejectionRecords = records
        }
    }

    private func atomicMutation<T>(_ operation: () throws -> T) throws -> T {
        do {
            let result = try operation()
            try context.save()
            return result
        } catch {
            context.rollback()
            throw error
        }
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

    private static func profileOrder(
        _ lhs: PersonProfileSnapshot,
        _ rhs: PersonProfileSnapshot
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
