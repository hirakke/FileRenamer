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
            Alert(title: Text(message.title), message: Text(message.detail), dismissButton: .default(Text("OK")))
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
            : "\(first.lastPathComponent) ほか\(model.workingDirectories.count - 1)か所"
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
                Label("命名作業ナビゲータ", systemImage: "sidebar.leading")
            }
            .help(isWorkspaceSidebarVisible ? "命名作業ナビゲータを隠す" : "命名作業ナビゲータを表示")
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
                    Menu(field.displayName) {
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
        window.collectionBehavior = [.fullScreenPrimary]
        window.level = .floating
        window.delegate = self

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
        // the floating level keeps the preview visually in front until a real click.
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
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

/// A review surface, not a deletion workflow. It deliberately makes no automatic
/// choice because visually similar photos can still represent different moments.
private struct SimilarImageReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let review: AppModel.SimilarityReview

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("類似している可能性のある画像")
                    .font(.title2.weight(.semibold))
                Text("内容を比較して確認してください。ファイルは自動的に削除・除外されません。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(spacing: 18) {
                    ForEach(review.candidates) { candidate in
                        HStack(alignment: .center, spacing: 18) {
                            comparisonCard(
                                item: review.source,
                                label: "基準画像",
                                detail: nil
                            )

                            Image(systemName: "arrow.left.and.right")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.secondary)

                            comparisonCard(
                                item: candidate.item,
                                label: candidate.kind == .exact ? "完全一致" : "類似候補",
                                detail: candidate.kind == .exact
                                    ? "ファイル内容が一致しています"
                                    : "見た目が似ている可能性があります"
                            )
                        }
                        if candidate.id != review.candidates.last?.id { Divider() }
                    }
                }
                .padding(.vertical, 4)
            }

            HStack {
                Label("画像の比較はこのMac内で行われます", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 920, height: 680)
    }

    private func comparisonCard(
        item: RenameItem,
        label: String,
        detail: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label)
                .font(.headline)
                .foregroundStyle(label == "完全一致" ? Palette.warning : Color.primary)

            ThumbnailView(url: item.originalURL, size: 300)

            Text(item.displayName)
                .font(.system(.callout, design: .monospaced).weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.displayName)

            HStack(spacing: 8) {
                if let dimensions = dimensionsText(for: item) {
                    Text(dimensions)
                }
                if let size = item.metadata.fileSize {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Finderで表示") {
                NSWorkspace.shared.activateFileViewerSelecting([item.originalURL])
            }
            .buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 375, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
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
