import Foundation

/// Persists user presets as JSON in Application Support.
///
/// A plain readable file rather than UserDefaults so a rule set can be copied
/// between machines, and so a broken file can be inspected or deleted by hand.
public struct RulePresetStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    public static func defaultFileURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("FileRenamer", isDirectory: true)
            .appendingPathComponent("rule-presets.json", isDirectory: false)
    }

    public struct LoadResult: Sendable {
        public var presets: [RenameRulePreset]
        public var recoveryMessage: String?
    }

    /// A corrupt file never prevents launch. It is copied aside for inspection and
    /// reported to the UI instead of silently looking like the user deleted presets.
    public func loadWithDiagnostics() -> LoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return LoadResult(presets: [], recoveryMessage: nil)
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let presets = try JSONDecoder().decode([RenameRulePreset].self, from: data)
            return LoadResult(presets: presets.filter { !$0.isBuiltIn }, recoveryMessage: nil)
        } catch {
            let formatter = ISO8601DateFormatter()
            let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent("rule-presets-corrupt-\(stamp).json")
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            return LoadResult(
                presets: [],
                recoveryMessage: "プリセットファイルを読み取れませんでした。壊れたデータは \(backup.lastPathComponent) に退避しました。"
            )
        }
    }

    public func load() -> [RenameRulePreset] {
        loadWithDiagnostics().presets
    }

    public func save(_ presets: [RenameRulePreset]) throws {
        let userPresets = presets.filter { !$0.isBuiltIn }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(userPresets)
        try data.write(to: fileURL, options: .atomic)
    }

    public func exportData(_ presets: [RenameRulePreset]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(presets.filter { !$0.isBuiltIn })
    }

    public func decodeImportedPresets(from data: Data) throws -> [RenameRulePreset] {
        try JSONDecoder().decode([RenameRulePreset].self, from: data)
            .filter { !$0.isBuiltIn }
    }
}
