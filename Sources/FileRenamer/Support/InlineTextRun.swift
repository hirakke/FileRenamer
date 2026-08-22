import AppKit
import SwiftUI

/// Where the caret is, across all the text runs of one rule field.
///
/// Clicking an insert button moves focus away from the field, so the caret has to be
/// remembered as it moves rather than read back afterwards.
@MainActor
final class RuleEditingContext {
    var focusedRunID: UUID?
    var caretLocation = 0

    func reset() {
        focusedRunID = nil
        caretLocation = 0
    }
}

/// A borderless text field that is exactly as wide as its contents.
///
/// SwiftUI's `TextField` always claims the available width, which would make a rule
/// of several runs impossible to lay out inline. This one behaves like a word in a
/// sentence.
final class AutoWidthTextField: NSTextField {
    var minimumWidth: CGFloat = 10

    override var intrinsicContentSize: NSSize {
        let unbounded = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let fitting = cell?.cellSize(forBounds: NSRect(origin: .zero, size: unbounded)) ?? super.intrinsicContentSize
        return NSSize(width: max(fitting.width + 2, minimumWidth), height: fitting.height)
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        invalidateIntrinsicContentSize()
    }
}

/// Asks a specific run to take focus and put the caret at a given offset.
struct RuleFocusRequest: Equatable {
    let runID: UUID
    let caret: Int
}

/// One literal run of the rule — the part the user simply types.
struct InlineTextRun: NSViewRepresentable {
    let id: UUID
    @Binding var text: String
    let context: RuleEditingContext
    var placeholder: String = ""
    var focusRequest: RuleFocusRequest?
    /// Backspace at the very start of a run deletes the block in front of it, the way
    /// it deletes a character anywhere else. Return true when the run handled it.
    var onDeleteBackwardAtStart: () -> Bool = { false }
    var onDeleteForwardAtEnd: () -> Bool = { false }
    var onFocusRequestHandled: () -> Void = {}
    var onEditingChanged: (Bool) -> Void = { _ in }

    func makeNSView(context nsContext: Context) -> AutoWidthTextField {
        let field = AutoWidthTextField()
        field.delegate = nsContext.coordinator
        field.isBordered = false
        field.drawsBackground = false
        // The whole rule line is the editor. A focus ring around each tiny literal
        // run looked like several unrelated input boxes.
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        field.placeholderString = placeholder
        field.stringValue = text
        field.setAccessibilityLabel("固定文字")
        field.setAccessibilityHelp("ファイル名にそのまま入る文字を編集します")
        return field
    }

    func updateNSView(_ field: AutoWidthTextField, context nsContext: Context) {
        nsContext.coordinator.parent = self
        field.placeholderString = placeholder
        if field.stringValue != text {
            field.stringValue = text
            field.invalidateIntrinsicContentSize()
        }
        applyFocusRequest(to: field)
    }

    /// Deferred: the view may not be in a window yet on the pass that requests focus.
    private func applyFocusRequest(to field: AutoWidthTextField) {
        guard let focusRequest, focusRequest.runID == id else { return }
        let caret = focusRequest.caret
        DispatchQueue.main.async {
            guard let window = field.window else { return }
            window.makeFirstResponder(field)
            if let editor = field.currentEditor() {
                let location = min(max(caret, 0), field.stringValue.count)
                editor.selectedRange = NSRange(location: location, length: 0)
            }
            onFocusRequestHandled()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AutoWidthTextField, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineTextRun
        private var selectionObserver: NSObjectProtocol?

        init(_ parent: InlineTextRun) {
            self.parent = parent
        }

        deinit {
            if let selectionObserver {
                NotificationCenter.default.removeObserver(selectionObserver)
            }
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            (field.currentEditor() as? NSTextView)?.allowsUndo = true
            parent.onEditingChanged(true)
            observeSelection(of: field)
            record(from: field)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
            field.invalidateIntrinsicContentSize()
            record(from: field)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let selection = textView.selectedRange()
            guard selection.length == 0 else { return false }

            if selector == #selector(NSResponder.deleteBackward(_:)), selection.location == 0 {
                return parent.onDeleteBackwardAtStart()
            }
            if selector == #selector(NSResponder.deleteForward(_:)),
               selection.location == (textView.string as NSString).length {
                return parent.onDeleteForwardAtEnd()
            }
            return false
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            record(from: field)
            stopObservingSelection()
            parent.onEditingChanged(false)
        }

        /// The caret is tracked live: a click into the middle of a run changes it
        /// without changing the text, and an insert has to land there.
        private func observeSelection(of field: NSTextField) {
            stopObservingSelection()
            guard let editor = field.currentEditor() as? NSTextView else { return }
            selectionObserver = NotificationCenter.default.addObserver(
                forName: NSTextView.didChangeSelectionNotification,
                object: editor,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                let location = editor.selectedRange().location
                let id = self.parent.id
                let context = self.parent.context
                Task { @MainActor in
                    context.focusedRunID = id
                    context.caretLocation = location
                }
            }
        }

        private func stopObservingSelection() {
            if let selectionObserver {
                NotificationCenter.default.removeObserver(selectionObserver)
            }
            selectionObserver = nil
        }

        // The delegate callbacks arrive on the main thread but are not statically
        // isolated to it, so the hop is stated explicitly.
        @MainActor
        private func record(from field: NSTextField) {
            parent.context.focusedRunID = parent.id
            parent.context.caretLocation = (field.currentEditor() as? NSTextView)?.selectedRange().location
                ?? field.stringValue.count
        }
    }
}
