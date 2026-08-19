import Foundation

/// A completed batch, kept so it can be undone. `moves` records what actually
/// happened on disk, in the order it happened.
public struct RenameTransaction: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public let date: Date
    public let moves: [RenameOperation]
    public let accessBookmarks: [Data]
    public let imageEdits: [ImageEditRecord]

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        moves: [RenameOperation],
        accessBookmarks: [Data] = [],
        imageEdits: [ImageEditRecord] = []
    ) {
        self.id = id
        self.date = date
        self.moves = moves
        self.accessBookmarks = accessBookmarks
        self.imageEdits = imageEdits
    }

    public var fileCount: Int { max(moves.count, imageEdits.count) }

    /// The transaction that puts everything back.
    public var inverted: RenameTransaction {
        RenameTransaction(moves: moves.reversed().map {
            RenameOperation(source: $0.destination, destination: $0.source)
        }, accessBookmarks: accessBookmarks, imageEdits: imageEdits)
    }

    public func addingImageEdits(_ edits: [ImageEditRecord]) -> RenameTransaction {
        RenameTransaction(
            id: id,
            date: date,
            moves: moves,
            accessBookmarks: accessBookmarks,
            imageEdits: edits
        )
    }

    private enum CodingKeys: String, CodingKey { case id, date, moves, accessBookmarks, imageEdits }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try values.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        moves = try values.decodeIfPresent([RenameOperation].self, forKey: .moves) ?? []
        accessBookmarks = try values.decodeIfPresent([Data].self, forKey: .accessBookmarks) ?? []
        imageEdits = try values.decodeIfPresent([ImageEditRecord].self, forKey: .imageEdits) ?? []
    }
}

public enum RenameExecutionError: Error, LocalizedError {
    case validationFailed(errorCount: Int)
    case nothingToDo
    case sourceMissing(URL)
    case destinationOccupied(URL)
    case moveFailed(source: URL, destination: URL, underlying: Error, rolledBack: Bool)

    public var errorDescription: String? {
        switch self {
        case .validationFailed(let count):
            return "\(count) 件のエラーがあるため実行できません。"
        case .nothingToDo:
            return "変更が必要なファイルがありません。"
        case .sourceMissing(let url):
            return "ファイルが見つかりません: \(url.lastPathComponent)"
        case .destinationOccupied(let url):
            return "変更後の名前が既に使われています: \(url.lastPathComponent)"
        case .moveFailed(let source, _, let underlying, let rolledBack):
            let suffix = rolledBack ? "変更は元に戻されました。" : "一部のファイルが元に戻せませんでした。"
            return "\(source.lastPathComponent) のリネームに失敗しました（\(underlying.localizedDescription)）。\(suffix)"
        }
    }
}

/// Performs the renames. Never opens, reads or writes file *contents* — only
/// `FileManager.moveItem`, which is a directory-entry operation.
///
/// Two phases, because a batch can legitimately ask for `A→B` and `B→A`:
///
///     original → .filerenamer-tmp-<uuid>.ext → final
///
/// Every move is journalled as it happens, so a failure anywhere can be unwound
/// step by step back to the starting state.
/// `@unchecked Sendable`: the only stored property is a `FileManager`, which is not
/// marked `Sendable` but is documented as thread-safe for the file operations used here.
public struct RenameExecutor: @unchecked Sendable {
    public typealias ProgressHandler = @Sendable (Double) -> Void

    private let fileManager: FileManager
    private let journalStore: RenameJournalStore

    public init(
        fileManager: FileManager = .default,
        journalStore: RenameJournalStore = RenameJournalStore()
    ) {
        self.fileManager = fileManager
        self.journalStore = journalStore
    }

    /// - Returns: a transaction describing the moves, for undo.
    public func execute(
        previews: [RenamePreview],
        accessBookmarks: [Data] = [],
        progress: ProgressHandler? = nil
    ) async throws -> RenameTransaction {
        let errorCount = previews.errorCount
        guard errorCount == 0 else { throw RenameExecutionError.validationFailed(errorCount: errorCount) }

        let operations = previews.flatMap(\.effectiveOperations)
        guard !operations.isEmpty else { throw RenameExecutionError.nothingToDo }

        let scopedURLs = Self.resolveSecurityScopedBookmarks(accessBookmarks)
        defer { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
        return try await run(
            operations: operations,
            accessBookmarks: accessBookmarks,
            progress: progress
        )
    }

    /// Re-applies a recorded transaction in reverse. Used by Undo.
    public func revert(
        _ transaction: RenameTransaction,
        progress: ProgressHandler? = nil
    ) async throws -> RenameTransaction {
        let operations = transaction.inverted.moves.filter { !$0.isNoop }
        guard !operations.isEmpty else { throw RenameExecutionError.nothingToDo }
        let scopedURLs = Self.resolveSecurityScopedBookmarks(transaction.accessBookmarks)
        defer { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
        return try await run(
            operations: operations,
            accessBookmarks: transaction.accessBookmarks,
            progress: progress
        )
    }

    // MARK: - Two-phase move

    private func run(
        operations: [RenameOperation],
        accessBookmarks: [Data],
        progress: ProgressHandler?
    ) async throws -> RenameTransaction {
        let fileManager = self.fileManager
        let journalStore = self.journalStore
        return try await Task.detached(priority: .userInitiated) {
            try Self.performTwoPhase(
                operations,
                accessBookmarks: accessBookmarks,
                fileManager: fileManager,
                journalStore: journalStore,
                progress: progress
            )
        }.value
    }

    private static func performTwoPhase(
        _ operations: [RenameOperation],
        accessBookmarks: [Data],
        fileManager: FileManager,
        journalStore: RenameJournalStore,
        progress: ProgressHandler?
    ) throws -> RenameTransaction {
        for operation in operations {
            guard fileManager.fileExists(atPath: operation.source.path) else {
                throw RenameExecutionError.sourceMissing(operation.source)
            }
        }

        let durableBookmarks = accessBookmarks.isEmpty
            ? makeSecurityScopedBookmarks(for: operations)
            : accessBookmarks
        var durableJournal = RenameJournal(
            entries: operations.map {
                RenameJournalEntry(
                    source: $0.source,
                    temporary: temporaryURL(for: $0.source),
                    destination: $0.destination
                )
            },
            accessBookmarks: durableBookmarks
        )
        try journalStore.save(durableJournal)

        // In-memory moves remain the fastest rollback path for ordinary I/O errors.
        var appliedMoves: [RenameOperation] = []
        let total = Double(operations.count * 2)

        func rollback() -> Bool {
            var fullyRestored = true
            for move in appliedMoves.reversed() {
                do {
                    if fileManager.fileExists(atPath: move.source.path) {
                        // If the destination still exists too, another file occupied the
                        // original path and this move was not actually restored.
                        if fileManager.fileExists(atPath: move.destination.path) {
                            fullyRestored = false
                        }
                        continue
                    }
                    try fileManager.moveItem(at: move.destination, to: move.source)
                } catch {
                    fullyRestored = false
                }
            }
            if fullyRestored {
                try? journalStore.remove(id: durableJournal.id)
            }
            return fullyRestored
        }

        // Phase 1: everything out of the way, into unique temporary names in the same
        // directory (same volume, so each move is a cheap rename).
        var staged: [(temporary: URL, operation: RenameOperation)] = []
        for (index, operation) in operations.enumerated() {
            let temporary = durableJournal.entries[index].temporary
            do {
                try fileManager.moveItem(at: operation.source, to: temporary)
                appliedMoves.append(RenameOperation(source: operation.source, destination: temporary))
                durableJournal.entries[index].state = .staged
                try journalStore.save(durableJournal)
                staged.append((temporary, operation))
                progress?(Double(index + 1) / total)
            } catch {
                let rolledBack = rollback()
                throw RenameExecutionError.moveFailed(
                    source: operation.source,
                    destination: temporary,
                    underlying: error,
                    rolledBack: rolledBack
                )
            }
        }

        // Phase 2: temporaries into their final names. By now every source path is
        // free, so an A↔B swap resolves without either file being clobbered.
        for (index, entry) in staged.enumerated() {
            let destination = entry.operation.destination
            do {
                guard !fileManager.fileExists(atPath: destination.path) else {
                    throw RenameExecutionError.destinationOccupied(destination)
                }
                try fileManager.moveItem(at: entry.temporary, to: destination)
                appliedMoves.append(RenameOperation(source: entry.temporary, destination: destination))
                durableJournal.entries[index].state = .finalized
                try journalStore.save(durableJournal)
                progress?(Double(operations.count + index + 1) / total)
            } catch {
                let rolledBack = rollback()
                if let executionError = error as? RenameExecutionError, !rolledBack {
                    throw executionError
                }
                throw RenameExecutionError.moveFailed(
                    source: entry.operation.source,
                    destination: destination,
                    underlying: error,
                    rolledBack: rolledBack
                )
            }
        }

        progress?(1.0)
        durableJournal.isCommitted = true
        do {
            try journalStore.save(durableJournal)
        } catch {
            let rolledBack = rollback()
            throw RenameExecutionError.moveFailed(
                source: operations[0].source,
                destination: operations[0].destination,
                underlying: error,
                rolledBack: rolledBack
            )
        }
        try? journalStore.remove(id: durableJournal.id)
        return RenameTransaction(moves: operations, accessBookmarks: durableBookmarks)
    }

    // MARK: - Crash recovery

    public func recoverPendingTransactions() async -> RenameRecoveryReport {
        let fileManager = self.fileManager
        let journalStore = self.journalStore
        return await Task.detached(priority: .userInitiated) {
            Self.recoverAll(fileManager: fileManager, journalStore: journalStore)
        }.value
    }

    private static func recoverAll(
        fileManager: FileManager,
        journalStore: RenameJournalStore
    ) -> RenameRecoveryReport {
        let loaded = journalStore.loadAll()
        var report = RenameRecoveryReport()
        if !loaded.unreadableFiles.isEmpty {
            report.messages.append("\(loaded.unreadableFiles.count) 件の復旧記録を読み取れませんでした。")
        }

        for journal in loaded.journals {
            if journal.isCommitted {
                try? journalStore.remove(id: journal.id)
                continue
            }

            let scopedURLs = resolveSecurityScopedBookmarks(journal.accessBookmarks)
            defer { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }

            do {
                let restored = try recover(journal, fileManager: fileManager)
                try journalStore.remove(id: journal.id)
                report.recoveredBatchCount += 1
                report.recoveredFileCount += restored
            } catch {
                report.unresolvedJournalIDs.append(journal.id)
                report.messages.append(error.localizedDescription)
            }
        }
        return report
    }

    private static func recover(_ journal: RenameJournal, fileManager: FileManager) throws -> Int {
        struct RecoveryMove {
            let current: URL
            let original: URL
            let temporary: URL
        }

        var moves: [RecoveryMove] = []
        for entry in journal.entries {
            let current: URL?
            switch entry.state {
            case .planned:
                if fileManager.fileExists(atPath: entry.source.path) { current = nil }
                else if fileManager.fileExists(atPath: entry.temporary.path) { current = entry.temporary }
                else if fileManager.fileExists(atPath: entry.destination.path) { current = entry.destination }
                else { throw RenameExecutionError.sourceMissing(entry.source) }
            case .staged:
                if fileManager.fileExists(atPath: entry.temporary.path) { current = entry.temporary }
                else if fileManager.fileExists(atPath: entry.source.path) { current = nil }
                else if fileManager.fileExists(atPath: entry.destination.path) { current = entry.destination }
                else { throw RenameExecutionError.sourceMissing(entry.source) }
            case .finalized:
                if fileManager.fileExists(atPath: entry.destination.path) { current = entry.destination }
                else if fileManager.fileExists(atPath: entry.source.path) { current = nil }
                else if fileManager.fileExists(atPath: entry.temporary.path) { current = entry.temporary }
                else { throw RenameExecutionError.sourceMissing(entry.source) }
            }

            if let current {
                let temporary = temporaryURL(for: current, prefix: ".filerenamer-recovery-")
                moves.append(RecoveryMove(current: current, original: entry.source, temporary: temporary))
            }
        }

        // Move every surviving file out of the namespace first. This also recovers
        // completed A↔B swaps without either original path blocking the other.
        var staged: [RecoveryMove] = []
        for move in moves {
            try fileManager.moveItem(at: move.current, to: move.temporary)
            staged.append(move)
        }

        do {
            for move in staged {
                guard !fileManager.fileExists(atPath: move.original.path) else {
                    throw RenameExecutionError.destinationOccupied(move.original)
                }
                try fileManager.moveItem(at: move.temporary, to: move.original)
            }
        } catch {
            // Best effort: put files back where recovery found them.
            for move in staged.reversed() where fileManager.fileExists(atPath: move.temporary.path) {
                try? fileManager.moveItem(at: move.temporary, to: move.current)
            }
            throw error
        }
        return moves.count
    }

    private static func makeSecurityScopedBookmarks(for operations: [RenameOperation]) -> [Data] {
        var seen = Set<String>()
        return operations.compactMap { operation in
            let url = operation.source
            guard seen.insert(url.standardizedFileURL.path).inserted else { return nil }
            return try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
    }

    private static func resolveSecurityScopedBookmarks(_ bookmarks: [Data]) -> [URL] {
        bookmarks.compactMap { data in
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), url.startAccessingSecurityScopedResource() else { return nil }
            return url
        }
    }

    /// Hidden (leading dot) and UUID-suffixed so it cannot collide with a real file
    /// or with another temporary in the same batch.
    static func temporaryURL(for source: URL, prefix: String = ".filerenamer-tmp-") -> URL {
        let ext = source.pathExtension
        let name = "\(prefix)\(UUID().uuidString)"
        let fileName = ext.isEmpty ? name : "\(name).\(ext)"
        return source.deletingLastPathComponent().appendingPathComponent(fileName, isDirectory: false)
    }
}
