import SwiftUI
import RenameKit

/// The "Name" step. The rule is typed like a file name; blocks are dropped in where
/// a part of it has to vary per file.
struct NamingRuleBar: View {
    @EnvironmentObject private var model: AppModel
    @State private var editingContext = RuleEditingContext()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("命名規則")
                    .font(.headline)
                PresetMenu()
                BlockInsertMenu(insert: insertBlock)
                Spacer()
                samplePreview
            }

            RuleTextField(rule: $model.rule, context: editingContext, editorPresentation: .popover)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .raisedWorkSurface(opacity: 0.97)
        .zIndex(1)
    }

    private func insertBlock(_ token: RenameToken) {
        model.insertBlock(token, atRun: editingContext.focusedRunID, caret: editingContext.caretLocation)
    }

    /// Live example built from the first item, so the rule is legible before the
    /// user scrolls the list.
    private var samplePreview: some View {
        Group {
            if let first = model.previews.first {
                HStack(spacing: 6) {
                    Text("例:").font(.caption).foregroundStyle(.secondary)
                    Text(first.proposedName)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(first.validation.isError ? Palette.error : Color.primary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// The same catalogue as the preset editor's insert panel, folded into a menu for
/// the toolbar where there is no room for three rows of popups.
struct BlockInsertMenu: View {
    let insert: (RenameToken) -> Void

    var body: some View {
        Menu {
            Menu("連番と日付") {
                ForEach(TokenInsertPanel.counterAndDateOptions.indices, id: \.self) { index in
                    let option = TokenInsertPanel.counterAndDateOptions[index]
                    Button(option.title) { insert(option.make()) }
                }
            }
            Menu("元の名前") {
                ForEach(TokenInsertPanel.originalNameOptions.indices, id: \.self) { index in
                    let option = TokenInsertPanel.originalNameOptions[index]
                    Button(option.title) { insert(option.make()) }
                }
            }
        } label: {
            Label("ブロックを挿入", systemImage: "plus.square")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
