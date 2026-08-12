import SwiftUI
import QuickLookUI
import RenameKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var workspace: WorkspaceModel
    @State private var isDropTargeted = false
    @State private var isWorkspaceSidebarVisible = true

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
        .toolbar { toolbarContent }
        .modifier(GlassWindowToolbarBackground())
        .navigationTitle("")
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
        .overlay {
            if let url = model.quickLookURL {
                FinderStyleQuickLook(url: url) {
                    model.quickLookURL = nil
                }
                .transition(
                    .asymmetric(
                        insertion: .scale(scale: 0.72).combined(with: .opacity),
                        removal: .scale(scale: 0.90).combined(with: .opacity)
                    )
                )
                .zIndex(10)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.resultMessage?.id)
        .animation(.spring(response: 0.30, dampingFraction: 0.76), value: model.quickLookURL)
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
        .frame(minWidth: 900, minHeight: 600)
        .modifier(ClearWindowContainerBackground())
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

private struct WorkspaceSidebar: View {
    @EnvironmentObject private var workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("命名作業")
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

private struct FinderStyleQuickLook: View {
    let url: URL
    let dismiss: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.08)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismiss)

                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 22, height: 22)

                        Text(url.lastPathComponent)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Button(action: dismiss) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("クイックルックを閉じる")
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                    .background(.bar)

                    EmbeddedQuickLookView(url: url)
                        .background(Color(nsColor: .windowBackgroundColor))
                }
                .frame(
                    width: min(proxy.size.width * 0.78, 760),
                    height: min(proxy.size.height * 0.78, 560)
                )
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.30), radius: 28, y: 14)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.34), lineWidth: 0.8)
                        .allowsHitTesting(false)
                }
            }
        }
        .onExitCommand(perform: dismiss)
        .accessibilityAddTraits(.isModal)
    }
}

private struct EmbeddedQuickLookView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.shouldCloseWithWindow = false
        context.coordinator.update(url: url, previewView: view)
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        context.coordinator.update(url: url, previewView: nsView)
    }

    static func dismantleNSView(_ nsView: QLPreviewView, coordinator: Coordinator) {
        coordinator.stopAccessing()
        nsView.close()
    }

    final class Coordinator {
        private var currentURL: URL?
        private var isAccessing = false

        func update(url: URL, previewView: QLPreviewView) {
            guard currentURL != url else { return }
            stopAccessing()
            currentURL = url
            isAccessing = url.startAccessingSecurityScopedResource()
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
