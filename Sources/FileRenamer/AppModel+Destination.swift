import AppKit
import RenameKit

/// The "move the renamed files into one folder" option: choosing the target,
/// and the counts the status bar needs to phrase its split button.
extension AppModel {
    /// Files whose destination differs from where they are now, including the
    /// folder move itself. Counted per item to match the other status numbers.
    var renamedItemCount: Int {
        previews.filter { !$0.validation.isError && !$0.effectiveOperations.isEmpty }.count
    }

    var imageProcessingItemCount: Int {
        previews.filter { !$0.validation.isError && $0.requiresContentProcessing }.count
    }

    /// What the rename button promises right now — move, rename + convert, plain
    /// rename, or plain convert. Shared by the status bar and the confirmation sheet.
    var renameActionTitle: String {
        guard changedCount > 0 else {
            return localized("action.rename", defaultValue: "Rename")
        }
        if renameDestination.directory != nil {
            return localized(
                "action.moveItems",
                defaultValue: "Move %lld Items",
                arguments: [changedCount]
            )
        }
        if renamedItemCount > 0, imageProcessingItemCount > 0 {
            return localized(
                "action.renameConvertCount",
                defaultValue: "Rename & Convert %lld Items",
                arguments: [changedCount]
            )
        }
        if imageProcessingItemCount > 0 {
            return localized(
                "action.convertCount",
                defaultValue: "Convert %lld Images",
                arguments: [imageProcessingItemCount]
            )
        }
        return localized(
            "action.renameCount",
            defaultValue: "Rename %lld Items",
            arguments: [changedCount]
        )
    }

    /// Folder picked through the move-to-existing menu item. Its access grant is
    /// kept like an imported folder so the rename and Undo can reach inside it.
    func chooseExistingDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = localized("destination.panel.prompt", defaultValue: "Move Here")
        panel.message = localized(
            "destination.panel.message",
            defaultValue: "The files will be moved into this folder when they are renamed."
        )
        panel.directoryURL = importedDirectories.first
        guard panel.runModal() == .OK, let selected = panel.url else { return }

        let started = selected.startAccessingSecurityScopedResource()
        guard let bookmark = try? selected.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            if started { selected.stopAccessingSecurityScopedResource() }
            alertMessage = AlertMessage(
                title: localized("originalFolder.access.failed.title", defaultValue: "Couldn’t Allow Access to This Location"),
                detail: localized("originalFolder.access.failed.detail", defaultValue: "Choose another folder and try again.")
            )
            return
        }
        registerFolderAccess(url: selected, bookmark: bookmark, isActive: started)
        setRenameDestination(.existingFolder(selected))
        refreshPreviews()
    }

    func useInPlaceRename() {
        setRenameDestination(.inPlace)
        refreshPreviews()
    }
}
