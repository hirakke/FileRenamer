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
        .alert(L10n.string("main.undoTheRename", defaultValue: "Undo the rename?", language: preferences.resolvedLanguage), isPresented: $model.isUndoConfirmationPresented) {
            Button(L10n.string("main.cancel", defaultValue: "Cancel", language: preferences.resolvedLanguage), role: .cancel) {}
            Button(L10n.string("main.undo", defaultValue: "Undo", language: preferences.resolvedLanguage), role: .destructive) {
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
            Button(L10n.string("main.moveToTrash", defaultValue: "Move to Trash", language: preferences.resolvedLanguage), role: .destructive) {
                model.confirmMoveToTrash()
            }
            Button(L10n.string("main.cancel", defaultValue: "Cancel", language: preferences.resolvedLanguage), role: .cancel) {
                model.cancelMoveToTrashConfirmation()
            }
        } message: {
            Text(trashConfirmationDetail)
        }
        .confirmationDialog(
            L10n.string("main.keepTheOriginalImages", defaultValue: "Keep the original images?", language: preferences.resolvedLanguage),
            isPresented: $model.isImageResizeOriginalChoicePresented,
            titleVisibility: .visible
        ) {
            Button(L10n.string("main.keepOriginalsAndChooseLocation", defaultValue: "Keep Originals and Choose Location", language: preferences.resolvedLanguage)) {
                model.chooseOriginalImagesDestinationForResize()
            }
            Button(L10n.string("main.replaceOriginals", defaultValue: "Replace Originals", language: preferences.resolvedLanguage), role: .destructive) {
                model.replaceOriginalImagesForResize()
            }
            Button(L10n.string("main.cancel", defaultValue: "Cancel", language: preferences.resolvedLanguage), role: .cancel) {}
        } message: {
            Text(L10n.string("main.imageConversionAndResizingRecreate", defaultValue: "Image conversion and resizing recreate image data. To keep originals, name the folder and choose where to save it.", language: preferences.resolvedLanguage))
        }
        .alert(L10n.string("main.originalImagesFolderName", defaultValue: "Original Images Folder Name", language: preferences.resolvedLanguage), isPresented: $model.isOriginalImagesFolderNamePresented) {
            TextField(L10n.string("main.folderName", defaultValue: "Folder Name", language: preferences.resolvedLanguage), text: $model.originalImagesFolderName)
            Button(L10n.string("main.cancel", defaultValue: "Cancel", language: preferences.resolvedLanguage), role: .cancel) {}
            Button(L10n.string("main.chooseLocation", defaultValue: "Choose Location", language: preferences.resolvedLanguage)) {
                model.confirmOriginalImagesFolderName()
            }
        } message: {
            Text(L10n.string("main.aNewFolderWithThis", defaultValue: "A new folder with this name will be created in the selected location.", language: preferences.resolvedLanguage))
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
                    Button(L10n.string("main.cancel", defaultValue: "Cancel", language: preferences.resolvedLanguage)) { model.cancelBusyOperation() }
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
                        Button(L10n.string("main.undo", defaultValue: "Undo", language: preferences.resolvedLanguage)) {
                            model.requestUndo()
                        }
                    }
                    Button(L10n.string("settings.close", defaultValue: "Close", language: preferences.resolvedLanguage)) {
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
                Label(L10n.string("main.sidebar", defaultValue: "Sidebar", language: preferences.resolvedLanguage), systemImage: "sidebar.leading")
            }
            .help(isWorkspaceSidebarVisible ? L10n.string("main.hideTabBar", defaultValue: "Hide Sidebar", language: preferences.resolvedLanguage) : L10n.string("main.showTabBar", defaultValue: "Show Sidebar", language: preferences.resolvedLanguage))
        }

        ToolbarItemGroup {
            Button {
                model.presentOpenPanel(directories: false)
            } label: {
                Label(L10n.string("main.addFiles", defaultValue: "Add Files", language: preferences.resolvedLanguage), systemImage: "doc.badge.plus")
            }
            .tutorialTip(AddFilesTip(language: preferences.resolvedLanguage), step: 0, arrowEdge: .top)

            Button {
                model.presentOpenPanel(directories: true)
            } label: {
                Label(L10n.string("main.addFolder", defaultValue: "Add Folder", language: preferences.resolvedLanguage), systemImage: "folder.badge.plus")
            }

            Menu {
                ForEach(SortField.allCases, id: \.self) { field in
                    Menu(field.localizedDisplayName(in: preferences.resolvedLanguage)) {
                        Button(L10n.string("main.ascending", defaultValue: "Ascending", language: preferences.resolvedLanguage)) { model.applySort(SortDescriptorOption(field: field, ascending: true)) }
                        Button(L10n.string("main.descending", defaultValue: "Descending", language: preferences.resolvedLanguage)) { model.applySort(SortDescriptorOption(field: field, ascending: false)) }
                    }
                }
                Divider()
                Button(L10n.string("main.reverseOrder", defaultValue: "Reverse Order", language: preferences.resolvedLanguage)) { model.reverseOrder() }
                Divider()
                Toggle(L10n.string("main.groupRawJpeg", defaultValue: "Group RAW + JPEG", language: preferences.resolvedLanguage), isOn: $model.importOptions.groupCompanionFiles)
            } label: {
                Label(L10n.string("main.sort", defaultValue: "Sort", language: preferences.resolvedLanguage), systemImage: "arrow.up.arrow.down")
            }

            Picker(L10n.string("settings.display", defaultValue: "Display", language: preferences.resolvedLanguage), selection: $model.viewMode) {
                ForEach(ViewMode.allCases) { mode in
                    Image(systemName: mode.systemImageName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .help(L10n.string("main.switchBetweenListAndGrid", defaultValue: "Switch between list and grid views", language: preferences.resolvedLanguage))

            Button {
                model.requestUndo()
            } label: {
                Label(L10n.string("main.undo", defaultValue: "Undo", language: preferences.resolvedLanguage), systemImage: "arrow.uturn.backward")
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
    @Environment(\.locale) private var locale
    private var language: ResolvedAppLanguage { ResolvedAppLanguage(locale: locale) }
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tertiary)
            Text(L10n.string("main.dropFilesOrAFolder", defaultValue: "Drop Files or a Folder", language: language))
                .font(.title3)
            Button(L10n.string("main.addFiles2", defaultValue: "Add Files…", language: language)) { model.presentOpenPanel(directories: false) }
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
