import AppKit
import RenameKit

extension AppModel {
    func revealInFinder(ids: Set<UUID>) {
        let urls = items.filter { ids.contains($0.id) }.flatMap(\.allURLs)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func openDirectoryInFinder(_ directory: URL) {
        NSWorkspace.shared.open(directory)
    }

    func copyDirectoryPath(_ directory: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(directory.path, forType: .string)
    }

    func quickLookSelection() {
        if quickLookURL != nil {
            quickLookURL = nil
            return
        }
        guard let id = selection.first, let item = items.first(where: { $0.id == id }) else { return }
        quickLookURL = item.originalURL
    }
}
