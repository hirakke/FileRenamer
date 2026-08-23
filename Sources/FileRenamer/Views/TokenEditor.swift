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
                .help("このブロックを削除")
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
    @State var config: TextConfiguration
    let commit: (TextConfiguration) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("例: イベント名", text: $config.value)
                .textFieldStyle(.roundedBorder)
        }
        .onChange(of: config) { _, new in commit(new) }
    }
}

private struct SeparatorTokenEditor: View {
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

            TextField("その他", text: $config.value)
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
            LabeledContent("開始番号") {
                TextField("", value: $config.start, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }
            LabeledContent("桁数") {
                Picker("", selection: $config.digits) {
                    ForEach(1...6, id: \.self) { digits in
                        Text(String(repeating: "0", count: digits - 1) + "1").tag(digits)
                    }
                }
                .labelsHidden()
                .frame(width: 90)
            }
            LabeledContent("増分") {
                Stepper(value: $config.step, in: 1...100) { Text("+\(config.step)") }
            }
            Picker("番号のリセット", selection: $config.resetMode) {
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
            Picker("種類", selection: $config.source) {
                ForEach(DateSource.allCases, id: \.self) { source in
                    Text(source.localizedDisplayName(in: preferences.resolvedLanguage)).tag(source)
                }
            }

            Picker("形式", selection: $config.preset) {
                ForEach(DateFormatPreset.allCases, id: \.self) { preset in
                    Text(preset == .custom ? "カスタム" : preset.pattern.uppercased()).tag(preset)
                }
            }

            if config.preset == .custom {
                TextField("yyyyMMdd", text: $config.customPattern)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                if config.customPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label("日付形式を入力してください", systemImage: "exclamationmark.triangle.fill")
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
        Picker("項目", selection: $config.field) {
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
            Picker("大文字小文字", selection: $config.transform) {
                ForEach(CaseTransform.allCases, id: \.self) { transform in
                    Text(transform.localizedDisplayName(in: preferences.resolvedLanguage)).tag(transform)
                }
            }
            TextField("検索（空なら置換なし）", text: $config.find)
                .textFieldStyle(.roundedBorder)
            TextField("置換後", text: $config.replacement)
                .textFieldStyle(.roundedBorder)
            Toggle("正規表現を使う", isOn: $config.usesRegularExpression)
            if config.usesRegularExpression, !config.find.isEmpty,
               (try? NSRegularExpression(pattern: config.find)) == nil {
                Label("正規表現が正しくありません", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.warning)
            }
        }
        .onChange(of: config) { _, new in commit(new) }
    }
}
