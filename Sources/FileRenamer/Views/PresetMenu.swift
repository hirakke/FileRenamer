import SwiftUI
import RenameKit

/// Preset picker for the naming rule.
///
/// The label shows the active preset, or "カスタム" once blocks have been edited by
/// hand — so it is always clear whether what you see came from a preset or not.
struct PresetMenu: View {
    @EnvironmentObject private var model: AppModel

    @State private var sheetMode: PresetSheetMode?

    var body: some View {
        Menu {
            Section("プリセット") {
                ForEach(model.builtInPresets) { preset in
                    presetButton(preset)
                }
            }

            if !model.userPresets.isEmpty {
                Section("マイプリセット") {
                    ForEach(model.userPresets) { preset in
                        presetButton(preset)
                    }
                }
            }

            Divider()
            Button("現在のプリセットを保存…") {
                sheetMode = .create(model.savedRule)
            }
            // Always available: this is also where a first preset gets created.
            Button("プリセットを管理…") { sheetMode = .list }
            Divider()
            Button("プリセットを読み込む…") { model.importPresets() }
            Button("プリセットを書き出す…") { model.exportPresets() }
                .disabled(model.userPresets.isEmpty)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.stack.3d.up")
                Text(model.selectedPresetName ?? "カスタム")
                    .lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("命名規則のプリセットを選択・作成します")
        .sheet(item: $sheetMode) { mode in
            ManagePresetsSheet(initialMode: mode, dismiss: { sheetMode = nil })
                .environmentObject(model)
        }
    }

    private func presetButton(_ preset: RenameRulePreset) -> some View {
        Button {
            model.applyPreset(preset)
        } label: {
            if model.selectedPresetID == preset.id {
                Label(preset.name, systemImage: "checkmark")
            } else {
                Text(preset.name)
            }
        }
    }
}

enum PresetSheetMode: Identifiable {
    case list
    /// Start in the editor, seeded with a rule (usually the one currently applied).
    case create(RenameRule)

    var id: String {
        switch self {
        case .list: return "list"
        case .create: return "create"
        }
    }
}

/// Create, apply, edit and delete saved rules.
///
/// Reachable even with no presets yet — it doubles as the place to make the first
/// one, so "管理" is never a dead menu item. Creating and editing swap this sheet's
/// contents for the block builder rather than opening a second window on top: a rule
/// is assembled here from scratch, not just captured from the toolbar.
struct ManagePresetsSheet: View {
    @EnvironmentObject private var model: AppModel
    let initialMode: PresetSheetMode
    let dismiss: () -> Void

    private enum Screen: Equatable {
        case list
        case editor(presetID: UUID?)
    }

    @State private var screen: Screen = .list
    @State private var draftName = ""
    @State private var draftRule = RenameRule()
    @State private var didConfigure = false
    @State private var editingContext = RuleEditingContext()
    @State private var presetPendingDeletion: RenameRulePreset?

    var body: some View {
        Group {
            switch screen {
            case .list: presetList
            case .editor(let presetID): editor(presetID: presetID)
            }
        }
        .frame(width: 560)
        .onAppear {
            guard !didConfigure else { return }
            didConfigure = true
            if case .create(let rule) = initialMode {
                startCreating(from: rule)
            }
        }
        .alert("プリセットを削除しますか？", isPresented: Binding(
            get: { presetPendingDeletion != nil },
            set: { if !$0 { presetPendingDeletion = nil } }
        )) {
            Button("キャンセル", role: .cancel) { presetPendingDeletion = nil }
            Button("削除", role: .destructive) {
                if let presetPendingDeletion {
                    model.deletePreset(id: presetPendingDeletion.id)
                }
                presetPendingDeletion = nil
            }
        } message: {
            Text(presetPendingDeletion.map { "「\($0.name)」は元に戻せません。" } ?? "")
        }
    }

    // MARK: - List screen

    private var presetList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("プリセットを管理").font(.headline)
                Spacer()
                Menu {
                    Button("初めから作る") { startCreating(from: RenameRule()) }
                    Button("現在の規則を複製して作る") { startCreating(from: model.savedRule) }
                } label: {
                    Label("新規プリセット", systemImage: "plus")
                } primaryAction: {
                    startCreating(from: RenameRule())
                }
                .fixedSize()
            }

            if model.userPresets.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(model.userPresets) { preset in
                        row(for: preset)
                    }
                }
                .frame(height: 210)
            }

            Divider()

            HStack {
                Spacer()
                Button("閉じる", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func row(for preset: RenameRulePreset) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                RulePreviewLine(rule: preset.rule)
            }
            Spacer()

            Button("適用") { model.applyPreset(preset) }
                .buttonStyle(.borderless)

            Button {
                draftName = preset.name
                beginEditing(preset.rule)
                screen = .editor(presetID: preset.id)
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help("名前とブロックを編集")

            Button(role: .destructive) {
                presetPendingDeletion = preset
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("削除")
        }
        .padding(.vertical, 3)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("保存したプリセットはまだありません")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 210)
    }

    // MARK: - Editor screen

    /// Typing is the primary action: the rule is a line of text, and blocks are
    /// dropped in at the caret where a part of the name has to vary per file.
    private func editor(presetID: UUID?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(presetID == nil ? "新規プリセット" : "プリセットを編集")
                .font(.headline)

            LabeledContent("名前") {
                TextField("例: 旅行写真", text: $draftName)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 6) {
                Text("例:").font(.callout).foregroundStyle(.secondary)
                Text(sampleName)
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                    .foregroundStyle(draftRule.tokens.isEmpty ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            RuleTextField(rule: $draftRule, context: editingContext)

            Divider()
            TokenInsertPanel(insert: insertBlock)

            if isDuplicateName(excluding: presetID) {
                Label("同じ名前のプリセットを上書きします", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Palette.warning)
            }

            Divider()

            HStack {
                Spacer()
                Button("キャンセル") { backToList() }
                    .keyboardShortcut(.cancelAction)
                Button(presetID == nil ? "作成" : "保存") { commit(presetID: presetID) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCommit)
            }
        }
        .padding(20)
    }

    private func insertBlock(_ token: RenameToken) {
        draftRule = draftRule.inserting(
            token,
            atRun: editingContext.focusedRunID,
            caret: editingContext.caretLocation
        )
    }

    /// Preview against the first real file when there is one, so the sample shows the
    /// actual date and extension rather than a made-up example.
    private var sampleName: String {
        let rule = draftRule.compactedAfterTextEditing()
        guard !rule.tokens.isEmpty else { return "—" }
        if let item = model.items.first {
            return RenameEngine().makePreviews(items: [item], rule: rule).first?.proposedName ?? "—"
        }
        return rule.tokens.map(\.summary).joined()
    }

    private var canCommit: Bool {
        !draftName.trimmingCharacters(in: .whitespaces).isEmpty
            && !draftRule.compactedAfterTextEditing().tokens.isEmpty
    }

    private func isDuplicateName(excluding presetID: UUID?) -> Bool {
        let trimmed = draftName.trimmingCharacters(in: .whitespaces)
        return model.userPresets.contains { $0.name == trimmed && $0.id != presetID }
    }

    private func startCreating(from rule: RenameRule) {
        draftName = suggestedName()
        beginEditing(rule)
        screen = .editor(presetID: nil)
    }

    private func beginEditing(_ rule: RenameRule) {
        editingContext.reset()
        draftRule = rule.normalizedForTextEditing()
    }

    private func commit(presetID: UUID?) {
        let rule = draftRule.compactedAfterTextEditing()
        if let presetID {
            model.updatePreset(id: presetID, name: draftName, rule: rule)
        } else {
            model.addPreset(named: draftName, rule: rule)
        }
        backToList()
    }

    /// Creating from the menu opens straight into the editor, so cancelling or saving
    /// there should close the sheet rather than reveal a list the user never asked for.
    private func backToList() {
        if case .create = initialMode, screen == .editor(presetID: nil) {
            dismiss()
        } else {
            screen = .list
        }
    }

    /// "マイプリセット", "マイプリセット 2", … so the field is never empty.
    private func suggestedName() -> String {
        let base = "マイプリセット"
        guard model.userPresets.contains(where: { $0.name == base }) else { return base }
        var index = 2
        while model.userPresets.contains(where: { $0.name == "\(base) \(index)" }) { index += 1 }
        return "\(base) \(index)"
    }
}

/// Compact textual rendering of a rule's blocks, e.g. `撮影日 · _ · Event · _ · 001`.
struct RulePreviewLine: View {
    let rule: RenameRule

    var body: some View {
        Text(rule.tokens.isEmpty ? "（ブロックなし）" : rule.tokens.map(\.summary).joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}
