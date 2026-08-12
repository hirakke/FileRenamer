import Foundation

public struct ImportOptions: Hashable, Sendable {
    /// Treat `DSCF0001.RAF` + `DSCF0001.JPG` as one logical item.
    public var groupCompanionFiles: Bool
    /// Descend into sub-folders when a folder is dropped.
    public var recursive: Bool
    public var includeHiddenFiles: Bool

    public init(groupCompanionFiles: Bool = true, recursive: Bool = true, includeHiddenFiles: Bool = false) {
        self.groupCompanionFiles = groupCompanionFiles
        self.recursive = recursive
        self.includeHiddenFiles = includeHiddenFiles
    }

    public static let `default` = ImportOptions()
}

public struct ImportResult: Sendable {
    public var items: [RenameItem]
    /// Bundles/packages (.app, .rtfd, …) that were skipped rather than descended into.
    public var skippedPackages: [URL]

    public init(items: [RenameItem], skippedPackages: [URL] = []) {
        self.items = items
        self.skippedPackages = skippedPackages
    }
}

/// Expands dropped URLs into `RenameItem`s: walks folders, filters noise, groups
/// companion files and reads metadata. All of it off the main actor.
public struct FileImporter: Sendable {
    private let metadataLoader: MetadataLoader

    public init(metadataLoader: MetadataLoader = MetadataLoader()) {
        self.metadataLoader = metadataLoader
    }

    public func importItems(from urls: [URL], options: ImportOptions = .default) async throws -> ImportResult {
        let loader = metadataLoader
        let collectionTask = Task.detached(priority: .userInitiated) {
            try Self.collectFiles(from: urls, options: options)
        }
        let collection = try await withTaskCancellationHandler {
            try await collectionTask.value
        } onCancel: {
            collectionTask.cancel()
        }

        let groups = options.groupCompanionFiles
            ? Self.groupCompanions(collection.files)
            : collection.files.map { [$0] }
        let items = try await Self.loadItems(groups, loader: loader)
        let sorted = ItemSorter.sorted(items, by: SortDescriptorOption(field: .fileName, ascending: true))
        return ImportResult(items: sorted, skippedPackages: collection.skippedPackages)
    }

    // MARK: - Implementation

    private struct CollectedFiles: Sendable {
        var files: [URL]
        var skippedPackages: [URL]
    }

    private static func collectFiles(from urls: [URL], options: ImportOptions) throws -> CollectedFiles {
        var files: [URL] = []
        var skippedPackages: [URL] = []
        var seen = Set<String>()

        for url in urls {
            try Task.checkCancellation()
            try collect(url, options: options, files: &files, skipped: &skippedPackages, seen: &seen)
        }
        return CollectedFiles(files: files, skippedPackages: skippedPackages)
    }

    /// Metadata reads are independent and can be expensive for RAW files. Keep a
    /// small bounded pool so large imports are faster without flooding ImageIO.
    private static func loadItems(_ groups: [[URL]], loader: MetadataLoader) async throws -> [RenameItem] {
        let concurrency = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
        var iterator = groups.enumerated().makeIterator()
        var loaded: [(Int, RenameItem)] = []
        loaded.reserveCapacity(groups.count)

        try await withThrowingTaskGroup(of: (Int, RenameItem).self) { group in
            func enqueueNext() {
                guard let (index, urls) = iterator.next(), let primary = urls.first else { return }
                group.addTask {
                    try Task.checkCancellation()
                    return (
                        index,
                        RenameItem(
                            originalURL: primary,
                            companionURLs: Array(urls.dropFirst()),
                            metadata: loader.load(for: urls)
                        )
                    )
                }
            }

            for _ in 0..<min(concurrency, groups.count) { enqueueNext() }
            while let result = try await group.next() {
                loaded.append(result)
                enqueueNext()
            }
        }
        return loaded.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private static func collect(
        _ url: URL,
        options: ImportOptions,
        files: inout [URL],
        skipped: inout [URL],
        seen: inout Set<String>
    ) throws {
        try Task.checkCancellation()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return }

        // A package is a directory to the kernel but a document to the user. Renaming
        // its guts would break the document, so we never descend into one.
        if values.isPackage == true {
            skipped.append(url)
            return
        }

        if values.isDirectory == true {
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: Array(keys),
                options: options.includeHiddenFiles ? [] : [.skipsHiddenFiles]
            ) else { return }

            for case let child as URL in enumerator {
                try Task.checkCancellation()
                let childValues = try? child.resourceValues(forKeys: keys)
                if childValues?.isPackage == true {
                    skipped.append(child)
                    enumerator.skipDescendants()
                    continue
                }
                if childValues?.isDirectory == true {
                    if !options.recursive { enumerator.skipDescendants() }
                    continue
                }
                append(child, to: &files, seen: &seen, options: options)
            }
            return
        }

        append(url, to: &files, seen: &seen, options: options)
    }

    private static func append(_ url: URL, to files: inout [URL], seen: inout Set<String>, options: ImportOptions) {
        guard !FileKinds.isSystemNoise(url) else { return }
        if !options.includeHiddenFiles && url.lastPathComponent.hasPrefix(".") { return }
        let key = url.standardizedFileURL.path
        guard seen.insert(key).inserted else { return }
        files.append(url.standardizedFileURL)
    }

    /// Groups only legitimate photo companion sets. Merely sharing a base name is not
    /// enough: `report.pdf` and `report.jpg` must remain independent items.
    public static func groupCompanions(_ files: [URL]) -> [[URL]] {
        var groups: [String: [URL]] = [:]
        var order: [String] = []

        for url in files {
            let directory = url.deletingLastPathComponent().standardizedFileURL.path
            let base = url.deletingPathExtension().lastPathComponent
                .precomposedStringWithCanonicalMapping
                .lowercased()
            let key = directory + "\u{0}" + base
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(url)
        }

        return order.flatMap { key -> [[URL]] in
            guard let urls = groups[key], urls.count > 1 else {
                return groups[key].map { [$0] } ?? []
            }

            let images = urls.filter(FileKinds.isCompanionImage)
            let sidecars = urls.filter(FileKinds.isSidecar)
            let unrelated = urls.filter { !FileKinds.isCompanionImage($0) && !FileKinds.isSidecar($0) }
            let hasRAW = images.contains(where: FileKinds.isRAW)
            let shouldGroup = hasRAW || (!images.isEmpty && !sidecars.isEmpty)

            guard shouldGroup else { return urls.map { [$0] } }
            let companions = (images + sidecars).sorted {
                let lhs = FileKinds.groupPriority($0)
                let rhs = FileKinds.groupPriority($1)
                if lhs != rhs { return lhs < rhs }
                return $0.pathExtension.localizedStandardCompare($1.pathExtension) == .orderedAscending
            }
            return [companions] + unrelated.map { [$0] }
        }
    }
}
