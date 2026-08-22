import SwiftUI
import AppKit
import QuickLookUI
import RenameKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var workspace: WorkspaceModel
    @EnvironmentObject private var preferences: AppPreferences
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
                    primaryButton: .default(Text(message.actionTitle ?? "フォルダを選択…")) {
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

private struct WorkspaceSidebar: View {
    @EnvironmentObject private var workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("FileRenamer")
                    .font(.headline.weight(.semibold))

                Spacer()

                Button {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                        workspace.addTab()
                    }
                } label: {
                    Text("＋")
                        .font(.system(size: 15, weight: .regular))
                        .frame(width: 25, height: 25)
                }
                .buttonStyle(.plain)
                .help("新しい命名作業を追加（⌘T）")
                .accessibilityLabel("新しい命名作業を追加")
            }
            .padding(.leading, 13)
            .padding(.trailing, 9)
            .frame(height: 43)

            Color.primary.opacity(0.08)
                .frame(height: 1)

            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    ForEach(workspace.tabs) { tab in
                        WorkspaceSidebarRow(tab: tab, model: tab.model)
                    }
                }
                .padding(7)
            }
            .scrollIndicators(.hidden)

            HStack {
                Text("\(workspace.tabs.count) 件")
                Spacer()
                Text("⌘Tで追加")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Color.primary.opacity(0.025))
        }
        .background(Color.clear)
    }
}

private struct WorkspaceSidebarRow: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    let tab: WorkspaceModel.Tab
    @ObservedObject var model: AppModel
    @State private var isHovering = false

    private var isSelected: Bool { workspace.selectedTabID == tab.id }
    private var showsActions: Bool { isSelected || isHovering }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.14)) {
                    workspace.selectTab(tab.id)
                }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(workspace.title(for: tab))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(model.items.isEmpty ? "ファイル未追加" : "\(model.fileCount) ファイル")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if workspace.tabs.count > 1 {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        workspace.closeTab(tab.id)
                    }
                } label: {
                    Text("×")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 15, height: 15)
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
                .help(model.isBusy ? "処理中のタブは閉じられません" : "タブを閉じる")
                .opacity(showsActions ? 1 : 0)
                .allowsHitTesting(showsActions && !model.isBusy)
            }
        }
        .font(.callout.weight(isSelected ? .semibold : .regular))
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Palette.accent.opacity(0.12))
            } else if isHovering {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .opacity(isSelected ? 1 : 0.88)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .contextMenu {
            ForEach(model.importedDirectories, id: \.path) { directory in
                Button("\(directory.lastPathComponent)をFinderで開く") {
                    model.openDirectoryInFinder(directory)
                }
            }
            if !model.importedDirectories.isEmpty { Divider() }
            Button("タブを閉じる", role: .destructive) {
                workspace.closeTab(tab.id)
            }
            .disabled(workspace.tabs.count == 1 || model.isBusy)
        }
    }
}

/// Owns one non-modal AppKit window, independent from the main SwiftUI window.
/// Repeated force-clicks replace its item instead of creating extra windows.
@MainActor
private final class QuickLookWindowController: NSObject, ObservableObject, NSWindowDelegate {
    private var window: NSWindow?
    private var hostingController: NSHostingController<StandaloneQuickLookContent>?
    private var closeHandler: (() -> Void)?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    func update(url: URL?, onClose: @escaping () -> Void) {
        guard let url else {
            close(notify: false)
            return
        }

        closeHandler = onClose
        let content = StandaloneQuickLookContent(url: url) { [weak self] in
            self?.window?.performClose(nil)
        }

        if let window, let hostingController {
            hostingController.rootView = content
            window.title = url.lastPathComponent
            window.representedURL = url
            attachToPresentingWindowIfNeeded(window)
            startOutsideClickMonitoring(for: window)
            present(window)
            return
        }

        let hostingController = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = url.lastPathComponent
        window.representedURL = url
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 480)
        // A preview opened from a full-screen main window must join that Space as
        // an auxiliary window. Treating it as another full-screen primary window
        // leaves AppKit to manage two independent full-screen sessions, which can
        // make closing the preview destabilize the original window.
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.delegate = self

        // Keep a real, separate preview window, but attach it to the main window
        // while presented. This gives it the correct full-screen lifetime and keeps
        // it in front without relying on a floating window level.
        attachToPresentingWindowIfNeeded(window)

        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let width = min(max(visibleFrame.width * 0.72, 760), 1320)
        let height = min(max(visibleFrame.height * 0.78, 560), 980)
        window.setContentSize(NSSize(width: width, height: height))
        window.center()

        self.hostingController = hostingController
        self.window = window
        startOutsideClickMonitoring(for: window)
        present(window)
    }

    func close(notify: Bool) {
        guard let window else { return }
        stopOutsideClickMonitoring()
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)

        let handler = notify ? closeHandler : nil
        closeHandler = nil
        if let handler {
            DispatchQueue.main.async {
                handler()
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Keep the native QLPreviewView alive and reuse it. Destroying it on every
        // outside click terminates Quick Look's remote view service and produces
        // ViewBridge Code 18 / task-port diagnostics in Xcode.
        close(notify: true)
        return false
    }

    private func present(_ window: NSWindow) {
        // A force-click release can make the main window key again later in the
        // current event cycle. Presenting on the next cycle avoids that race, while
        // making the preview key on the next cycle avoids that race while its parent
        // relationship keeps it in the correct full-screen Space.
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// `close` intentionally keeps the Quick Look view alive, so reopening an
    /// existing preview must attach it again. At that point the main window is key;
    /// while an already-visible preview is updated it remains attached and is left
    /// alone.
    private func attachToPresentingWindowIfNeeded(_ previewWindow: NSWindow) {
        guard previewWindow.parent == nil,
              let presentingWindow = NSApp.keyWindow,
              presentingWindow !== previewWindow
        else { return }

        presentingWindow.addChildWindow(previewWindow, ordered: .above)
    }

    private func startOutsideClickMonitoring(for previewWindow: NSWindow) {
        stopOutsideClickMonitoring()

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self, weak previewWindow] event in
            if let previewWindow, event.window !== previewWindow {
                self?.close(notify: true)
            }
            return event
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            self?.close(notify: true)
        }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.close(notify: true)
            }
        }
    }

    private func stopOutsideClickMonitoring() {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        localMouseMonitor = nil
        globalMouseMonitor = nil
        resignObserver = nil
    }
}

private struct StandaloneQuickLookContent: View {
    let url: URL
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            EmbeddedQuickLookView(url: url)
                .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)

                Text(url.lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button("Finderで表示") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }

                Button("閉じる", action: dismiss)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(.bar)
        }
        .frame(minWidth: 640, minHeight: 480)
        .onExitCommand(perform: dismiss)
    }
}

/// Duplicate review, one group at a time.
///
/// Similar pictures arrive as clusters — a burst of five near-identical frames is one
/// decision, not ten pairwise ones — so the sheet shows a list of groups on the left
/// and the pictures of the selected group on the right. Choices accumulate across
/// groups and are applied once at the end, so a long import is swept in a single pass.
///
/// Nothing is preselected: visually similar photos can still be different moments,
/// and only the person who took them knows. Deletion moves files to the Trash, so a
/// wrong call made from a thumbnail is always recoverable.
private struct SimilarImageReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    let review: AppModel.SimilarityReview

    @State private var focusedGroupID: UUID
    @State private var selectedIDs: Set<UUID> = []
    @State private var isConfirmingTrash = false
    /// Non-nil while one picture of the focused group fills the sheet.
    @State private var zoomedItemID: UUID?
    /// `onKeyPress` only fires on a focused view, so the zoom layer claims focus for
    /// as long as it is up.
    @FocusState private var isZoomFocused: Bool
    /// The card Space would preview — the last one the pointer touched.
    @State private var lastTouchedItemID: UUID?

    init(review: AppModel.SimilarityReview) {
        self.review = review
        _focusedGroupID = State(initialValue: review.focusedGroupID)
    }

    private var groups: [AppModel.DuplicateGroup] { review.groups }

    private var focusedGroup: AppModel.DuplicateGroup? {
        groups.first { $0.id == focusedGroupID } ?? groups.first
    }

    private var focusedIndex: Int {
        groups.firstIndex { $0.id == focusedGroupID } ?? 0
    }

    private var allItems: [RenameItem] {
        groups.flatMap(\.items)
    }

    private var selectedItems: [RenameItem] {
        allItems.filter { selectedIDs.contains($0.id) }
    }

    private var selectedFileCount: Int {
        selectedItems.reduce(0) { $0 + $1.allURLs.count }
    }

    private var selectedByteCount: Int64 {
        selectedItems.reduce(0) { $0 + ($1.metadata.fileSize ?? 0) }
    }

    /// Emptying a whole group is almost never the intent, and it is the one mistake
    /// the Trash makes tedious rather than trivial to undo.
    private var groupsFullySelected: [AppModel.DuplicateGroup] {
        groups.filter { group in
            !group.items.isEmpty && group.items.allSatisfy { selectedIDs.contains($0.id) }
        }
    }

    private var canDelete: Bool {
        !selectedIDs.isEmpty && groupsFullySelected.isEmpty && !model.isBusy
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            HStack(spacing: 0) {
                groupList
                    .frame(width: 232)
                Divider()
                groupDetail
                    .frame(maxWidth: .infinity)
            }

            Divider()
            footer
        }
        .frame(width: 980, height: 720)
        .overlay {
            if let zoomed = zoomedItem {
                zoomView(for: zoomed)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: zoomedItemID)
        .confirmationDialog(
            "\(selectedItems.count) 件をゴミ箱に移動しますか？",
            isPresented: $isConfirmingTrash,
            titleVisibility: .visible
        ) {
            Button("ゴミ箱に移動", role: .destructive) {
                model.moveToTrash(ids: selectedIDs)
                dismiss()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text(trashConfirmationDetail)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("重複している可能性のある画像")
                    .font(.title2.weight(.semibold))
                Text("\(groups.count) 組 · \(allItems.count) 枚。残すものと削除するものを選んでください。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if groups.count > 1 {
                HStack(spacing: 6) {
                    Button {
                        step(-1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(focusedIndex == 0 || zoomedItemID != nil)
                    .keyboardShortcut(.leftArrow, modifiers: [])

                    Text("\(focusedIndex + 1) / \(groups.count)")
                        .font(.system(.callout, design: .monospaced))
                        .frame(minWidth: 56)

                    Button {
                        step(1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(focusedIndex >= groups.count - 1 || zoomedItemID != nil)
                    .keyboardShortcut(.rightArrow, modifiers: [])
                }
                .help("組を切り替えます")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Group list

    private var groupList: some View {
        ScrollViewReader { proxy in
            List(selection: Binding(
                get: { focusedGroupID },
                set: { if let id = $0 { focusedGroupID = id } }
            )) {
                ForEach(groups) { group in
                    groupRow(group)
                        .tag(group.id)
                        .id(group.id)
                }
            }
            .listStyle(.sidebar)
            .onChange(of: focusedGroupID) { _, id in
                // The zoom belongs to the group it was opened from.
                zoomedItemID = nil
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
        }
    }

    private func groupRow(_ group: AppModel.DuplicateGroup) -> some View {
        let selectedInGroup = group.items.filter { selectedIDs.contains($0.id) }.count
        return HStack(spacing: 10) {
            ThumbnailView(url: group.items[0].originalURL, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(group.count) 枚")
                    .font(.callout.weight(.medium))
                Text(group.containsExactMatch ? "完全一致を含む" : "類似")
                    .font(.caption)
                    .foregroundStyle(group.containsExactMatch
                                     ? Palette.duplicateExact
                                     : Palette.duplicateSimilar)
            }

            Spacer()

            if selectedInGroup > 0 {
                Text("\(selectedInGroup)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Palette.error, in: Capsule())
                    .help("\(selectedInGroup) 件を削除対象にしています")
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - Group detail

    @ViewBuilder
    private var groupDetail: some View {
        if let group = focusedGroup {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text(group.containsExactMatch ? "完全一致を含む組" : "類似している組")
                        .font(.headline)
                        .foregroundStyle(group.containsExactMatch
                                         ? Palette.duplicateExact
                                         : Palette.duplicateSimilar)

                    Spacer()

                    Button("最初の1枚以外を選択") { selectAllButFirst(in: group) }
                        .help("先頭を残し、同じ組の残りを削除対象にします")
                    Button("この組の選択を解除") { deselectAll(in: group) }
                        .disabled(!group.items.contains { selectedIDs.contains($0.id) })
                }

                if group.items.allSatisfy({ selectedIDs.contains($0.id) }) {
                    Label("この組はすべて削除対象です。1 枚は残してください。", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Palette.warning)
                }

                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 16)],
                        spacing: 16
                    ) {
                        ForEach(group.items) { item in
                            card(for: item)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.space) {
                    let target = lastTouchedItemID.flatMap { id in
                        group.items.first { $0.id == id }
                    } ?? group.items.first
                    guard let target else { return .ignored }
                    zoom(to: target)
                    return .handled
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        } else {
            Text("表示できる組がありません")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func card(for item: RenameItem) -> some View {
        let isSelected = selectedIDs.contains(item.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("削除", isOn: binding(for: item))
                    .toggleStyle(.checkbox)
                    .font(.callout)
                    .foregroundStyle(isSelected ? Palette.error : Color.secondary)
                Spacer()
                Button {
                    zoom(to: item)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help("プレビュー（ダブルクリック / スペースキーでも開きます）")

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([item.originalURL])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Finderで表示")
            }

            ThumbnailView(url: item.originalURL, size: 200)
                .frame(maxWidth: .infinity)
                .opacity(isSelected ? 0.45 : 1)
                .overlay(alignment: .topLeading) {
                    if isSelected {
                        Label("削除", systemImage: "trash.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Palette.error, in: Capsule())
                            .padding(6)
                    }
                }

            Text(item.displayName)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.displayName)

            HStack(spacing: 6) {
                if let dimensions = dimensionsText(for: item) {
                    Text(dimensions)
                }
                if let size = item.metadata.fileSize {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                }
                if item.allURLs.count > 1 {
                    Text("\(item.allURLs.count)ファイル")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    isSelected ? Palette.error : Color.primary.opacity(0.10),
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .contentShape(Rectangle())
        // Deletion is deliberately available only from the checkbox. A double click
        // is reserved for preview and must never change the deletion selection.
        .onTapGesture(count: 2) { zoom(to: item) }
        .onHover { isHovering in
            if isHovering { lastTouchedItemID = item.id }
        }
    }

    // MARK: - Zoom

    private var zoomedItem: RenameItem? {
        guard let zoomedItemID else { return nil }
        return focusedGroup?.items.first { $0.id == zoomedItemID }
    }

    /// Fills the sheet with one picture so two near-identical frames can be flicked
    /// between at the same size and position — the only reliable way to see which of
    /// them is the one worth keeping.
    private func zoomView(for item: RenameItem) -> some View {
        let group = focusedGroup
        let index = group?.items.firstIndex { $0.id == item.id } ?? 0
        let total = group?.items.count ?? 1
        let isSelected = selectedIDs.contains(item.id)

        return ZStack {
            Color.black.opacity(0.82)
                .ignoresSafeArea()
                .onTapGesture { zoomedItemID = nil }

            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Text(item.displayName)
                        .font(.system(.callout, design: .monospaced).weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let detail = zoomDetailText(for: item) {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    Spacer()

                    Toggle("削除", isOn: binding(for: item))
                        .toggleStyle(.checkbox)
                        .font(.callout)
                        .foregroundStyle(isSelected ? Palette.error : .white)

                    Button {
                        zoomedItemID = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .help("閉じる（Esc）")
                }
                .foregroundStyle(.white)

                LargeImageView(url: item.originalURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Palette.error, lineWidth: 3)
                        }
                    }

                HStack(spacing: 16) {
                    Button {
                        stepZoom(-1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(index == 0)

                    Text("\(index + 1) / \(total)")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.white)

                    Button {
                        stepZoom(1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(index >= total - 1)
                }
            }
            .padding(20)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isZoomFocused)
        .onAppear { isZoomFocused = true }
        // Arrow keys move between the pictures of this group while zoomed.
        .onKeyPress(.leftArrow) { stepZoom(-1); return .handled }
        .onKeyPress(.rightArrow) { stepZoom(1); return .handled }
        .onKeyPress(.escape) { zoomedItemID = nil; return .handled }
        .onExitCommand { zoomedItemID = nil }
    }

    private func zoomDetailText(for item: RenameItem) -> String? {
        var parts: [String] = []
        if let dimensions = dimensionsText(for: item) { parts.append(dimensions) }
        if let size = item.metadata.fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func zoom(to item: RenameItem) {
        zoomedItemID = item.id
    }

    private func stepZoom(_ delta: Int) {
        guard let group = focusedGroup,
              let current = group.items.firstIndex(where: { $0.id == zoomedItemID })
        else { return }
        let target = current + delta
        guard group.items.indices.contains(target) else { return }
        zoomedItemID = group.items[target].id
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Label("画像の比較はこのMac内で行われます", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Text(selectionSummary)
                .font(.callout)
                .foregroundStyle(selectedIDs.isEmpty ? .secondary : .primary)

            Button("\(selectedIDs.count) 件をリストから除外") {
                model.removeFromList(ids: selectedIDs)
                dismiss()
            }
            .disabled(selectedIDs.isEmpty || model.isBusy)
            .help("ファイルは残したまま、この一覧からだけ外します")

            Button("ゴミ箱に移動…", role: .destructive) { isConfirmingTrash = true }
                .disabled(!canDelete)
                .help(groupsFullySelected.isEmpty
                      ? "選択したファイルをゴミ箱に移動します"
                      : "すべてが削除対象の組があります")

            Button("閉じる") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var selectionSummary: String {
        guard !selectedIDs.isEmpty else { return "選択なし" }
        var text = "\(selectedItems.count) 件を選択中"
        if selectedFileCount != selectedItems.count {
            text += "（\(selectedFileCount) ファイル）"
        }
        if selectedByteCount > 0 {
            text += " · \(ByteCountFormatter.string(fromByteCount: selectedByteCount, countStyle: .file))"
        }
        return text
    }

    private var trashConfirmationDetail: String {
        let names = selectedItems.prefix(5).map(\.displayName).joined(separator: "\n")
        let remainder = selectedItems.count > 5 ? "\nほか \(selectedItems.count - 5) 件" : ""
        return "ファイルはゴミ箱に移動され、Finder から元に戻せます。\n\n\(names)\(remainder)"
    }

    // MARK: - Selection

    private func step(_ delta: Int) {
        let target = focusedIndex + delta
        guard groups.indices.contains(target) else { return }
        focusedGroupID = groups[target].id
        zoomedItemID = nil
    }

    private func selectAllButFirst(in group: AppModel.DuplicateGroup) {
        selectedIDs.formUnion(group.items.dropFirst().map(\.id))
        selectedIDs.remove(group.items[0].id)
    }

    private func deselectAll(in group: AppModel.DuplicateGroup) {
        selectedIDs.subtract(group.items.map(\.id))
    }

    private func binding(for item: RenameItem) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(item.id) },
            set: { isSelected in
                if isSelected {
                    selectedIDs.insert(item.id)
                } else {
                    selectedIDs.remove(item.id)
                }
            }
        )
    }

    private func dimensionsText(for item: RenameItem) -> String? {
        guard let width = item.metadata.pixelWidth, let height = item.metadata.pixelHeight else { return nil }
        return "\(width)×\(height) px"
    }
}

private struct RenameConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    let confirmation: AppModel.RenameConfirmation
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("変更内容を確認")
                    .font(.title2.weight(.semibold))
                Text("次の内容でファイルを変更します。実行前に確認してください。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            summary

            if confirmation.replacesOriginalImages {
                Label(
                    "画像データを再生成し、元画像を置き換えます。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(Palette.warning)
            } else if let directory = confirmation.originalImagesDirectory {
                Label {
                    Text("元画像を「\(directory.lastPathComponent)」に保存します。")
                } icon: {
                    Image(systemName: "folder.badge.plus")
                }
                .font(.callout)
            }

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("変更前")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right")
                        .hidden()
                    Text("変更後")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)

                Divider()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(confirmation.rows) { row in
                            confirmationRow(row)
                            if row.id != confirmation.rows.last?.id { Divider() }
                        }
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            }

            HStack {
                Text("実行直前にも保存先の衝突を再確認します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("変更を実行") { confirm() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 820, height: 620)
    }

    private var summary: some View {
        HStack(spacing: 0) {
            summaryValue("対象", value: "\(confirmation.changedItemCount)件")
            Divider().frame(height: 32)
            summaryValue("名前変更", value: "\(confirmation.renamedFileCount)ファイル")
            Divider().frame(height: 32)
            summaryValue("画像処理", value: "\(confirmation.processedImageCount)ファイル")
            if confirmation.warningCount > 0 {
                Divider().frame(height: 32)
                summaryValue("警告", value: "\(confirmation.warningCount)件", tint: Palette.warning)
            }
        }
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

    private func summaryValue(_ title: String, value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
    }

    private func confirmationRow(_ row: AppModel.RenameConfirmationRow) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                Text(row.sourceName)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: row.changesName ? "arrow.right" : "equal")
                    .foregroundStyle(.tertiary)
                Text(row.destinationName)
                    .foregroundStyle(row.changesName ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(.callout, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)

            HStack(spacing: 8) {
                Text(URL(fileURLWithPath: row.sourceDirectoryPath).lastPathComponent)
                    .help(row.sourceDirectoryPath)
                if let imageChange = row.imageChange {
                    Label(imageChange, systemImage: "photo")
                }
                if let warning = row.warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.warning)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

private struct EmbeddedQuickLookView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.shouldCloseWithWindow = false
        view.setAccessibilityLabel("クイックルックプレビュー")
        context.coordinator.update(url: url, previewView: view)
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        context.coordinator.update(url: url, previewView: nsView)
    }

    static func dismantleNSView(_ nsView: QLPreviewView, coordinator: Coordinator) {
        nsView.previewItem = nil
        coordinator.stopAccessing()
        // Do not call QLPreviewView.close() here. AppKit owns the final teardown;
        // explicitly closing during SwiftUI dismantling races its RemoteViewService.
    }

    final class Coordinator {
        private var currentURL: URL?
        private var isAccessing = false

        func update(url: URL, previewView: QLPreviewView) {
            guard currentURL != url else { return }
            stopAccessing()
            currentURL = url
            isAccessing = url.startAccessingSecurityScopedResource()
            // QLPreviewView uses the system Quick Look generator, so PDF pages,
            // images, video, audio and supported documents share one native view.
            previewView.previewItem = nil
            previewView.previewItem = url as NSURL
            previewView.refreshPreviewItem()
        }

        func stopAccessing() {
            if isAccessing { currentURL?.stopAccessingSecurityScopedResource() }
            isAccessing = false
            currentURL = nil
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
        padding(24)
            .background {
                let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
                shape.fill(.regularMaterial)
                shape.fill(Color(nsColor: .controlBackgroundColor).opacity(0.84))
                LinearGradient(
                    colors: [Color.white.opacity(0.35), Color.clear],
                    startPoint: .top,
                    endPoint: .center
                )
                .clipShape(shape)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .white.opacity(0.42), radius: 1, y: -1)
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }
}
