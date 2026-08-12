import Foundation

/// Persists completed rename history separately from the crash-recovery journal.
/// Security-scoped bookmarks carried by each transaction allow Undo after relaunch.
public struct RenameHistoryStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    public static func defaultFileURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("FileRenamer", isDirectory: true)
            .appendingPathComponent("rename-history.json", isDirectory: false)
    }

    public func load() -> RenameHistory {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let history = try? decoder.decode(RenameHistory.self, from: data)
        else { return RenameHistory() }
        return history
    }

    public func save(_ history: RenameHistory) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(history).write(to: fileURL, options: .atomic)
    }
}
