import Foundation

/// Undo/redo stack of rename transactions.
///
/// Kept as a plain value type so the app layer can own one and the tests can drive it
/// without a filesystem. Even if a future version drops Undo from the UI, the history
/// is still the audit trail of what was renamed to what.
public struct RenameHistory: Sendable, Codable {
    public private(set) var undoStack: [RenameTransaction] = []
    public private(set) var redoStack: [RenameTransaction] = []

    /// Bounded so a long session cannot grow without limit.
    public var limit: Int = 50

    public init() {}

    public init(
        undoStack: [RenameTransaction],
        redoStack: [RenameTransaction] = [],
        limit: Int = 50
    ) {
        self.undoStack = Array(undoStack.suffix(limit))
        self.redoStack = Array(redoStack.suffix(limit))
        self.limit = limit
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var lastTransaction: RenameTransaction? { undoStack.last }

    public mutating func record(_ transaction: RenameTransaction) {
        undoStack.append(transaction)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
    }

    /// Pops the transaction to undo. The caller performs the filesystem work and then
    /// calls `finishUndo`, so a failed undo does not lose the entry.
    public mutating func beginUndo() -> RenameTransaction? {
        undoStack.last
    }

    public mutating func finishUndo() {
        guard let transaction = undoStack.popLast() else { return }
        redoStack.append(transaction)
    }

    public mutating func beginRedo() -> RenameTransaction? {
        redoStack.last
    }

    public mutating func finishRedo() {
        guard let transaction = redoStack.popLast() else { return }
        undoStack.append(transaction)
    }

    public mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
