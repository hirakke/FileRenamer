import SwiftUI
import AppKit
import QuickLookUI
import RenameKit
import TipKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var workspace: WorkspaceModel
    @EnvironmentObject private var preferences: AppPreferences
    @AppStorage("tutorial.generation") private var tutorialGeneration = 0
    @State private var isDropTargeted = false
    @State private var isWorkspaceSidebarVisible = false
    @StateObject private var quickLookWindow = QuickLookWindowController()
    @StateObject private var outsideClickMonitor = SidebarOutsideClickMonitor()

    private let workspaceSidebarWidth: CGFloat = 218

    var body: some View {
        ZStack {
            GlassWindowBackdrop()
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                fileArea
                NamingRuleBar()
                StatusBar()
            }
            .id(workspace.selectedTabID)
            // Keep the original control action alive: selecting a file, editing a
            // rule or moving a slider also dismisses the navigator in that same
            // click, instead of consuming a first click just to close it.
            .simultaneousGesture(
                TapGesture().onEnded {
                    guard isWorkspaceSidebarVisible else { return }
                    withAnimation(.smooth(duration: 0.22)) {
                        isWorkspaceSidebarVisible = false
                    }
                }
            )

            WorkspaceSidebar()
                .frame(width: workspaceSidebarWidth)
                .background(.thinMaterial)
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.10))
                        .frame(width: 1)
                }
                .offset(x: isWorkspaceSidebarVisible ? 0 : -workspaceSidebarWidth - 16)
                .allowsHitTesting(isWorkspaceSidebarVisible)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .zIndex(2)
                .animation(.smooth(duration: 0.22), value: isWorkspaceSidebarVisible)
        }
        .background {
            PlainWindowTitle(title: workingDirectoryTitle)
                .frame(width: 0, height: 0)
        }
        .toolbar { toolbarContent }
        .modifier(GlassWindowToolbarBackground())
        // Finder drop is accepted anywhere in the window, not just over the list.
        .dropDestination(for: URL.self) { urls, _ in
            model.importURLs(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if model.isBusy {
                busyOverlay
            } else if let message = model.resultMessage {
                completionOverlay(message)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.resultMessage?.id)
        .onAppear {
            isWorkspaceSidebarVisible = preferences.opensSidebarOnLaunch
            outsideClickMonitor.start(sidebarWidth: workspaceSidebarWidth) {
                guard isWorkspaceSidebarVisible else { return }
                withAnimation(.smooth(duration: 0.22)) {
                    isWorkspaceSidebarVisible = false
                }
            }
            updateQuickLookWindow(model.quickLookURL)
        }
        .onChange(of: model.quickLookURL) { _, url in
            updateQuickLookWindow(url)
        }
        .onDisappear {
            outsideClickMonitor.stop()
            quickLookWindow.close(notify: false)
        }
        .task(id: tutorialGeneration) {
            await observeTutorialTips()
        }
        .sheet(item: $model.similarityReview) { review in
            SimilarImageReviewView(review: review)
        }
        .sheet(item: $model.renameConfirmation) { confirmation in
            RenameConfirmationView(confirmation: confirmation) {
                model.confirmRename()
            }
            .interactiveDismissDisabled()
        }
        .alert(item: $model.alertMessage) { message in
            switch message.action {
            case .addWorkingFolder:
                Alert(
                    title: Text(message.title),
                    message: Text(message.detail),
                    primaryButton: .default(Text(message.actionTitle ?? L10n.string(
                        "フォルダを選択…",
                        defaultValue: "Choose Folder…",
                        language: preferences.resolvedLanguage
                    ))) {
                        model.presentFolderAccessPanel()
                    },
                    secondaryButton: .cancel()
                )
            case nil:
                Alert(title: Text(message.title), message: Text(message.detail), dismissButton: .default(Text("OK")))
            }
        }
        .alert("リネームを元に戻しますか？", isPresented: $model.isUndoConfirmationPresented) {
            Button("キャンセル", role: .cancel) {}
            Button("元に戻す", role: .destructive) {
                model.confirmUndo()
            }
        } message: {
            Text(model.undoConfirmationMessage)
        }
        .confirmationDialog(
            L10n.format(
                "trash.confirmation.title",
                defaultValue: "Move %d item(s) to Trash?",
                arguments: [model.trashConfirmationItems.count],
                language: preferences.resolvedLanguage
            ),
            isPresented: Binding(
                get: { model.trashConfirmation != nil },
                set: { if !$0 { model.cancelMoveToTrashConfirmation() } }
            ),
            titleVisibility: .visible
        ) {
            Button("ゴミ箱に移動", role: .destructive) {
                model.confirmMoveToTrash()
            }
            Button("キャンセル", role: .cancel) {
                model.cancelMoveToTrashConfirmation()
            }
        } message: {
            Text(trashConfirmationDetail)
        }
        .confirmationDialog(
            "変更前の元画像を残しますか？",
            isPresented: $model.isImageResizeOriginalChoicePresented,
            titleVisibility: .visible
        ) {
            Button("元画像を残して保存先を選ぶ") {
                model.chooseOriginalImagesDestinationForResize()
            }
            Button("元画像を置き換える", role: .destructive) {
                model.replaceOriginalImagesForResize()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("画像変換・リサイズでは画像データを再生成します。元画像を残す場合は、フォルダ名を入力してから作成場所を選択します。")
        }
        .alert("元画像を保存するフォルダ名", isPresented: $model.isOriginalImagesFolderNamePresented) {
            TextField("フォルダ名", text: $model.originalImagesFolderName)
            Button("キャンセル", role: .cancel) {}
            Button("保存場所を選ぶ") {
                model.confirmOriginalImagesFolderName()
            }
        } message: {
            Text("選択する保存場所の中に、この名前の新しいフォルダを作成します。")
        }
        .alert(
            L10n.string(
                "destination.new.alertTitle",
                defaultValue: "Name for the New Folder",
                language: preferences.resolvedLanguage
            ),
            isPresented: $model.isNewDestinationFolderNamePresented
        ) {
            TextField("フォルダ名", text: $model.newDestinationFolderName)
            Button("キャンセル", role: .cancel) {}
            Button("保存場所を選ぶ") {
                model.confirmNewDestinationFolderName()
            }
        } message: {
            Text(L10n.string(
                "destination.new.alertMessage",
                defaultValue: "The new folder will be created in the chosen location, and the files will be moved into it.",
                language: preferences.resolvedLanguage
            ))
        }
        .frame(minWidth: 900, minHeight: 600)
        .modifier(ClearWindowContainerBackground())
    }

    private func updateQuickLookWindow(_ url: URL?) {
        quickLookWindow.update(url: url) {
            DispatchQueue.main.async {
                model.quickLookURL = nil
            }
        }
    }

    private var workingDirectoryTitle: String {
        guard let first = model.workingDirectories.first else { return "" }
        return model.workingDirectories.count == 1
            ? first.lastPathComponent
            : L10n.format(
                "workspace.additionalFolders",
                defaultValue: "%@ and %d more location(s)",
                arguments: [first.lastPathComponent, model.workingDirectories.count - 1],
                language: preferences.resolvedLanguage
            )
    }

    private var trashConfirmationDetail: String {
        let items = model.trashConfirmationItems
        let names = items.prefix(5).map(\.displayName).joined(separator: "\n")
        let remainder = items.count > 5
            ? L10n.format(
                "trash.confirmation.remainder",
                defaultValue: "\n%d more item(s)",
                arguments: [items.count - 5],
                language: preferences.resolvedLanguage
            )
            : ""
        return L10n.format(
            "trash.confirmation.detail",
            defaultValue: "Files will be moved to Finder’s Trash and can be restored there.\n\n%@%@",
            arguments: [names, remainder],
            language: preferences.resolvedLanguage
        )
    }

    @ViewBuilder
    private var fileArea: some View {
        if model.isEmpty {
            EmptyStateView()
        } else {
            switch model.viewMode {
            case .list: FileListView()
            case .grid: FileGridView()
            }
        }
    }

    private var busyOverlay: some View {
        ZStack {
            Color.black.opacity(0.15)
            VStack(spacing: 12) {
                ProgressView(value: model.progress > 0 ? model.progress : nil, total: 1)
                    .progressViewStyle(.linear)
                    .frame(width: 220)
                Text(model.busyLabel).font(.callout)
                if model.canCancelBusyOperation {
                    Button("キャンセル") { model.cancelBusyOperation() }
                }
            }
            .operationPopupSurface()
        }
        .ignoresSafeArea()
    }

    private func completionOverlay(_ message: AppModel.ResultMessage) -> some View {
        ZStack {
            Color.black.opacity(0.15)

            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Palette.ok)

                Text(message.text)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    if message.offersUndo {
                        Button("元に戻す") {
                            model.requestUndo()
                        }
                    }
                    Button("閉じる") {
                        model.resultMessage = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .frame(width: 260)
            .operationPopupSurface()
        }
        .ignoresSafeArea()
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                isWorkspaceSidebarVisible.toggle()
            } label: {
                Label("TabBar", systemImage: "sidebar.leading")
            }
            .help(isWorkspaceSidebarVisible ? "TabBarを隠す" : "TabBarを表示")
        }

        ToolbarItemGroup {
            Button {
                model.presentOpenPanel(directories: false)
            } label: {
                Label("ファイルを追加", systemImage: "doc.badge.plus")
            }
            .tutorialTip(AddFilesTip(language: preferences.resolvedLanguage), step: 0, arrowEdge: .top)

            Button {
                model.presentOpenPanel(directories: true)
            } label: {
                Label("フォルダを追加", systemImage: "folder.badge.plus")
            }

            Menu {
                ForEach(SortField.allCases, id: \.self) { field in
                    Menu(field.localizedDisplayName(in: preferences.resolvedLanguage)) {
                        Button("昇順") { model.applySort(SortDescriptorOption(field: field, ascending: true)) }
                        Button("降順") { model.applySort(SortDescriptorOption(field: field, ascending: false)) }
                    }
                }
                Divider()
                Button("並びを反転") { model.reverseOrder() }
                Divider()
                Toggle("RAW + JPEG をまとめる", isOn: $model.importOptions.groupCompanionFiles)
            } label: {
                Label("並べ替え", systemImage: "arrow.up.arrow.down")
            }

            Picker("表示", selection: $model.viewMode) {
                ForEach(ViewMode.allCases) { mode in
                    Image(systemName: mode.systemImageName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .help("リスト / グリッド表示を切り替え")

            Button {
                model.requestUndo()
            } label: {
                Label("元に戻す", systemImage: "arrow.uturn.backward")
            }
            .disabled(!model.canUndo)
            .tutorialTip(UndoTip(language: preferences.resolvedLanguage), step: 4, arrowEdge: .top)
        }
    }

    /// Closing a tip with its × reports `.invalidated` on `statusUpdates`; the tour
    /// treats that the same as tapping Next so the sequence keeps moving.
    private func observeTutorialTips() async {
        let language = preferences.resolvedLanguage
        let tips: [(any Tip, Int)] = [
            (AddFilesTip(language: language), 0),
            (TypeNameTip(language: language), 1),
            (InsertBlocksTip(language: language), 2),
            (RenameOrGatherTip(language: language), 3),
            (UndoTip(language: language), 4)
        ]
        await withTaskGroup(of: Void.self) { group in
            for (tip, step) in tips {
                group.addTask {
                    for await status in tip.statusUpdates {
                        if case .invalidated = status {
                            TutorialProgress.advance(from: step)
                        }
                    }
                }
            }
        }
    }
}

/// Watches mouse-down events without consuming them. A click in the main window
/// outside the leading sidebar closes it while the clicked control still receives
/// the same event normally.
@MainActor
private final class SidebarOutsideClickMonitor: ObservableObject {
    private var localMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var sidebarWidth: CGFloat = 0
    private var dismiss: (() -> Void)?

    func start(sidebarWidth: CGFloat, dismiss: @escaping () -> Void) {
        self.sidebarWidth = sidebarWidth
        self.dismiss = dismiss
        guard localMonitor == nil else { return }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            guard let self,
                  let eventWindow = event.window,
                  eventWindow == NSApp.mainWindow,
                  event.locationInWindow.x > self.sidebarWidth
            else { return event }

            let dismiss = self.dismiss
            DispatchQueue.main.async {
                dismiss?()
            }
            return event
        }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                let dismiss = self?.dismiss
                DispatchQueue.main.async {
                    dismiss?()
                }
            }
        }
    }

    func stop() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        localMonitor = nil
        resignObserver = nil
        dismiss = nil
    }

    deinit {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
    }
}

private struct GlassWindowToolbarBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content.toolbarBackground(.hidden, for: .windowToolbar)
        }
    }
}

private struct ClearWindowContainerBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.containerBackground(.clear, for: .window)
        } else {
            content
        }
    }
}

struct EmptyStateView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tertiary)
            Text("ファイルまたはフォルダをドロップ")
                .font(.title3)
            Button("ファイルを追加…") { model.presentOpenPanel(directories: false) }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.clear)
    }
}

private extension View {
    func operationPopupSurface() -> some View {
        modifier(OperationPopupSurface())
    }
}

private struct OperationPopupSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let isDark = colorScheme == .dark
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        content
            .padding(24)
            .background {
                ZStack {
                    shape.fill(.regularMaterial)
                    shape.fill(Color(nsColor: .controlBackgroundColor).opacity(0.84))
                    LinearGradient(
                        colors: [Color.white.opacity(isDark ? 0.08 : 0.35), Color.clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                }
                .clipShape(shape)
                .compositingGroup()
                .shadow(color: .white.opacity(isDark ? 0.10 : 0.42), radius: 1, y: -1)
                .shadow(color: .black.opacity(isDark ? 0.45 : 0.18), radius: 18, y: 8)
            }
    }
}
