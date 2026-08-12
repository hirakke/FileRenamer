import Foundation

/// A saved naming rule.
///
/// `RenameRule` is already `Codable`, so a preset is just a name attached to one.
/// Built-in presets are not persisted — they are recreated on every launch so they
/// can be improved in a later version without migrating anyone's file.
public struct RenameRulePreset: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var name: String
    public var rule: RenameRule
    public var isBuiltIn: Bool

    public init(id: UUID = UUID(), name: String, rule: RenameRule, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.rule = rule
        self.isBuiltIn = isBuiltIn
    }

    /// Ready-made starting points covering the common photo/document workflows.
    public static let builtIns: [RenameRulePreset] = [
        RenameRulePreset(
            name: "日付 + イベント名 + 連番",
            rule: RenameRule(tokens: [
                .date(DateConfiguration(source: .capture, preset: .compact)),
                .separator(SeparatorConfiguration(value: "_")),
                .text(TextConfiguration(value: "Event")),
                .separator(SeparatorConfiguration(value: "_")),
                .counter(CounterConfiguration(start: 1, digits: 3))
            ]),
            isBuiltIn: true
        ),
        RenameRulePreset(
            name: "イベント名 + 連番",
            rule: RenameRule(tokens: [
                .text(TextConfiguration(value: "Event")),
                .separator(SeparatorConfiguration(value: "_")),
                .counter(CounterConfiguration(start: 1, digits: 3))
            ]),
            isBuiltIn: true
        ),
        RenameRulePreset(
            name: "日付 + 連番",
            rule: RenameRule(tokens: [
                .date(DateConfiguration(source: .capture, preset: .dashed)),
                .separator(SeparatorConfiguration(value: "_")),
                .counter(CounterConfiguration(start: 1, digits: 3))
            ]),
            isBuiltIn: true
        ),
        RenameRulePreset(
            name: "連番のみ",
            rule: RenameRule(tokens: [
                .counter(CounterConfiguration(start: 1, digits: 4))
            ]),
            isBuiltIn: true
        ),
        RenameRulePreset(
            name: "元の名前 + 連番",
            rule: RenameRule(tokens: [
                .originalName(OriginalNameConfiguration()),
                .separator(SeparatorConfiguration(value: "_")),
                .counter(CounterConfiguration(start: 1, digits: 3))
            ]),
            isBuiltIn: true
        )
    ]
}
