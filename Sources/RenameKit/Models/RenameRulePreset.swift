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
            id: UUID(uuidString: "544DA950-3FB3-4967-9B9B-E2DBD670DFC8")!,
            name: "01納品",
            rule: RenameRule(tokens: [
                .text(TextConfiguration(
                    id: UUID(uuidString: "C3E1927A-0071-4F28-9471-6244A089163B")!,
                    value: "Day1_"
                )),
                .counter(CounterConfiguration(
                    id: UUID(uuidString: "00794301-10E5-4F14-BEA7-CCA4BA754164")!,
                    start: 1,
                    digits: 2,
                    step: 1,
                    resetMode: .never
                ))
            ]),
            isBuiltIn: true
        ),
        RenameRulePreset(
            id: UUID(uuidString: "8435AAA5-B0B6-40DF-BD37-051F022B39E2")!,
            name: "001納品",
            rule: RenameRule(tokens: [
                .text(TextConfiguration(
                    id: UUID(uuidString: "73E1C00C-8F9F-451C-9C0C-236291CBE55A")!,
                    value: "Day1_"
                )),
                .counter(CounterConfiguration(
                    id: UUID(uuidString: "515440CE-5DB4-47DE-91E4-725C8C48DEB1")!,
                    start: 1,
                    digits: 3,
                    step: 1,
                    resetMode: .never
                ))
            ]),
            isBuiltIn: true
        ),
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
