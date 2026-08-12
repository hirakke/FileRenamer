import Foundation

/// One row in the file list — a *logical* item, not necessarily a single file.
///
/// A RAW + JPEG pair (`DSCF0001.RAF` + `DSCF0001.JPG`) is one `RenameItem` with the
/// RAW as `originalURL` and the JPEG in `companionURLs`; both get the same new base
/// name and keep their own extension. Grouping is optional — with it off every file
/// is its own item and `companionURLs` is empty.
public struct RenameItem: Identifiable, Hashable, Sendable {
    public let id: UUID

    /// The file the name and metadata are derived from.
    public let originalURL: URL
    /// Files that must follow the primary's new base name (RAW/JPEG sidecars, XMP, ...).
    public var companionURLs: [URL]

    /// Position in the list. This *is* the counter order — see `RenameEngine`.
    public var order: Int
    /// Pinned: `ItemSorter` keeps this item at its current index when re-sorting.
    public var isLocked: Bool

    public var metadata: FileMetadata

    public init(
        id: UUID = UUID(),
        originalURL: URL,
        companionURLs: [URL] = [],
        order: Int = 0,
        isLocked: Bool = false,
        metadata: FileMetadata = FileMetadata()
    ) {
        self.id = id
        self.originalURL = originalURL
        self.companionURLs = companionURLs
        self.order = order
        self.isLocked = isLocked
        self.metadata = metadata
    }

    /// Primary first, then companions.
    public var allURLs: [URL] { [originalURL] + companionURLs }

    public var directoryURL: URL { originalURL.deletingLastPathComponent() }

    /// File name without the extension. Never treat a URL as a plain string —
    /// go through these two accessors instead.
    public var baseName: String { originalURL.deletingPathExtension().lastPathComponent }
    public var fileExtension: String { originalURL.pathExtension }
    public var displayName: String { originalURL.lastPathComponent }

    /// `"RAF + JPG"` for a grouped item, `nil` for a single file.
    public var groupSummary: String? {
        guard !companionURLs.isEmpty else { return nil }
        let exts = allURLs.map { $0.pathExtension.uppercased() }.filter { !$0.isEmpty }
        return exts.joined(separator: " + ")
    }

    /// Best available date for a given source, with sensible fallbacks so a naming
    /// rule using `captureDate` still produces something for a PDF.
    public func date(for source: DateSource) -> Date? {
        switch source {
        case .capture:
            return metadata.captureDate ?? metadata.creationDate ?? metadata.modificationDate
        case .creation:
            return metadata.creationDate ?? metadata.modificationDate
        case .modification:
            return metadata.modificationDate ?? metadata.creationDate
        }
    }
}
