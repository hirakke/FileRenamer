import Foundation

/// Injected so validation can be unit tested without touching a real disk.
public protocol FileExistenceChecking: Sendable {
    func fileExists(at url: URL) -> Bool
}

/// Optional fast path: a validator can ask for all occupied destinations at once.
/// The default implementation scans each directory once instead of issuing one
/// filesystem query per file, which is especially important on network volumes.
public protocol BatchFileExistenceChecking: FileExistenceChecking {
    func existingFiles(at urls: [URL]) -> Set<URL>
}

public struct DefaultFileExistenceChecker: BatchFileExistenceChecking {
    public init() {}
    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func existingFiles(at urls: [URL]) -> Set<URL> {
        let grouped = Dictionary(grouping: urls) {
            $0.deletingLastPathComponent().standardizedFileURL.path
        }
        var existing = Set<URL>()
        existing.reserveCapacity(urls.count)

        for candidates in grouped.values {
            guard let first = candidates.first else { continue }
            // A directory listing wins for a batch, but is wasteful when only one or
            // two files are being renamed inside a very large folder.
            if candidates.count < 8 {
                for candidate in candidates where fileExists(at: candidate) {
                    existing.insert(candidate)
                }
                continue
            }
            let directory = first.deletingLastPathComponent()
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            ) else {
                for candidate in candidates where fileExists(at: candidate) {
                    existing.insert(candidate)
                }
                continue
            }

            let names = Set(children.map {
                $0.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
            })
            for candidate in candidates {
                let name = candidate.lastPathComponent
                    .precomposedStringWithCanonicalMapping
                    .lowercased()
                if names.contains(name) { existing.insert(candidate) }
            }
        }
        return existing
    }
}

/// Checks a batch of previews and stamps each one with `valid` / `warning` / `error`.
///
/// Runs over the whole batch at once because the interesting failures are relational:
/// two items resolving to the same name, or a name colliding with a file already on disk.
public struct RenameValidator: Sendable {
    private let existenceChecker: FileExistenceChecking

    public init(existenceChecker: FileExistenceChecking = DefaultFileExistenceChecker()) {
        self.existenceChecker = existenceChecker
    }

    public func validate(
        _ previews: [RenamePreview],
        checkExistingFiles: Bool = true
    ) -> [RenamePreview] {
        // APFS is case-insensitive by default and normalizes Unicode, so collisions
        // must be detected on a folded key, not on the raw string.
        var destinationCounts: [String: Int] = [:]
        for preview in previews {
            for operation in preview.operations {
                destinationCounts[Self.key(operation.destination), default: 0] += 1
            }
        }

        // Files that will vacate their current path, so a destination pointing at one
        // of them is not a real conflict — the two-phase executor handles the swap.
        var vacatedSources: Set<String> = []
        for preview in previews {
            for operation in preview.operations where !operation.isNoop {
                vacatedSources.insert(Self.key(operation.source))
            }
        }

        let occupiedDestinations: Set<String>
        if checkExistingFiles {
            let candidates = previews.flatMap(\.operations).filter {
                !$0.isNoop && !vacatedSources.contains(Self.key($0.destination))
            }.map(\.destination)
            if let batchChecker = existenceChecker as? any BatchFileExistenceChecking {
                occupiedDestinations = Set(batchChecker.existingFiles(at: candidates).map(Self.key))
            } else {
                occupiedDestinations = Set(candidates.filter(existenceChecker.fileExists).map(Self.key))
            }
        } else {
            occupiedDestinations = []
        }

        return previews.map { preview in
            var preview = preview
            preview.validation = validation(
                for: preview,
                destinationCounts: destinationCounts,
                vacatedSources: vacatedSources,
                occupiedDestinations: occupiedDestinations
            )
            return preview
        }
    }

    private func validation(
        for preview: RenamePreview,
        destinationCounts: [String: Int],
        vacatedSources: Set<String>,
        occupiedDestinations: Set<String>
    ) -> RenameValidation {
        let baseName = preview.proposedBaseName

        // MARK: hard errors
        if FileNameSanitizer.isReservedName(baseName) {
            return .error("ファイル名が空です")
        }
        if FileNameSanitizer.containsIllegalCharacters(baseName) {
            return .error("使用できない文字が含まれています（/ : は不可）")
        }
        for operation in preview.operations {
            let name = operation.destination.lastPathComponent
            if FileNameSanitizer.byteLength(name) > FileNameSanitizer.maximumNameLength {
                return .error("ファイル名が長すぎます（255バイトまで）")
            }
        }
        for operation in preview.operations {
            if destinationCounts[Self.key(operation.destination), default: 0] > 1 {
                return .error("変更後の名前が重複しています: \(operation.destination.lastPathComponent)")
            }
        }
        for operation in preview.operations where !operation.isNoop {
            let key = Self.key(operation.destination)
            if occupiedDestinations.contains(key), !vacatedSources.contains(key) {
                return .error("同名のファイルが既に存在します: \(operation.destination.lastPathComponent)")
            }
        }

        // MARK: warnings
        if baseName.hasPrefix(".") {
            return .warning("先頭がドットのため Finder で不可視になります")
        }
        if baseName.hasSuffix(" ") || baseName.hasSuffix(".") {
            return .warning("末尾の空白・ドットは扱いにくい名前です")
        }
        if FileNameSanitizer.containsDiscouragedCharacters(baseName) {
            return .warning("推奨されない文字が含まれています")
        }
        if let warning = preview.generationWarnings.first {
            return .warning(warning)
        }
        if preview.isUnchanged {
            return .warning("名前が変わりません")
        }
        return .valid
    }

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.path
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }
}
