import Foundation

/// A single filesystem move. The executor never sees anything but these.
public struct RenameOperation: Hashable, Sendable, Codable {
    public let source: URL
    public let destination: URL

    public init(source: URL, destination: URL) {
        self.source = source
        self.destination = destination
    }

    public var isNoop: Bool {
        source.standardizedFileURL == destination.standardizedFileURL
    }
}

public enum RenameValidation: Hashable, Sendable {
    case valid
    case warning(String)
    case error(String)

    public var isError: Bool { if case .error = self { return true } else { return false } }
    public var isWarning: Bool { if case .warning = self { return true } else { return false } }

    public var message: String? {
        switch self {
        case .valid: return nil
        case .warning(let m), .error(let m): return m
        }
    }
}

/// The computed result for one item. Produced by `RenameEngine`, consumed by the UI
/// and by `RenameExecutor`. Nothing here touches the filesystem.
public struct RenamePreview: Identifiable, Hashable, Sendable {
    public let itemID: UUID
    /// The number this item got from its position in the list, if the rule has a counter.
    public let counterValue: Int?
    /// New base name (no extension) shared by the primary and every companion.
    public let proposedBaseName: String
    public let operations: [RenameOperation]
    public let requiresContentProcessing: Bool
    public var generationWarnings: [String]
    public var validation: RenameValidation

    public var id: UUID { itemID }

    public init(
        itemID: UUID,
        counterValue: Int?,
        proposedBaseName: String,
        operations: [RenameOperation],
        requiresContentProcessing: Bool = false,
        generationWarnings: [String] = [],
        validation: RenameValidation = .valid
    ) {
        self.itemID = itemID
        self.counterValue = counterValue
        self.proposedBaseName = proposedBaseName
        self.operations = operations
        self.requiresContentProcessing = requiresContentProcessing
        self.generationWarnings = generationWarnings
        self.validation = validation
    }

    public var sourceURL: URL { operations.first?.source ?? URL(fileURLWithPath: "/") }
    public var destinationURL: URL { operations.first?.destination ?? sourceURL }
    public var proposedName: String { destinationURL.lastPathComponent }
    public var isUnchanged: Bool { operations.allSatisfy(\.isNoop) && !requiresContentProcessing }

    /// Moves that actually need to run.
    public var effectiveOperations: [RenameOperation] { operations.filter { !$0.isNoop } }
}

public extension Array where Element == RenamePreview {
    var hasErrors: Bool { contains { $0.validation.isError } }
    var warningCount: Int { filter { $0.validation.isWarning }.count }
    var errorCount: Int { filter { $0.validation.isError }.count }
    var changedCount: Int { filter { !$0.isUnchanged && !$0.validation.isError }.count }
}
