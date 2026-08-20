import Foundation

public struct TrashFailure: Sendable, Hashable {
    public let url: URL
    public let message: String

    public init(url: URL, message: String) {
        self.url = url
        self.message = message
    }
}

/// Records Finder's destination so a failed multi-file operation can be rolled back.
public struct TrashedFile: Sendable, Hashable {
    public let originalURL: URL
    public let trashURL: URL

    public init(originalURL: URL, trashURL: URL) {
        self.originalURL = originalURL
        self.trashURL = trashURL
    }
}

public struct TrashOutcome: Sendable {
    public let trashedFiles: [TrashedFile]
    public let failures: [TrashFailure]

    public init(trashedFiles: [TrashedFile] = [], failures: [TrashFailure] = []) {
        self.trashedFiles = trashedFiles
        self.failures = failures
    }

    public var trashedURLs: [URL] { trashedFiles.map(\.originalURL) }
    public var isEmpty: Bool { trashedFiles.isEmpty && failures.isEmpty }
}

/// File operations used by `FileTrasher`.
///
/// The production initializer uses Finder's Trash. Injection makes it possible to
/// exercise partial-failure rollback without moving test fixtures into the real Trash.
public struct FileTrashOperations: Sendable {
    public let fileExists: @Sendable (URL) -> Bool
    public let moveToTrash: @Sendable (URL) throws -> URL
    public let restore: @Sendable (URL, URL) throws -> Void

    public init(
        fileExists: @escaping @Sendable (URL) -> Bool,
        moveToTrash: @escaping @Sendable (URL) throws -> URL,
        restore: @escaping @Sendable (URL, URL) throws -> Void
    ) {
        self.fileExists = fileExists
        self.moveToTrash = moveToTrash
        self.restore = restore
    }

    public static let finderTrash = FileTrashOperations(
        fileExists: { FileManager.default.fileExists(atPath: $0.path) },
        moveToTrash: { url in
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            guard let resultingURL = resultingURL as URL? else {
                throw FileTrashError.missingTrashLocation(url)
            }
            return resultingURL
        },
        restore: { trashURL, originalURL in
            try FileManager.default.moveItem(at: trashURL, to: originalURL)
        }
    )
}

/// Moves selected files to Finder's Trash, preserving the integrity of each item.
///
/// A single item can contain companion files such as RAW + JPEG + XMP. The operation
/// treats that set as one unit: if one move fails, every file already moved for that
/// item is restored before the failure is reported. Different items can still proceed
/// independently, so one locked duplicate does not block the whole review.
public struct FileTrasher: Sendable {
    private let operations: FileTrashOperations

    public init() {
        operations = .finderTrash
    }

    public init(operations: FileTrashOperations) {
        self.operations = operations
    }

    public func moveToTrash(groups: [[URL]]) async -> TrashOutcome {
        let groups = groups.map(uniqued).filter { !$0.isEmpty }
        guard !groups.isEmpty else { return TrashOutcome() }

        return await Task.detached(priority: .userInitiated) {
            var trashedFiles: [TrashedFile] = []
            var failures: [TrashFailure] = []

            for group in groups {
                let result = moveGroupToTrash(group)
                trashedFiles.append(contentsOf: result.trashedFiles)
                failures.append(contentsOf: result.failures)
            }
            return TrashOutcome(trashedFiles: trashedFiles, failures: failures)
        }.value
    }

    private func moveGroupToTrash(_ urls: [URL]) -> TrashOutcome {
        let scopedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }

        var moved: [TrashedFile] = []
        for url in urls {
            // A file removed outside FileRenamer has already achieved the requested
            // end state. It must not prevent the remaining companions from leaving
            // the rename list.
            guard operations.fileExists(url) else { continue }

            do {
                moved.append(TrashedFile(
                    originalURL: url,
                    trashURL: try operations.moveToTrash(url)
                ))
            } catch {
                var failures = [TrashFailure(url: url, message: error.localizedDescription)]
                for movedFile in moved.reversed() {
                    do {
                        try operations.restore(movedFile.trashURL, movedFile.originalURL)
                    } catch {
                        failures.append(TrashFailure(
                            url: movedFile.originalURL,
                            message: "ゴミ箱から元の場所へ戻せませんでした: \(error.localizedDescription)"
                        ))
                    }
                }
                return TrashOutcome(failures: failures)
            }
        }
        return TrashOutcome(trashedFiles: moved)
    }

    private func uniqued(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

private enum FileTrashError: LocalizedError {
    case missingTrashLocation(URL)

    var errorDescription: String? {
        switch self {
        case .missingTrashLocation(let url):
            return "「\(url.lastPathComponent)」のゴミ箱内の場所を取得できませんでした。"
        }
    }
}
