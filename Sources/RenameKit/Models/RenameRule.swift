import Foundation

// MARK: - Token configurations

public struct TextConfiguration: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var value: String

    public init(id: UUID = UUID(), value: String = "") {
        self.id = id
        self.value = value
    }
}

public struct SeparatorConfiguration: Identifiable, Hashable, Sendable, Codable {
    /// The presets offered in the UI. Any other string is allowed too.
    public static let presets: [String] = ["_", "-", ".", " "]

    public var id: UUID
    public var value: String

    public init(id: UUID = UUID(), value: String = "_") {
        self.id = id
        self.value = value
    }
}

public enum CounterResetMode: String, CaseIterable, Hashable, Sendable, Codable {
    case never
    case folder
    case day

    public var displayName: String {
        switch self {
        case .never: return "リセットしない"
        case .folder: return "フォルダごと"
        case .day: return "日付ごと"
        }
    }
}

public struct CounterConfiguration: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var start: Int
    public var digits: Int
    public var step: Int
    public var resetMode: CounterResetMode

    public init(
        id: UUID = UUID(),
        start: Int = 1,
        digits: Int = 3,
        step: Int = 1,
        resetMode: CounterResetMode = .never
    ) {
        self.id = id
        self.start = start
        self.digits = digits
        self.step = step
        self.resetMode = resetMode
    }

    /// `index` is the zero-based position in the ordered item list.
    public func value(at index: Int) -> Int {
        start + index * max(step, 1)
    }

    public func formatted(at index: Int) -> String {
        let n = value(at: index)
        let digits = max(1, min(self.digits, 10))
        let magnitude = String(abs(n))
        let padded = magnitude.count >= digits
            ? magnitude
            : String(repeating: "0", count: digits - magnitude.count) + magnitude
        return n < 0 ? "-" + padded : padded
    }

    private enum CodingKeys: String, CodingKey { case id, start, digits, step, resetMode }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try values.decodeIfPresent(Int.self, forKey: .start) ?? 1
        digits = try values.decodeIfPresent(Int.self, forKey: .digits) ?? 3
        step = try values.decodeIfPresent(Int.self, forKey: .step) ?? 1
        resetMode = try values.decodeIfPresent(CounterResetMode.self, forKey: .resetMode) ?? .never
    }
}

public enum DateSource: String, CaseIterable, Hashable, Sendable, Codable {
    case creation
    case modification
    case capture

    public var displayName: String {
        switch self {
        case .creation: return "作成日"
        case .modification: return "更新日"
        case .capture: return "撮影日"
        }
    }
}

/// Presets only — the user never types a `yyyyMMdd` pattern unless they open the
/// custom field on purpose.
public enum DateFormatPreset: String, CaseIterable, Hashable, Sendable, Codable {
    case compact          // 20260808
    case dashed           // 2026-08-08
    case underscored      // 2026_08_08
    case shortCompact     // 260808
    case yearMonth        // 2026-08
    case year             // 2026
    case compactWithTime  // 20260808_143005
    case custom

    public var pattern: String {
        switch self {
        case .compact: return "yyyyMMdd"
        case .dashed: return "yyyy-MM-dd"
        case .underscored: return "yyyy_MM_dd"
        case .shortCompact: return "yyMMdd"
        case .yearMonth: return "yyyy-MM"
        case .year: return "yyyy"
        case .compactWithTime: return "yyyyMMdd_HHmmss"
        case .custom: return ""
        }
    }
}

public struct DateConfiguration: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var source: DateSource
    public var preset: DateFormatPreset
    public var customPattern: String

    public init(
        id: UUID = UUID(),
        source: DateSource = .creation,
        preset: DateFormatPreset = .compact,
        customPattern: String = "yyyyMMdd"
    ) {
        self.id = id
        self.source = source
        self.preset = preset
        self.customPattern = customPattern
    }

    public var pattern: String {
        preset == .custom ? customPattern : preset.pattern
    }
}

public enum CaseTransform: String, CaseIterable, Hashable, Sendable, Codable {
    case none
    case lowercase
    case uppercase

    public var displayName: String {
        switch self {
        case .none: return "そのまま"
        case .lowercase: return "小文字"
        case .uppercase: return "大文字"
        }
    }

    public func apply(_ string: String) -> String {
        switch self {
        case .none: return string
        case .lowercase: return string.lowercased()
        case .uppercase: return string.uppercased()
        }
    }
}

public struct OriginalNameConfiguration: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var transform: CaseTransform
    public var find: String
    public var replacement: String
    public var usesRegularExpression: Bool

    public init(
        id: UUID = UUID(),
        transform: CaseTransform = .none,
        find: String = "",
        replacement: String = "",
        usesRegularExpression: Bool = false
    ) {
        self.id = id
        self.transform = transform
        self.find = find
        self.replacement = replacement
        self.usesRegularExpression = usesRegularExpression
    }

    public func applying(to original: String) -> (value: String, warning: String?) {
        let transformed = transform.apply(original)
        guard !find.isEmpty else { return (transformed, nil) }
        if usesRegularExpression {
            do {
                let expression = try NSRegularExpression(pattern: find)
                let range = NSRange(transformed.startIndex..<transformed.endIndex, in: transformed)
                return (expression.stringByReplacingMatches(
                    in: transformed,
                    range: range,
                    withTemplate: replacement
                ), nil)
            } catch {
                return (transformed, "正規表現が正しくありません")
            }
        }
        return (transformed.replacingOccurrences(of: find, with: replacement), nil)
    }

    private enum CodingKeys: String, CodingKey {
        case id, transform, find, replacement, usesRegularExpression
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        transform = try values.decodeIfPresent(CaseTransform.self, forKey: .transform) ?? .none
        find = try values.decodeIfPresent(String.self, forKey: .find) ?? ""
        replacement = try values.decodeIfPresent(String.self, forKey: .replacement) ?? ""
        usesRegularExpression = try values.decodeIfPresent(Bool.self, forKey: .usesRegularExpression) ?? false
    }
}

public enum MetadataField: String, CaseIterable, Hashable, Sendable, Codable {
    case cameraModel
    case lensModel
    case iso
    case focalLength
    case aperture
    case dimensions

    public var displayName: String {
        switch self {
        case .cameraModel: return "カメラ機種"
        case .lensModel: return "レンズ"
        case .iso: return "ISO感度"
        case .focalLength: return "焦点距離"
        case .aperture: return "絞り値"
        case .dimensions: return "画像サイズ"
        }
    }
}

public struct MetadataConfiguration: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var field: MetadataField

    public init(id: UUID = UUID(), field: MetadataField = .cameraModel) {
        self.id = id
        self.field = field
    }
}

// MARK: - Token

/// One visual block in the naming rule builder.
public enum RenameToken: Identifiable, Hashable, Sendable, Codable {
    case text(TextConfiguration)
    case separator(SeparatorConfiguration)
    case counter(CounterConfiguration)
    case date(DateConfiguration)
    case originalName(OriginalNameConfiguration)
    case metadata(MetadataConfiguration)

    public var id: UUID {
        switch self {
        case .text(let c): return c.id
        case .separator(let c): return c.id
        case .counter(let c): return c.id
        case .date(let c): return c.id
        case .originalName(let c): return c.id
        case .metadata(let c): return c.id
        }
    }

    public var kindName: String {
        switch self {
        case .text: return "固定文字列"
        case .separator: return "区切り"
        case .counter: return "連番"
        case .date: return "日付"
        case .originalName: return "元の名前"
        case .metadata: return "写真情報"
        }
    }

    public var systemImageName: String {
        switch self {
        case .text: return "textformat"
        case .separator: return "minus"
        case .counter: return "number"
        case .date: return "calendar"
        case .originalName: return "doc.text"
        case .metadata: return "camera"
        }
    }

    /// What the block shows on its face in the rule bar.
    public var summary: String {
        switch self {
        case .text(let c):
            return c.value.isEmpty ? "（未入力）" : c.value
        case .separator(let c):
            return c.value == " " ? "space" : c.value
        case .counter(let c):
            return c.formatted(at: 0)
        case .date(let c):
            // Upper case reads as a placeholder; the real casing only matters to
            // DateFormatter.
            return "\(c.source.displayName) \(c.pattern.uppercased())"
        case .originalName(let c):
            return c.transform == .none ? "元の名前" : "元の名前 (\(c.transform.displayName))"
        case .metadata(let c):
            return c.field.displayName
        }
    }
}

// MARK: - Rule

public struct RenameRule: Hashable, Sendable, Codable {
    public var tokens: [RenameToken]
    /// Off by default: extensions are preserved verbatim (see the safety rules).
    public var extensionTransform: CaseTransform

    public init(tokens: [RenameToken] = [], extensionTransform: CaseTransform = .none) {
        self.tokens = tokens
        self.extensionTransform = extensionTransform
    }

    public var containsCounter: Bool {
        tokens.contains { if case .counter = $0 { return true } else { return false } }
    }

    /// `[日付] [_] [Event] [_] [001]`
    public static let `default` = RenameRule(tokens: [
        .date(DateConfiguration(source: .creation, preset: .compact)),
        .separator(SeparatorConfiguration(value: "_")),
        .text(TextConfiguration(value: "Event")),
        .separator(SeparatorConfiguration(value: "_")),
        .counter(CounterConfiguration(start: 1, digits: 3))
    ])
}
