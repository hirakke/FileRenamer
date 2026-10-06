import SwiftUI
import RenameKit

/// Preset picker for the naming rule.
///
/// The label shows the active preset, or "カスタム" once blocks have been edited by
/// hand — so it is always clear whether what you see came from a preset or not.
struct PresetMenu: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: AppPreferences

    @State private var sheetMode: PresetSheetMode?

    var body: some View {
        Menu {
            Section(L10n.string("preset.presets", defaultValue: "Presets", language: preferences.resolvedLanguage)) {
                ForEach(model.builtInPresets) { preset in
                    presetButton(preset)
                }
            }

            if !model.userPresets.isEmpty {
                Section(L10n.string("preset.myPresets", defaultValue: "My Presets", language: preferences.resolvedLanguage)) {
                    ForEach(model.userPresets) { preset in
                        presetButton(preset)
                    }
                }
            }

            Divider()
            Button(L10n.string("preset.saveCurrentPreset", defaultValue: "Save Current Preset…", language: preferences.resolvedLanguage)) {
                sheetMode = .create(model.savedRule)
            }
            // Always available: this is also where a first preset gets created.
            Button(L10n.string("preset.managePresets", defaultValue: "Manage Presets…", language: preferences.resolvedLanguage)) { sheetMode = .list }
            Divider()
            Button(L10n.string("preset.importPresets", defaultValue: "Import Presets…", language: preferences.resolvedLanguage)) { model.importPresets() }
            Button(L10n.string("preset.exportPresets", defaultValue: "Export Presets…", language: preferences.resolvedLanguage)) { model.exportPresets() }
                .disabled(model.userPresets.isEmpty)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.stack.3d.up")
                Text(model.selectedPresetName
                     ?? L10n.string("カスタム", defaultValue: "Custom", language: preferences.resolvedLanguage))
                    .lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L10n.string("preset.chooseOrCreateANaming", defaultValue: "Choose or create a naming-rule preset.", language: preferences.resolvedLanguage))
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
                Label(preset.localizedDisplayName(in: preferences.resolvedLanguage), systemImage: "checkmark")
            } else {
                Text(preset.localizedDisplayName(in: preferences.resolvedLanguage))
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
    @EnvironmentObject private var preferences: AppPreferences
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
        .alert(L10n.string("preset.deleteThisPreset", defaultValue: "Delete this preset?", language: preferences.resolvedLanguage), isPresented: Binding(
            get: { presetPendingDeletion != nil },
            set: { if !$0 { presetPendingDeletion = nil } }
        )) {
            Button(L10n.string("main.cancel", defaultValue: "Cancel", language: preferences.resolvedLanguage), role: .cancel) { presetPendingDeletion = nil }
            Button(L10n.string("preset.delete", defaultValue: "Delete", language: preferences.resolvedLanguage), role: .destructive) {
                if let presetPendingDeletion {
                    model.deletePreset(id: presetPendingDeletion.id)
                }
                presetPendingDeletion = nil
            }
        } message: {
            Text(presetPendingDeletion.map {
                L10n.format(
                    "preset.delete.irreversible",
                    defaultValue: "“%@” can’t be restored.",
                    arguments: [$0.name],
                    language: preferences.resolvedLanguage
                )
            } ?? "")
        }
    }

    // MARK: - List screen

    private var presetList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.string("preset.managePresets2", defaultValue: "Manage Presets", language: preferences.resolvedLanguage)).font(.headline)
                Spacer()
                Menu {
                    Button(L10n.string("preset.createFromScratch", defaultValue: "Create from Scratch", language: preferences.resolvedLanguage)) { startCreating(from: RenameRule()) }
                    Button(L10n.string("preset.duplicateCurrentRule", defaultValue: "Duplicate Current Rule", language: preferences.resolvedLanguage)) { startCreating(from: model.savedRule) }
                } label: {
                    Label(L10n.string("preset.newPreset", defaultValue: "New Preset", language: preferences.resolvedLanguage), systemImage: "plus")
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
                Button(L10n.string("settings.close", defaultValue: "Close", language: preferences.resolvedLanguage), action: dismiss)
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

            Button(L10n.string("preset.apply", defaultValue: "Apply", language: preferences.resolvedLanguage)) { model.applyPreset(preset) }
                .buttonStyle(.borderless)

            Button {
                draftName = preset.name
                beginEditing(preset.rule)
                screen = .editor(presetID: preset.id)
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help(L10n.string("preset.editNameAndBlocks", defaultValue: "Edit name and blocks", language: preferences.resolvedLanguage))

            Button(role: .destructive) {
                presetPendingDeletion = preset
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(L10n.string("preset.delete", defaultValue: "Delete", language: preferences.resolvedLanguage))
        }
        .padding(.vertical, 3)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(L10n.string("preset.noSavedPresetsYet", defaultValue: "No saved presets yet", language: preferences.resolvedLanguage))
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
            Text(presetID == nil ? L10n.string("preset.newPreset", defaultValue: "New Preset", language: preferences.resolvedLanguage) : L10n.string("preset.editPreset", defaultValue: "Edit Preset", language: preferences.resolvedLanguage))
                .font(.headline)

            LabeledContent(L10n.string("preset.name", defaultValue: "Name", language: preferences.resolvedLanguage)) {
                TextField(L10n.string("preset.exampleTravelPhotos", defaultValue: "Example: Travel Photos", language: preferences.resolvedLanguage), text: $draftName)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 6) {
                Text(L10n.string("ruleBar.example", defaultValue: "Example:", language: preferences.resolvedLanguage)).font(.callout).foregroundStyle(.secondary)
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
                Label(L10n.string("preset.thisWillReplaceThePreset", defaultValue: "This will replace the preset with the same name.", language: preferences.resolvedLanguage), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Palette.warning)
            }

            Divider()

            HStack {
                Spacer()
                Button(L10n.string("main.cancel", defaultValue: "Cancel", language: preferences.resolvedLanguage)) { backToList() }
                    .keyboardShortcut(.cancelAction)
                Button(presetID == nil ? L10n.string("preset.create", defaultValue: "Create", language: preferences.resolvedLanguage) : L10n.string("preset.save", defaultValue: "Save", language: preferences.resolvedLanguage)) { commit(presetID: presetID) }
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
        return rule.tokens.map { $0.localizedSummary(in: preferences.resolvedLanguage) }.joined()
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

    /// "My Preset", "My Preset 2", … so the field is never empty.
    private func suggestedName() -> String {
        let base = L10n.string("preset.suggestedName", defaultValue: "My Preset", language: preferences.resolvedLanguage)
        guard model.userPresets.contains(where: { $0.name == base }) else { return base }
        var index = 2
        while model.userPresets.contains(where: { $0.name == "\(base) \(index)" }) { index += 1 }
        return "\(base) \(index)"
    }
}

/// Compact textual rendering of a rule's blocks, e.g. `撮影日 · _ · Event · _ · 001`.
struct RulePreviewLine: View {
    @EnvironmentObject private var preferences: AppPreferences
    let rule: RenameRule

    var body: some View {
        Text(
            rule.tokens.isEmpty
                ? L10n.string("preset.noBlocks", defaultValue: "(No Blocks)", language: preferences.resolvedLanguage)
                : rule.tokens.map { $0.localizedSummary(in: preferences.resolvedLanguage) }.joined(separator: " · ")
        )
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}
