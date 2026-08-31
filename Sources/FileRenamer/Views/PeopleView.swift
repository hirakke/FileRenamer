import SwiftUI

struct PeopleView: View {
    @Environment(\.undoManager) private var undoManager
    @EnvironmentObject private var model: AppModel
    @ObservedObject var workspace: PeopleWorkspaceModel

    var body: some View {
        Group {
            switch workspace.route {
            case .overview:
                PeopleOverviewView(workspace: workspace)
            case .group, .unconfirmed:
                PersonDetailView(workspace: workspace, route: workspace.route)
            }
        }
        .workSurface(opacity: 0.92)
        .onAppear { workspace.attachUndoManager(undoManager) }
        .onChange(of: undoManager) { _, manager in
            workspace.attachUndoManager(manager)
        }
        .onDisappear { workspace.attachUndoManager(nil) }
        .confirmationDialog(
            "このMacに人物データを保存しますか？",
            isPresented: Binding(
                get: { model.pendingPeopleStorageEdit != nil },
                set: { if !$0 { model.cancelPeopleStorageEdit() } }
            ),
            titleVisibility: .visible
        ) {
            Button("保存して続ける") { model.confirmPeopleStorageEdit() }
            Button("キャンセル", role: .cancel) { model.cancelPeopleStorageEdit() }
        } message: {
            Text("名前と顔の特徴量だけをこのMac内に保存します。顔画像や写真の場所は保存しません。")
        }
    }
}
