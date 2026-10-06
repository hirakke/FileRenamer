import SwiftUI
import TipKit
import RenameKit

/// Drives the five-step walkthrough. `step` persists in the TipKit datastore, so a
/// quit mid-tour resumes where it stopped. TipKit cannot un-invalidate a tip, so
/// "show again" folds a UserDefaults generation number into every tip id instead —
/// a new generation looks like brand-new tips to the datastore.
enum TutorialProgress {
    @Parameter static var step: Int = 0
    @Parameter static var hasFiles: Bool = false

    private static let generationKey = "tutorial.generation"

    static var generation: Int {
        UserDefaults.standard.integer(forKey: generationKey)
    }

    /// Only the current step can advance, so stale callbacks fired by an
    /// already-passed tip cannot skip ahead.
    static func advance(from step: Int) {
        guard Self.step == step else { return }
        Self.step = step + 1
    }

    static func restart() {
        UserDefaults.standard.set(generation + 1, forKey: generationKey)
        step = 0
    }
}

/// The "Add Files" toolbar button.
struct AddFilesTip: Tip {
    let language: ResolvedAppLanguage

    var id: String { "tutorial.addFiles.\(TutorialProgress.generation)" }
    var title: Text {
        Text(L10n.string("tutorial.addFiles.title", defaultValue: "Add Files", language: language))
    }
    var message: Text? {
        Text(L10n.string(
            "tutorial.addFiles.message",
            defaultValue: "Add files or folders here, or drop them anywhere in the window.",
            language: language
        ))
    }
    var image: Image? { Image(systemName: "doc.badge.plus") }
    var rules: [Rule] {
        #Rule(TutorialProgress.$step) { $0 == 0 }
    }
    var actions: [Action] {
        TutorialActions.standard(language: language)
    }
}

/// The naming rule text field.
struct TypeNameTip: Tip {
    let language: ResolvedAppLanguage

    var id: String { "tutorial.typeName.\(TutorialProgress.generation)" }
    var title: Text {
        Text(L10n.string("tutorial.typeName.title", defaultValue: "Type the New Name", language: language))
    }
    var message: Text? {
        Text(L10n.string(
            "tutorial.typeName.message",
            defaultValue: "Type fixed text directly. Every file is renamed with this rule, and the list shows the result before anything changes.",
            language: language
        ))
    }
    var image: Image? { Image(systemName: "character.cursor.ibeam") }
    var rules: [Rule] {
        #Rule(TutorialProgress.$step) { $0 == 1 }
    }
    var actions: [Action] {
        TutorialActions.standard(language: language)
    }
}

/// The block insertion menu.
struct InsertBlocksTip: Tip {
    let language: ResolvedAppLanguage

    var id: String { "tutorial.insertBlocks.\(TutorialProgress.generation)" }
    var title: Text {
        Text(L10n.string("tutorial.insertBlocks.title", defaultValue: "Insert Blocks", language: language))
    }
    var message: Text? {
        Text(L10n.string(
            "tutorial.insertBlocks.message",
            defaultValue: "Blocks change per file — counters, dates, the original name, or photo info. Click a block to adjust it.",
            language: language
        ))
    }
    var image: Image? { Image(systemName: "square.on.square") }
    var rules: [Rule] {
        #Rule(TutorialProgress.$step) { $0 == 2 }
    }
    var actions: [Action] {
        TutorialActions.standard(language: language)
    }
}

/// The destination chevron on the rename split button.
struct RenameOrGatherTip: Tip {
    let language: ResolvedAppLanguage

    var id: String { "tutorial.renameOrGather.\(TutorialProgress.generation)" }
    var title: Text {
        Text(L10n.string("tutorial.renameOrGather.title", defaultValue: "Rename or Gather", language: language))
    }
    var message: Text? {
        Text(L10n.string(
            "tutorial.renameOrGather.message",
            defaultValue: "Press the button to rename. Use ▾ to move the files into one existing or new folder at the same time.",
            language: language
        ))
    }
    var image: Image? { Image(systemName: "folder.badge.plus") }
    var rules: [Rule] {
        #Rule(TutorialProgress.$step) { $0 == 3 }
        #Rule(TutorialProgress.$hasFiles) { $0 }
    }
    var actions: [Action] {
        TutorialActions.standard(language: language)
    }
}

/// The Undo toolbar button — the last step.
struct UndoTip: Tip {
    let language: ResolvedAppLanguage

    var id: String { "tutorial.undo.\(TutorialProgress.generation)" }
    var title: Text {
        Text(L10n.string("tutorial.undo.title", defaultValue: "You Can Always Undo", language: language))
    }
    var message: Text? {
        Text(L10n.string(
            "tutorial.undo.message",
            defaultValue: "Changes can be undone with ⌥⌘Z, even after the app is restarted.",
            language: language
        ))
    }
    var image: Image? { Image(systemName: "arrow.uturn.backward") }
    var rules: [Rule] {
        #Rule(TutorialProgress.$step) { $0 == 4 }
    }
    var actions: [Action] {
        TutorialActions.done(language: language)
    }
}

private enum TutorialActions {
    static func standard(language: ResolvedAppLanguage) -> [Tips.Action] {
        [
            Tips.Action(
                id: "next",
                title: L10n.string("tutorial.next", defaultValue: "Next", language: language)
            ),
            Tips.Action(
                id: "skip",
                title: L10n.string("tutorial.skip", defaultValue: "Skip Tutorial", language: language)
            )
        ]
    }

    static func done(language: ResolvedAppLanguage) -> [Tips.Action] {
        [
            Tips.Action(
                id: "next",
                title: L10n.string("tutorial.done", defaultValue: "Done", language: language)
            )
        ]
    }
}

extension View {
    /// Attaches one step of the tutorial. The primary action advances the tour;
    /// "skip" ends it entirely.
    func tutorialTip(_ tip: some Tip, step: Int, arrowEdge: Edge) -> some View {
        popoverTip(tip, arrowEdge: arrowEdge) { action in
            if action.id == "skip" {
                TutorialProgress.step = 99
            } else {
                TutorialProgress.advance(from: step)
            }
            tip.invalidate(reason: .actionPerformed)
        }
    }
}
