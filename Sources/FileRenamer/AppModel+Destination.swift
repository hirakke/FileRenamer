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

    /// The new-folder flow first asks for the folder's name; the parent location
    /// comes second, from `confirmNewDestinationFolderName`.
    func chooseNewDestinationFolder() {
        newDestinationFolderName = localized("destination.new.defaultName", defaultValue: "New Folder")
        isNewDestinationFolderNamePresented = true
    }

    func confirmNewDestinationFolderName() {
        let name = newDestinationFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..",
              !FileNameSanitizer.containsIllegalCharacters(name) else {
            alertMessage = AlertMessage(
                title: localized("originalFolder.invalid.title", defaultValue: "This Folder Name Can’t Be Used"),
                detail: localized(
                    "originalFolder.invalid.detail",
                    defaultValue: "A folder name can’t be blank, `.`, `..`, or contain `/` or `:`."
                )
            )
            return
        }
        newDestinationFolderName = name
        isNewDestinationFolderNamePresented = false
        DispatchQueue.main.async { [weak self] in
            self?.presentNewDestinationParentPanel()
        }
    }

    /// Picks the parent for the new folder. The folder itself is only created by
    /// the executor at rename time, never here.
    private func presentNewDestinationParentPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = localized("destination.parent.prompt", defaultValue: "Choose Location")
        panel.message = localized(
            "destination.parent.message",
            defaultValue: "The new folder will be created in the selected location."
        )
        panel.directoryURL = importedDirectories.first
        guard panel.runModal() == .OK, let parent = panel.url else { return }

        let started = parent.startAccessingSecurityScopedResource()
        guard let bookmark = try? parent.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            if started { parent.stopAccessingSecurityScopedResource() }
            alertMessage = AlertMessage(
                title: localized("originalFolder.access.failed.title", defaultValue: "Couldn’t Allow Access to This Location"),
                detail: localized("originalFolder.access.failed.detail", defaultValue: "Choose another folder and try again.")
            )
            return
        }
        registerFolderAccess(url: parent, bookmark: bookmark, isActive: started)

        let folder = parent.appendingPathComponent(newDestinationFolderName, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            alertMessage = AlertMessage(
                title: localized("destination.exists.title", defaultValue: "A Folder with This Name Already Exists"),
                detail: localized(
                    "destination.exists.detail",
                    defaultValue: "“%@” already exists. No files were changed.",
                    arguments: [folder.lastPathComponent]
                )
            )
            return
        }
        setRenameDestination(.newFolder(folder))
        refreshPreviews()
    }

    func useInPlaceRename() {
        setRenameDestination(.inPlace)
        refreshPreviews()
    }
}
