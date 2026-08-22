import SwiftUI
import AppKit
import Combine
import RenameKit

@MainActor
final class AppPreferences: ObservableObject {
    private enum Key {
        static let confirmsRenameChanges = "preferences.confirmsRenameChanges"
        static let confirmsOriginalProtection = "preferences.confirmsOriginalProtection"
        static let confirmsUndo = "preferences.confirmsUndo"
        static let preventsUpscalingByDefault = "preferences.preventsUpscalingByDefault"
        static let preservesJPEGAtMaximumQuality = "preferences.preservesJPEGAtMaximumQuality"
        static let defaultViewMode = "preferences.defaultViewMode"
        static let opensSidebarOnLaunch = "preferences.opensSidebarOnLaunch"
        static let gridColumnCount = "gridColumnCount"
        static let detectsSimilarImages = "preferences.detectsSimilarImages"
        static let similarImageSensitivity = "preferences.similarImageSensitivity"
        static let detectsOnlyExactDuplicates = "preferences.detectsOnlyExactDuplicates"
        static let excludesRAWJPEGFromSimilarity = "preferences.excludesRAWJPEGFromSimilarity"
    }

    private let defaults: UserDefaults

    @Published var confirmsRenameChanges: Bool {
        didSet { defaults.set(confirmsRenameChanges, forKey: Key.confirmsRenameChanges) }
    }
    @Published var confirmsOriginalProtection: Bool {
        didSet { defaults.set(confirmsOriginalProtection, forKey: Key.confirmsOriginalProtection) }
    }
    @Published var confirmsUndo: Bool {
        didSet { defaults.set(confirmsUndo, forKey: Key.confirmsUndo) }
    }
    @Published var preventsUpscalingByDefault: Bool {
        didSet { defaults.set(preventsUpscalingByDefault, forKey: Key.preventsUpscalingByDefault) }
    }
    @Published var preservesJPEGAtMaximumQuality: Bool {
        didSet { defaults.set(preservesJPEGAtMaximumQuality, forKey: Key.preservesJPEGAtMaximumQuality) }
    }
    @Published var defaultViewMode: ViewMode {
        didSet { defaults.set(defaultViewMode.rawValue, forKey: Key.defaultViewMode) }
    }
    @Published var opensSidebarOnLaunch: Bool {
        didSet { defaults.set(opensSidebarOnLaunch, forKey: Key.opensSidebarOnLaunch) }
    }
    @Published var gridColumnCount: Int {
        didSet {
            let normalized = max(2, min(gridColumnCount, 8))
            if gridColumnCount != normalized {
                gridColumnCount = normalized
            } else {
                defaults.set(normalized, forKey: Key.gridColumnCount)
            }
        }
    }
    @Published var detectsSimilarImages: Bool {
        didSet { defaults.set(detectsSimilarImages, forKey: Key.detectsSimilarImages) }
    }
    @Published var similarImageSensitivity: SimilarImageSensitivity {
        didSet { defaults.set(similarImageSensitivity.rawValue, forKey: Key.similarImageSensitivity) }
    }
    @Published var detectsOnlyExactDuplicates: Bool {
        didSet { defaults.set(detectsOnlyExactDuplicates, forKey: Key.detectsOnlyExactDuplicates) }
    }
    @Published var excludesRAWJPEGFromSimilarity: Bool {
        didSet { defaults.set(excludesRAWJPEGFromSimilarity, forKey: Key.excludesRAWJPEGFromSimilarity) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.confirmsRenameChanges: true,
            Key.confirmsOriginalProtection: true,
            Key.confirmsUndo: true,
            Key.preventsUpscalingByDefault: true,
            Key.preservesJPEGAtMaximumQuality: true,
            Key.defaultViewMode: ViewMode.list.rawValue,
            Key.opensSidebarOnLaunch: true,
            Key.gridColumnCount: 4,
            Key.detectsSimilarImages: true,
            Key.similarImageSensitivity: SimilarImageSensitivity.standard.rawValue,
            Key.detectsOnlyExactDuplicates: false,
            Key.excludesRAWJPEGFromSimilarity: true
        ])
        confirmsRenameChanges = defaults.bool(forKey: Key.confirmsRenameChanges)
        confirmsOriginalProtection = defaults.bool(forKey: Key.confirmsOriginalProtection)
        confirmsUndo = defaults.bool(forKey: Key.confirmsUndo)
        preventsUpscalingByDefault = defaults.bool(forKey: Key.preventsUpscalingByDefault)
        preservesJPEGAtMaximumQuality = defaults.bool(forKey: Key.preservesJPEGAtMaximumQuality)
        defaultViewMode = defaults.string(forKey: Key.defaultViewMode)
            .flatMap(ViewMode.init(rawValue:)) ?? .list
        opensSidebarOnLaunch = defaults.bool(forKey: Key.opensSidebarOnLaunch)
        gridColumnCount = max(2, min(defaults.integer(forKey: Key.gridColumnCount), 8))
        detectsSimilarImages = defaults.bool(forKey: Key.detectsSimilarImages)
        similarImageSensitivity = defaults.string(forKey: Key.similarImageSensitivity)
            .flatMap(SimilarImageSensitivity.init(rawValue:)) ?? .standard
        detectsOnlyExactDuplicates = defaults.bool(forKey: Key.detectsOnlyExactDuplicates)
        excludesRAWJPEGFromSimilarity = defaults.bool(forKey: Key.excludesRAWJPEGFromSimilarity)
    }

    var similarImageScanConfiguration: SimilarImageScanConfiguration {
        SimilarImageScanConfiguration(
            exactMatchesOnly: detectsOnlyExactDuplicates,
            sensitivity: similarImageSensitivity,
            excludesRAWJPEGCompanions: excludesRAWJPEGFromSimilarity
        )
    }
}

@MainActor
final class WorkspaceModel: ObservableObject {
    struct Tab: Identifiable {
        let id: UUID
        let model: AppModel
    }

    @Published private(set) var tabs: [Tab]
    @Published var selectedTabID: UUID
    private let preferences: AppPreferences
    private var preferenceCancellables: Set<AnyCancellable> = []

    init(preferences: AppPreferences) {
        self.preferences = preferences
        let id = UUID()
        let model = AppModel(preferences: preferences)
        tabs = [Tab(id: id, model: model)]
        selectedTabID = id

        preferences.$defaultViewMode
            .dropFirst()
            .sink { [weak self] mode in
                self?.tabs.forEach { $0.model.viewMode = mode }
            }
            .store(in: &preferenceCancellables)
        preferences.$preservesJPEGAtMaximumQuality
            .dropFirst()
            .sink { [weak self] _ in
                self?.tabs.forEach { $0.model.preferencesDidChange() }
            }
            .store(in: &preferenceCancellables)

        Publishers.Merge4(
            preferences.$detectsSimilarImages.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            preferences.$similarImageSensitivity.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            preferences.$detectsOnlyExactDuplicates.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            preferences.$excludesRAWJPEGFromSimilarity.dropFirst().map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self] in
            self?.tabs.forEach { $0.model.similarityPreferencesDidChange() }
        }
        .store(in: &preferenceCancellables)
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
            preferences: preferences,
            recoversPendingRenames: false
        )
        tabs.append(Tab(id: id, model: model))
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
        if wasSelected {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    func title(for tab: Tab) -> String {
        let directories = tab.model.workingDirectories
        if let first = directories.first {
            return directories.count == 1
                ? first.lastPathComponent
                : "\(first.lastPathComponent) ほか\(directories.count - 1)件"
        }
        let index = tabs.firstIndex(where: { $0.id == tab.id }) ?? 0
        return "Tab \(index + 1)"
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

private enum MainWindow {
    static let id = "main-window"
}

/// Keeps a permanent way back to the main workspace after its last window was
/// closed. This is intentionally in the standard Window menu, matching macOS
/// conventions and App Store review expectations.
private struct MainWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowList) {
            Divider()
            Button("FileRenamerを開く") {
                openWindow(id: MainWindow.id)
            }
        }
    }
}

/// The Edit menu owns ⌘Z. When the focus is in a native text editor, forwarding the
/// selector preserves normal typing Undo; otherwise the same shortcut reverts the
/// in-memory file ordering.
private enum UndoCommandRouter {
    static var isEditingText: Bool {
        var responder = NSApp.keyWindow?.firstResponder
        for _ in 0..<12 {
            guard let current = responder else { return false }
            if current is NSTextView { return true }
            responder = current.nextResponder
        }
        return false
    }

    static func performNativeUndo() {
        NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
    }

    static func performNativeRedo() {
        NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
    }
}

@main
struct FileRenamerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var preferences: AppPreferences
    @StateObject private var workspace: WorkspaceModel

    init() {
        let preferences = AppPreferences()
        _preferences = StateObject(wrappedValue: preferences)
        _workspace = StateObject(wrappedValue: WorkspaceModel(preferences: preferences))
    }

    var body: some Scene {
        WindowGroup("FileRenamer", id: MainWindow.id) {
            ContentView()
                .environmentObject(workspace.activeModel)
                .environmentObject(workspace)
                .environmentObject(preferences)
                .onAppear { appDelegate.workspace = workspace }
        }
        .windowToolbarStyle(.unified)
        .commands {
            MainWindowCommands()

            CommandGroup(replacing: .newItem) {
                Button("新規タブ") { workspace.addTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Divider()
                Button("ファイルを追加…") { workspace.activeModel.presentOpenPanel(directories: false) }
                    .keyboardShortcut("o", modifiers: .command)
                Button("フォルダを追加…") { workspace.activeModel.presentOpenPanel(directories: true) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }

            // Replace the stock commands so ⌘Z reaches ordering changes instead of
            // being consumed by an empty window Undo manager. Text fields retain
            // their native Undo/Redo through the first-responder chain.
            // Filesystem Undo deliberately remains ⌥⌘Z because it alters files.
            CommandGroup(replacing: .undoRedo) {
                Button("取り消す") {
                    if UndoCommandRouter.isEditingText {
                        UndoCommandRouter.performNativeUndo()
                    } else {
                        workspace.activeModel.undoOrderChange()
                    }
                }
                    .keyboardShortcut("z", modifiers: .command)
                Button("やり直す") {
                    if UndoCommandRouter.isEditingText {
                        UndoCommandRouter.performNativeRedo()
                    } else {
                        workspace.activeModel.redoOrderChange()
                    }
                }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
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
                Button("\(workspace.activeModel.selection.count) 件をリストから除外") { workspace.activeModel.removeSelected() }
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

        Settings {
            PreferencesView()
                .environmentObject(preferences)
        }
    }
}

private struct PreferencesView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @State private var showsPrivacyPolicy = false

    var body: some View {
        Form {
            Section("確認") {
                Toggle("実行前に変更内容を確認", isOn: $preferences.confirmsRenameChanges)
                Text("変更前後のファイル名、画像処理、原本の扱いを一覧で確認します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("画像を変換・リサイズする前に原本の扱いを確認", isOn: $preferences.confirmsOriginalProtection)
                Text("オフの場合は元画像を置き換えます。ファイル名の衝突防止と失敗時の復元は常に有効です。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Undoの前に確認", isOn: $preferences.confirmsUndo)
            }

            Section("画像処理") {
                Toggle("リサイズでは拡大を防ぐ設定を初期値にする", isOn: $preferences.preventsUpscalingByDefault)
                Text("画像設定でリサイズを新しく有効にしたときに適用します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("JPEG 100%・同形式・リサイズなしでは再圧縮しない", isOn: $preferences.preservesJPEGAtMaximumQuality)
                Text("オンの場合、対象のJPEGデータは変更せず、必要な名前変更だけを行います。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("類似画像") {
                Toggle("類似している可能性のある画像を確認", isOn: $preferences.detectsSimilarImages)

                Toggle("完全に同一のファイルだけ検出", isOn: $preferences.detectsOnlyExactDuplicates)
                    .disabled(!preferences.detectsSimilarImages)

                Picker("検出感度", selection: $preferences.similarImageSensitivity) {
                    ForEach(SimilarImageSensitivity.allCases) { sensitivity in
                        Text(sensitivity.displayName).tag(sensitivity)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!preferences.detectsSimilarImages || preferences.detectsOnlyExactDuplicates)

                Toggle("RAW＋JPEGの組み合わせを候補から除外", isOn: $preferences.excludesRAWJPEGFromSimilarity)
                    .disabled(!preferences.detectsSimilarImages)

                Text("画像特徴の比較はこのMac内で行います。候補を表示するだけで、自動的な削除や除外は行いません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("表示") {
                Picker("標準の表示形式", selection: $preferences.defaultViewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("グリッドの列数")
                    Slider(
                        value: Binding(
                            get: { Double(preferences.gridColumnCount) },
                            set: { preferences.gridColumnCount = Int($0.rounded()) }
                        ),
                        in: 2...8,
                        step: 1
                    )
                    Text("\(preferences.gridColumnCount)列")
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }

                Toggle("ウィンドウを開いたときにサイドバーを表示", isOn: $preferences.opensSidebarOnLaunch)
            }

            Section("プライバシー") {
                LabeledContent("データの処理") {
                    Text("このMac内のみ")
                        .foregroundStyle(.secondary)
                }

                Button("プライバシーポリシーを表示…") {
                    showsPrivacyPolicy = true
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 560, height: 780)
        .sheet(isPresented: $showsPrivacyPolicy) {
            PrivacyPolicyView()
        }
    }
}

private struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("プライバシーポリシー")
                .font(.title2.weight(.semibold))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    policySection(
                        "データの処理",
                        "FileRenamerは、ユーザーが選択したファイルをこのMac内で処理します。ファイル、ファイル名、画像、メタデータ、利用状況を開発者へ送信または収集しません。"
                    )
                    policySection(
                        "ファイルへのアクセス",
                        "選択したファイルへのアクセスは、読み込み、プレビュー、名前変更、画像変換、リサイズ、類似画像候補のローカル比較、ユーザーが明示的に選んだファイルのゴミ箱への移動、Undo、失敗時の復旧にだけ使用します。"
                    )
                    policySection(
                        "このMacに保存する情報",
                        "設定、命名ルール、Undo履歴、復旧情報、必要な画像バックアップをこのMac内に保存します。古いUndo履歴と関連バックアップは、アプリの保存上限に従って削除されます。"
                    )
                    policySection(
                        "追跡と第三者提供",
                        "広告、分析、ユーザー追跡を行わず、データを第三者へ提供しません。更新確認を有効にした場合は、最新バージョンの有無を確認するため更新情報サーバーへ接続しますが、ファイル、画像、利用状況は送信しません。"
                    )
                    Text("制定日：2026年8月13日")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560, height: 480)
    }

    private func policySection(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.headline)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
