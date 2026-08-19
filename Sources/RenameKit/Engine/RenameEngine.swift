import Foundation

/// Options that affect name generation but are not part of the naming rule itself.
public struct RenameOptions: Hashable, Sendable {
    /// Replace characters that are illegal in a file name instead of erroring out.
    public var sanitizeIllegalCharacters: Bool
    public var replacementCharacter: String
    /// Trim leading/trailing whitespace from the generated base name.
    public var trimWhitespace: Bool

    public init(
        sanitizeIllegalCharacters: Bool = true,
        replacementCharacter: String = "-",
        trimWhitespace: Bool = true
    ) {
        self.sanitizeIllegalCharacters = sanitizeIllegalCharacters
        self.replacementCharacter = replacementCharacter
        self.trimWhitespace = trimWhitespace
    }

    public static let `default` = RenameOptions()
}

/// Turns `[RenameItem] + RenameRule` into `[RenamePreview]`.
///
/// Pure and synchronous: no filesystem access, no UI types. The counter comes from
/// the item's index in the array it is handed — the caller's ordering *is* the
/// numbering, which is the whole point of the app.
public struct RenameEngine: Sendable {
    private let options: RenameOptions

    public init(options: RenameOptions = .default) {
        self.options = options
    }

    // DateFormatter is expensive to build; one per pattern per call is plenty.
    private final class FormatterCache {
        private var cache: [String: DateFormatter] = [:]
        func formatter(for pattern: String) -> DateFormatter {
            if let existing = cache[pattern] { return existing }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = pattern
            cache[pattern] = formatter
            return formatter
        }
    }

    /// - Parameter items: already in display order. Index 0 gets the first counter value.
    public func makePreviews(
        items: [RenameItem],
        rule: RenameRule,
        jpegQuality: JPEGQualitySetting = JPEGQualitySetting(),
        preservesJPEGAtMaximumQuality: Bool = true
    ) -> [RenamePreview] {
        let formatters = FormatterCache()
        var counterGroups: [UUID: [String: Int]] = [:]
        return items.enumerated().map { index, item in
            var counterIndices: [UUID: Int] = [:]
            for token in rule.tokens {
                guard case .counter(let config) = token else { continue }
                let key = counterGroupKey(for: item, mode: config.resetMode)
                let next = counterGroups[config.id, default: [:]][key, default: 0]
                counterIndices[config.id] = next
                counterGroups[config.id, default: [:]][key] = next + 1
            }
            return preview(
                for: item,
                at: index,
                rule: rule,
                jpegQuality: jpegQuality,
                preservesJPEGAtMaximumQuality: preservesJPEGAtMaximumQuality,
                formatters: formatters,
                counterIndices: counterIndices
            )
        }
    }

    private func preview(
        for item: RenameItem,
        at index: Int,
        rule: RenameRule,
        jpegQuality: JPEGQualitySetting,
        preservesJPEGAtMaximumQuality: Bool,
        formatters: FormatterCache,
        counterIndices: [UUID: Int]
    ) -> RenamePreview {
        var baseName = ""
        var counterValue: Int?
        var generationWarnings: [String] = []

        for token in rule.tokens {
            switch token {
            case .text(let config):
                baseName += config.value

            case .separator(let config):
                baseName += config.value

            case .counter(let config):
                let counterIndex = counterIndices[config.id] ?? index
                counterValue = config.value(at: counterIndex)
                baseName += config.formatted(at: counterIndex)

            case .date(let config):
                if let date = item.date(for: config.source), !config.pattern.isEmpty {
                    baseName += formatters.formatter(for: config.pattern).string(from: date)
                }
                if config.source == .capture,
                   item.metadata.captureDate == nil,
                   item.date(for: .capture) != nil {
                    generationWarnings.append("撮影日時がないため、ファイル日時を使用します")
                }

            case .originalName(let config):
                let result = config.applying(to: item.baseName)
                baseName += result.value
                if let warning = result.warning { generationWarnings.append(warning) }

            case .metadata(let config):
                if let value = metadataValue(config.field, from: item.metadata) {
                    baseName += value
                } else {
                    generationWarnings.append("\(config.field.displayName)を取得できません")
                }
            }
        }

        if options.trimWhitespace {
            baseName = baseName.trimmingCharacters(in: .whitespaces)
        }
        if options.sanitizeIllegalCharacters {
            baseName = FileNameSanitizer.sanitize(baseName, replacement: options.replacementCharacter)
        }

        let operations = item.allURLs.map { url -> RenameOperation in
            RenameOperation(source: url, destination: destination(for: url, baseName: baseName, rule: rule))
        }
        let requiresContentProcessing = item.allURLs.contains {
            rule.imageEditConfiguration(
                for: $0,
                jpegQuality: jpegQuality,
                preservesJPEGAtMaximumQuality: preservesJPEGAtMaximumQuality
            ) != nil
        }

        return RenamePreview(
            itemID: item.id,
            counterValue: counterValue,
            proposedBaseName: baseName,
            operations: operations,
            requiresContentProcessing: requiresContentProcessing,
            generationWarnings: generationWarnings
        )
    }

    private func counterGroupKey(for item: RenameItem, mode: CounterResetMode) -> String {
        switch mode {
        case .never:
            return "all"
        case .folder:
            return item.directoryURL.standardizedFileURL.path
                .precomposedStringWithCanonicalMapping
                .lowercased()
        case .day:
            guard let date = item.date(for: .capture) else { return "date-missing" }
            let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
            return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
        }
    }

    private func metadataValue(_ field: MetadataField, from metadata: FileMetadata) -> String? {
        switch field {
        case .cameraModel:
            return metadata.cameraModel
        case .lensModel:
            return metadata.lensModel
        case .iso:
            return metadata.iso.map { "ISO\($0)" }
        case .focalLength:
            return metadata.focalLength.map { String(format: "%gmm", $0) }
        case .aperture:
            return metadata.apertureFNumber.map { String(format: "f%g", $0) }
        case .dimensions:
            guard let width = metadata.pixelWidth, let height = metadata.pixelHeight else { return nil }
            return "\(width)x\(height)"
        }
    }

    private func destination(for url: URL, baseName: String, rule: RenameRule) -> URL {
        let outputExtension: String
        if FileKinds.isEditableImage(url), let converted = rule.imageOutputFormat.fileExtension {
            outputExtension = converted
        } else {
            outputExtension = url.pathExtension
        }
        let ext = rule.extensionTransform.apply(outputExtension)
        let directory = url.deletingLastPathComponent()
        let fileName = ext.isEmpty ? baseName : "\(baseName).\(ext)"
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }

}
