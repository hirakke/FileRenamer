import SwiftUI
import RenameKit

/// The rule as a line of text you type, with blocks embedded in it.
///
/// Typing is the primary action: a rule is mostly literal characters, and a block is
/// inserted at the caret when a part of the name has to vary per file. Blocks are
/// still draggable and deletable, so a rule can be rearranged after the fact.
struct RuleTextField: View {
    /// Where a block's settings appear. The bar uses a popover so the window does not
    /// grow every time a block is clicked; a sheet uses inline, because popovers do
    /// not nest reliably on macOS.
    enum EditorPresentation {
        case popover
        case inline
    }

    @Binding var rule: RenameRule
    let context: RuleEditingContext
    var editorPresentation: EditorPresentation = .inline
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var editingTokenID: UUID?
    @State private var focusRequest: RuleFocusRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            field

            if editorPresentation == .inline,
               let id = editingTokenID,
               let token = rule.tokens.first(where: { $0.id == id }) {
                TokenEditor(rule: $rule, token: token)
                    .padding(14)
                    .liquidGlass(cornerRadius: 12)
            }
        }
    }

    private var field: some View {
        FlowLayout(spacing: 5, lineSpacing: 7) {
            ForEach(Array(rule.tokens.enumerated()), id: \.element.id) { index, token in
                switch token {
                case .text(let config):
                    InlineTextRun(
                        id: config.id,
                        text: textBinding(for: config),
                        context: context,
                        placeholder: placeholder(at: index),
                        focusRequest: focusRequest,
                        onDeleteBackwardAtStart: { deleteBlock(before: config.id) },
                        onDeleteForwardAtEnd: { deleteBlock(after: config.id) },
                        onFocusRequestHandled: { focusRequest = nil },
                        onEditingChanged: onEditingChanged
                    )
                    .frame(height: 24)

                default:
                    BlockToken(
                        rule: $rule,
                        token: token,
                        presentation: editorPresentation,
                        isSelected: editingTokenID == token.id,
                        onEdit: { editingTokenID = editingTokenID == token.id ? nil : token.id },
                        onDelete: { delete(token) }
                    )
                    .draggable(token.id.uuidString) { BlockFace(token: token) }
                    .dropDestination(for: String.self) { payload, _ in
                        guard let id = payload.compactMap(UUID.init(uuidString:)).first else { return false }
                        $rule.move(tokenID: id, toIndex: index)
                        rule = rule.normalizedForTextEditing()
                        return true
                    }
                }
            }

            ExtensionBlockToken(rule: $rule)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Only the first run prompts, and only while the whole rule is empty.
    private func placeholder(at index: Int) -> String {
        guard index == 0, rule.tokens.count == 1 else { return "" }
        return "ファイル名を入力"
    }

    private func textBinding(for config: TextConfiguration) -> Binding<String> {
        Binding(
            get: { config.value },
            set: { newValue in
                var updated = config
                updated.value = newValue
                $rule.update(.text(updated))
            }
        )
    }

    private func delete(_ token: RenameToken) {
        if editingTokenID == token.id { editingTokenID = nil }
        rule = rule.removingToken(id: token.id)
    }

    /// Backspace at the start of a run eats the block in front of it.
    ///
    /// Removing the block merges the runs on either side of it, and the merged run
    /// keeps the earlier run's identity — so the caret is put back at the join, exactly
    /// where the block used to be. Deleting feels like deleting a character.
    private func deleteBlock(before runID: UUID) -> Bool {
        guard let index = rule.tokens.firstIndex(where: { $0.id == runID }),
              index >= 1,
              !rule.tokens[index - 1].isTextRun
        else { return false }

        let block = rule.tokens[index - 1]
        var target: RuleFocusRequest?
        if index >= 2, case .text(let preceding) = rule.tokens[index - 2] {
            target = RuleFocusRequest(runID: preceding.id, caret: preceding.value.count)
        }

        if editingTokenID == block.id { editingTokenID = nil }
        rule = rule.removingToken(id: block.id)
        focusRequest = target
        return true
    }

    /// Forward delete at the end of a run eats the block after it.
    private func deleteBlock(after runID: UUID) -> Bool {
        guard let index = rule.tokens.firstIndex(where: { $0.id == runID }),
              index + 1 < rule.tokens.count,
              !rule.tokens[index + 1].isTextRun,
              case .text(let current) = rule.tokens[index]
        else { return false }

        let block = rule.tokens[index + 1]
        if editingTokenID == block.id { editingTokenID = nil }
        rule = rule.removingToken(id: block.id)
        focusRequest = RuleFocusRequest(runID: current.id, caret: current.value.count)
        return true
    }
}

/// Extensions are not part of the editable base-name token array, but showing one
/// as a fixed final block makes the complete output name legible at a glance.
private struct ExtensionBlockToken: View {
    @Binding var rule: RenameRule
    @EnvironmentObject private var preferences: AppPreferences
    @State private var isShowingPopover = false
    @State private var isHovered = false

    var body: some View {
        Button {
            isShowingPopover.toggle()
        } label: {
            ExtensionBlockFace(label: label, isSelected: isShowingPopover)
                .opacity(isHovered ? 0.85 : 1)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .popover(isPresented: $isShowingPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("拡張子")
                    .font(.headline)

                Text("大文字・小文字")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("大文字・小文字", selection: $rule.extensionTransform) {
                    ForEach(CaseTransform.allCases, id: \.self) { transform in
                        Text(transform.localizedDisplayName(in: preferences.resolvedLanguage)).tag(transform)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                Text("画像形式は「画像設定」から変更できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(width: 280)
        }
        .help("拡張子の大文字・小文字を設定")
        .accessibilityLabel("拡張子ブロック、\(label)")
    }

    private var label: String {
        if let outputExtension = rule.imageOutputFormat.fileExtension {
            return ".\(rule.extensionTransform.apply(outputExtension))"
        }

        switch rule.extensionTransform {
        case .none:
            return ".拡張子"
        case .lowercase:
            return ".拡張子（小文字）"
        case .uppercase:
            return ".拡張子（大文字）"
        }
    }
}

/// A block sitting inside the text: click to configure, hover to delete.
private struct BlockToken: View {
    @Binding var rule: RenameRule
    let token: RenameToken
    let presentation: RuleTextField.EditorPresentation
    let isSelected: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var isShowingPopover = false

    private func edit() {
        if presentation == .popover {
            isShowingPopover = true
        } else {
            onEdit()
        }
    }

    var body: some View {
        Button(action: edit) {
            BlockFace(token: token, isSelected: isSelected || isShowingPopover)
                .opacity(isHovered ? 0.85 : 1)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowingPopover, arrowEdge: .bottom) {
            TokenEditor(rule: $rule, token: token)
                .padding(16)
                .frame(width: 280)
        }
        .onHover { isHovered = $0 }
        .help("クリックで設定、ドラッグで移動、Backspace で削除")
        .contextMenu {
            Button("編集…", action: edit)
            Divider()
            Button("削除", role: .destructive, action: onDelete)
        }
    }
}
