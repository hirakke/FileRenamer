import SwiftUI
import AppKit
import Combine
import RenameKit

@MainActor
final class WorkspaceModel: ObservableObject {
    struct Tab: Identifiable {
        let id: UUID
        let model: AppModel
    }

    @Published private(set) var tabs: [Tab]
    @Published var selectedTabID: UUID
    private var modelObservers: [UUID: AnyCancellable] = [:]

    init() {
        let id = UUID()
        let model = AppModel()
        tabs = [Tab(id: id, model: model)]
        selectedTabID = id
        observe(model, id: id)
    }

    var activeModel: AppModel {
        tabs.first(where: { $0.id == selectedTabID })?.model ?? tabs[0].model
    }

    var preventsTermination: Bool {
        tabs.contains { $0.model.preventsTermination }
    }

    func addTab() {
        let id = UUID()
        let historyURL = RenameHistoryStore.defaultFileURL()
            .deletingLastPathComponent()
            .appendingPathComponent("TabHistories", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).json", isDirectory: false)
        let model = AppModel(
            historyStore: RenameHistoryStore(fileURL: historyURL),
            recoversPendingRenames: false
        )
        tabs.append(Tab(id: id, model: model))
        observe(model, id: id)
        selectedTabID = id
    }

    func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
    }

    func closeTab(_ id: UUID) {
        guard tabs.count > 1,
              let index = tabs.firstIndex(where: { $0.id == id }),
              !tabs[index].model.isBusy
        else { return }

        let wasSelected = selectedTabID == id
        tabs.remove(at: index)
        modelObservers[id] = nil
        if wasSelected {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    func title(for tab: Tab) -> String {
        let directories = tab.model.importedDirectories
        if let first = directories.first {
            return directories.count == 1
                ? first.lastPathComponent
                : "\(first.lastPathComponent) ほか\(directories.count - 1)件"
        }
        let index = tabs.firstIndex(where: { $0.id == tab.id }) ?? 0
        return "Tab \(index + 1)"
    }

    private func observe(_ model: AppModel, id: UUID) {
        modelObservers[id] = model.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var workspace: WorkspaceModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard workspace?.preventsTermination == true else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "リネーム処理が完了するまで終了できません"
        alert.informativeText = "ファイル名を安全に確定または復旧しています。処理が終わってから、もう一度終了してください。"
        alert.addButton(withTitle: "処理を続ける")
        alert.runModal()
        return .terminateCancel
    }
}

@main
struct FileRenamerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var workspace = WorkspaceModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(workspace.activeModel)
                .environmentObject(workspace)
                .onAppear { appDelegate.workspace = workspace }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新規タブ") { workspace.addTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Divider()
                Button("ファイルを追加…") { workspace.activeModel.presentOpenPanel(directories: false) }
                    .keyboardShortcut("o", modifiers: .command)
                Button("フォルダを追加…") { workspace.activeModel.presentOpenPanel(directories: true) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }

            // Keep the system Undo/Redo group intact so the field editor owns ⌘Z.
            // Filesystem Undo is a separate domain and uses ⌥⌘Z.
            CommandGroup(after: .undoRedo) {
                Divider()
                Button("前回のリネームを元に戻す") { workspace.activeModel.requestUndo() }
                    .keyboardShortcut("z", modifiers: [.command, .option])
                    .disabled(!workspace.activeModel.canUndo)
                Button("前回のリネームをやり直す") { workspace.activeModel.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .option, .shift])
                    .disabled(!workspace.activeModel.canRedo)
            }

            CommandGroup(after: .pasteboard) {
                Button("すべて選択") { workspace.activeModel.selectAll() }
                    .keyboardShortcut("a", modifiers: .command)
                Button("リストから除外") { workspace.activeModel.removeSelected() }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(workspace.activeModel.selection.isEmpty)
            }

            CommandMenu("並べ替え") {
                Button("1つ前へ") { workspace.activeModel.shift(ids: workspace.activeModel.selection, by: -1) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(!workspace.activeModel.canShift(ids: workspace.activeModel.selection, by: -1))
                Button("1つ後ろへ") { workspace.activeModel.shift(ids: workspace.activeModel.selection, by: 1) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                    .disabled(!workspace.activeModel.canShift(ids: workspace.activeModel.selection, by: 1))
                Button("先頭へ移動") { workspace.activeModel.moveToEdge(ids: workspace.activeModel.selection, toStart: true) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    .disabled(workspace.activeModel.selection.isEmpty)
                Button("末尾へ移動") { workspace.activeModel.moveToEdge(ids: workspace.activeModel.selection, toStart: false) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                    .disabled(workspace.activeModel.selection.isEmpty)
                Divider()
                ForEach(SortField.allCases, id: \.self) { field in
                    Menu(field.displayName) {
                        Button("昇順") { workspace.activeModel.applySort(SortDescriptorOption(field: field, ascending: true)) }
                        Button("降順") { workspace.activeModel.applySort(SortDescriptorOption(field: field, ascending: false)) }
                    }
                }
                Divider()
                Button("並びを反転") { workspace.activeModel.reverseOrder() }
                Button("選択項目の位置を固定 / 解除") {
                    workspace.activeModel.toggleLock(ids: workspace.activeModel.selection)
                }
                    .keyboardShortcut("l", modifiers: .command)
            }
        }
    }
}
