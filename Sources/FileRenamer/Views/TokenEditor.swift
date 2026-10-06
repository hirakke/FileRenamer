import SwiftUI
import RenameKit

/// Editor for one naming block. Writes back through the rule binding it was given,
/// so it is identical whether the rule is the live one or a preset draft.
struct TokenEditor: View {
    @EnvironmentObject private var preferences: AppPreferences
    @Binding var rule: RenameRule
    let token: RenameToken

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(token.localizedKindName(in: preferences.resolvedLanguage), systemImage: token.systemImageName)
                    .font(.headline)
                Spacer()
                Button(role: .destructive) {
                    $rule.remove(tokenID: token.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(L10n.string("tokenEditor.deleteThisBlock", defaultValue: "Delete this block", language: preferences.resolvedLanguage))
            }

            switch token {
            case .text(let config):
                TextTokenEditor(config: config) { $rule.update(.text($0)) }
            case .separator(let config):
                SeparatorTokenEditor(config: config) { $rule.update(.separator($0)) }
            case .counter(let config):
                CounterTokenEditor(config: config) { $rule.update(.counter($0)) }
            case .date(let config):
                DateTokenEditor(config: config) { $rule.update(.date($0)) }
            case .originalName(let config):
                OriginalNameTokenEditor(config: config) { $rule.update(.originalName($0)) }
            case .metadata(let config):
                MetadataTokenEditor(config: config) { $rule.update(.metadata($0)) }
            }
        }
    }
}

private struct TextTokenEditor: View {
    @Environment(\.locale) private var locale
    private var language: ResolvedAppLanguage { ResolvedAppLanguage(locale: locale) }
    @State var config: TextConfiguration
    let commit: (TextConfiguration) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(L10n.string("tokenEditor.exampleEventName", defaultValue: "Example: Event Name", language: language), text: $config.value)
                .textFieldStyle(.roundedBorder)
        }
        .onChange(of: config) { _, new in commit(new) }
    }
}

private struct SeparatorTokenEditor: View {
    @Environment(\.locale) private var locale
    private var language: ResolvedAppLanguage { ResolvedAppLanguage(locale: locale) }
    @State var config: SeparatorConfiguration
    let commit: (SeparatorConfiguration) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $config.value) {
                ForEach(SeparatorConfiguration.presets, id: \.self) { preset in
                    Text(preset == " " ? "space" : preset).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextField(L10n.string("tokenEditor.other", defaultValue: "Other", language: language), text: $config.value)
                .textFieldStyle(.roundedBorder)
        }
        .onChange(of: config) { _, new in commit(new) }
    }
}

private struct CounterTokenEditor: View {
    @EnvironmentObject private var preferences: AppPreferences
    @State var config: CounterConfiguration
    let commit: (CounterConfiguration) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent(L10n.string("tokenEditor.startingNumber", defaultValue: "Starting Number", language: preferences.resolvedLanguage)) {
                TextField("", value: $config.start, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }
            LabeledContent(L10n.string("tokenEditor.digits", defaultValue: "Digits", language: preferences.resolvedLanguage)) {
                Picker("", selection: $config.digits) {
                    ForEach(1...6, id: \.self) { digits in
                        Text(String(repeating: "0", count: digits - 1) + "1").tag(digits)
                    }
                }
                .labelsHidden()
                .frame(width: 90)
            }
            LabeledContent(L10n.string("tokenEditor.increment", defaultValue: "Increment", language: preferences.resolvedLanguage)) {
                Stepper(value: $config.step, in: 1...100) { Text("+\(config.step)") }
            }
            Picker(L10n.string("tokenEditor.resetCounter", defaultValue: "Reset Counter", language: preferences.resolvedLanguage), selection: $config.resetMode) {
                ForEach(CounterResetMode.allCases, id: \.self) { mode in
                    Text(mode.localizedDisplayName(in: preferences.resolvedLanguage)).tag(mode)
                }
            }
        }
        .onChange(of: config) { _, new in commit(new) }
    }
}

private struct DateTokenEditor: View {
    @EnvironmentObject private var preferences: AppPreferences
    @State var config: DateConfiguration
    let commit: (DateConfiguration) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(L10n.string("tokenEditor.type", defaultValue: "Type", language: preferences.resolvedLanguage), selection: $config.source) {
                ForEach(DateSource.allCases, id: \.self) { source in
                    Text(source.localizedDisplayName(in: preferences.resolvedLanguage)).tag(source)
                }
            }

            Picker(L10n.string("tokenEditor.format", defaultValue: "Format", language: preferences.resolvedLanguage), selection: $config.preset) {
                ForEach(DateFormatPreset.allCases, id: \.self) { preset in
                    Text(preset == .custom ? L10n.string("tokenEditor.custom", defaultValue: "Custom", language: preferences.resolvedLanguage) : preset.pattern.uppercased()).tag(preset)
                }
            }

            if config.preset == .custom {
                TextField("yyyyMMdd", text: $config.customPattern)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                if config.customPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label(L10n.string("tokenEditor.enterADateFormat", defaultValue: "Enter a date format.", language: preferences.resolvedLanguage), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Palette.warning)
                }
            }
        }
        .onChange(of: config) { _, new in commit(new) }
    }
}

private struct MetadataTokenEditor: View {
    @EnvironmentObject private var preferences: AppPreferences
    @State var config: MetadataConfiguration
    let commit: (MetadataConfiguration) -> Void

    var body: some View {
        Picker(L10n.string("tokenEditor.item", defaultValue: "Item", language: preferences.resolvedLanguage), selection: $config.field) {
            ForEach(MetadataField.allCases, id: \.self) { field in
                Text(field.localizedDisplayName(in: preferences.resolvedLanguage)).tag(field)
            }
        }
        .onChange(of: config) { _, new in commit(new) }
    }
}

private struct OriginalNameTokenEditor: View {
    @EnvironmentObject private var preferences: AppPreferences
    @State var config: OriginalNameConfiguration
    let commit: (OriginalNameConfiguration) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(L10n.string("tokenEditor.letterCase", defaultValue: "Letter Case", language: preferences.resolvedLanguage), selection: $config.transform) {
                ForEach(CaseTransform.allCases, id: \.self) { transform in
                    Text(transform.localizedDisplayName(in: preferences.resolvedLanguage)).tag(transform)
                }
            }
            TextField(L10n.string("tokenEditor.findLeaveEmptyForNo", defaultValue: "Find (leave empty for no replacement)", language: preferences.resolvedLanguage), text: $config.find)
                .textFieldStyle(.roundedBorder)
            TextField(L10n.string("tokenEditor.replaceWith", defaultValue: "Replace With", language: preferences.resolvedLanguage), text: $config.replacement)
                .textFieldStyle(.roundedBorder)
            Toggle(L10n.string("tokenEditor.useRegularExpression", defaultValue: "Use Regular Expression", language: preferences.resolvedLanguage), isOn: $config.usesRegularExpression)
            if config.usesRegularExpression, !config.find.isEmpty,
               (try? NSRegularExpression(pattern: config.find)) == nil {
                Label(L10n.string("tokenEditor.theRegularExpressionIsInvalid", defaultValue: "The regular expression is invalid.", language: preferences.resolvedLanguage), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.warning)
            }
        }
        .onChange(of: config) { _, new in commit(new) }
    }
}
