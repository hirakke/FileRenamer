import Foundation

public enum RenameJournalEntryState: String, Codable, Sendable {
    case planned
    case staged
    case finalized
}

public struct RenameJournalEntry: Codable, Hashable, Sendable {
    public let source: URL
    public let temporary: URL
    public let destination: URL
    public var state: RenameJournalEntryState

    public init(
        source: URL,
        temporary: URL,
        destination: URL,
        state: RenameJournalEntryState = .planned
    ) {
        self.source = source
        self.temporary = temporary
        self.destination = destination
        self.state = state
    }
}

public struct RenameJournal: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var entries: [RenameJournalEntry]
    public var accessBookmarks: [Data]
    public var isCommitted: Bool

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        entries: [RenameJournalEntry],
        accessBookmarks: [Data] = [],
        isCommitted: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.entries = entries
        self.accessBookmarks = accessBookmarks
        self.isCommitted = isCommitted
    }
}

public struct RenameRecoveryReport: Sendable {
    public var recoveredBatchCount: Int
    public var recoveredFileCount: Int
    public var unresolvedJournalIDs: [UUID]
    public var messages: [String]

    public init(
        recoveredBatchCount: Int = 0,
        recoveredFileCount: Int = 0,
        unresolvedJournalIDs: [UUID] = [],
        messages: [String] = []
    ) {
        self.recoveredBatchCount = recoveredBatchCount
        self.recoveredFileCount = recoveredFileCount
        self.unresolvedJournalIDs = unresolvedJournalIDs
        self.messages = messages
    }

    public var hasWork: Bool { recoveredBatchCount > 0 || !unresolvedJournalIDs.isEmpty }
    public var hasUnresolvedWork: Bool { !unresolvedJournalIDs.isEmpty }
}

/// Durable write-ahead records for rename batches.
///
/// A journal is stored before the first file move and updated after every successful
/// move. It is marked committed before deletion, so a harmless leftover record can
/// never cause a completed batch to be reverted on the next launch.
public struct RenameJournalStore: @unchecked Sendable {
    public let directoryURL: URL
    private let fileManager: FileManager

    public init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL()
        self.fileManager = fileManager
    }

    public static func defaultDirectoryURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("FileRenamer", isDirectory: true)
            .appendingPathComponent("RenameJournals", isDirectory: true)
    }

    public func save(_ journal: RenameJournal) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(journal).write(to: fileURL(for: journal.id), options: .atomic)
    }

    public func remove(id: UUID) throws {
        let url = fileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    public func loadAll() -> (journals: [RenameJournal], unreadableFiles: [URL]) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return ([], []) }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var journals: [RenameJournal] = []
        var unreadable: [URL] = []

        for url in urls where url.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: url)
                journals.append(try decoder.decode(RenameJournal.self, from: data))
            } catch {
                unreadable.append(url)
            }
        }
        return (journals.sorted { $0.createdAt < $1.createdAt }, unreadable)
    }

    private func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }
}
