import SwiftUI
import AppKit
import Combine
import RenameKit
import TipKit

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
        static let displayLanguage = "preferences.displayLanguage"
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
    @Published var displayLanguage: AppLanguage {
        didSet { defaults.set(displayLanguage.rawValue, forKey: Key.displayLanguage) }
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
            Key.excludesRAWJPEGFromSimilarity: true,
            Key.displayLanguage: AppLanguage.system.rawValue
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
        displayLanguage = defaults.string(forKey: Key.displayLanguage)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    var similarImageScanConfiguration: SimilarImageScanConfiguration {
        SimilarImageScanConfiguration(
            exactMatchesOnly: detectsOnlyExactDuplicates,
            sensitivity: similarImageSensitivity,
            excludesRAWJPEGCompanions: excludesRAWJPEGFromSimilarity
        )
    }

    var resolvedLanguage: ResolvedAppLanguage {
        displayLanguage.resolved(preferredLanguageIdentifier: Locale.preferredLanguages.first ?? "en")
    }

    var displayLocale: Locale {
        Locale(identifier: resolvedLanguage.localeIdentifier)
    }
}

@MainActor
final class WorkspaceModel: ObservableObject {
    struct Tab: Identifiable {
        let id: UUID
        let model: AppModel
    }

    @Published private(set) var tabs: [Tab]
    @Published var selectedTabID: UUID {
        didSet { observeActiveModel() }
    }

    /// Mirrors of the active model's Edit-menu state.
    ///
    /// `Commands` is part of the `App`, which observes this workspace — not the
    /// `AppModel` inside it. Reading `activeModel.canUndoOrderChange` directly from a
    /// command therefore samples it once and never again, so the menu item keeps
    /// whatever enabled state it had at launch (disabled) and ⌘Z does nothing no
    /// matter how many times the list is rearranged. Republishing the three flags the
    /// menu needs puts them on the object the menu is actually subscribed to.
    @Published private(set) var canUndoOrderChange = false
    @Published private(set) var canRedoOrderChange = false
    @Published private(set) var isRuleTextEditing = false
    @Published private(set) var canUndoRename = false
    @Published private(set) var canRedoRename = false
    @Published private(set) var hasSelection = false
    @Published private(set) var canShiftSelectionEarlier = false
    @Published private(set) var canShiftSelectionLater = false

    private let preferences: AppPreferences
    private var preferenceCancellables: Set<AnyCancellable> = []
    private var activeModelCancellable: AnyCancellable?

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

        observeActiveModel()
    }

    /// Follows whichever tab is in front. `objectWillChange` fires *before* the
    /// change lands, so the state is read on the next run-loop pass, and only a real
    /// difference is republished — otherwise every keystroke in the rule field would
    /// invalidate the whole scene.
    private func observeActiveModel() {
        let model = activeModel
        refreshEditMenuState(from: model)
        activeModelCancellable = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self, weak model] in
                guard let self, let model else { return }
                self.refreshEditMenuState(from: model)
            }
    }

    private func refreshEditMenuState(from model: AppModel) {
        let undo = model.canUndoOrderChange
        let redo = model.canRedoOrderChange
        let editing = model.isRuleTextEditing
        let undoRename = model.canUndo
        let redoRename = model.canRedo
        let selected = !model.selection.isEmpty
        let earlier = model.canShift(ids: model.selection, by: -1)
        let later = model.canShift(ids: model.selection, by: 1)
        guard undo != canUndoOrderChange
                || redo != canRedoOrderChange
                || editing != isRuleTextEditing
                || undoRename != canUndoRename
                || redoRename != canRedoRename
                || selected != hasSelection
                || earlier != canShiftSelectionEarlier
                || later != canShiftSelectionLater
        else { return }

        canUndoOrderChange = undo
        canRedoOrderChange = redo
        isRuleTextEditing = editing
        canUndoRename = undoRename
        canRedoRename = redoRename
        hasSelection = selected
        canShiftSelectionEarlier = earlier
        canShiftSelectionLater = later
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
        observeActiveModel()
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

    var displayLanguage: ResolvedAppLanguage { preferences.resolvedLanguage }

    func title(for tab: Tab) -> String {
        let directories = tab.model.workingDirectories
        if let first = directories.first {
            return directories.count == 1
                ? first.lastPathComponent
                : L10n.format(
                    "workspace.additionalFolders",
                    defaultValue: "%@ and %d more location(s)",
                    arguments: [first.lastPathComponent, directories.count - 1],
                    language: displayLanguage
                )
        }
        let index = tabs.firstIndex(where: { $0.id == tab.id }) ?? 0
        return L10n.format(
            "workspace.tabNumber",
            defaultValue: "Tab %d",
            arguments: [index + 1],
            language: displayLanguage
        )
    }

}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var workspace: WorkspaceModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard workspace?.preventsTermination == true else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        let language = workspace?.displayLanguage ?? .english
        alert.messageText = L10n.string(
            "quit.blocked.title",
            defaultValue: "FileRenamer can’t quit until renaming finishes",
            language: language
        )
        alert.informativeText = L10n.string(
            "quit.blocked.detail",
            defaultValue: "File names are being safely finalized or recovered. Try quitting again when this finishes.",
            language: language
        )
        alert.addButton(withTitle: L10n.string("quit.blocked.continue", defaultValue: "Continue", language: language))
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
    let language: ResolvedAppLanguage
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowList) {
            Divider()
            Button(L10n.string("settings.openFilerenamer", defaultValue: "Open FileRenamer", language: language)) {
                openWindow(id: MainWindow.id)
            }
        }
    }
}

/// The Edit menu owns ⌘Z. When the focus is in a native text editor, forwarding the
/// selector preserves normal typing Undo; otherwise the same shortcut reverts the
/// in-memory file ordering.
private enum UndoCommandRouter {
    static var hasNativeTextEditorFocus: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.isFieldEditor == true
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
        try? Tips.configure([
            .displayFrequency(.immediate),
            .datastoreLocation(.applicationDefault)
        ])
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
                .environment(\.locale, preferences.displayLocale)
                .onAppear { appDelegate.workspace = workspace }
        }
        .windowToolbarStyle(.unified)
        .commands {
            MainWindowCommands(language: preferences.resolvedLanguage)

            CommandGroup(replacing: .newItem) {
                Button(localized("menu.newTab", defaultValue: "New Tab")) { workspace.addTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Divider()
                Button(localized("menu.addFiles", defaultValue: "Add Files…")) { workspace.activeModel.presentOpenPanel(directories: false) }
                    .keyboardShortcut("o", modifiers: .command)
                Button(localized("menu.addFolder", defaultValue: "Add Folder…")) { workspace.activeModel.presentOpenPanel(directories: true) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }

            // Replace the stock commands so ⌘Z reaches ordering changes instead of
            // being consumed by an empty window Undo manager. Text fields retain
            // their native Undo/Redo through the first-responder chain.
            // Filesystem Undo deliberately remains ⌥⌘Z because it alters files.
            CommandGroup(replacing: .undoRedo) {
                Button(localized("menu.undo", defaultValue: "Undo")) {
                    if workspace.isRuleTextEditing || UndoCommandRouter.hasNativeTextEditorFocus {
                        UndoCommandRouter.performNativeUndo()
                    } else {
                        workspace.activeModel.undoOrderChange()
                    }
                }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!workspace.canUndoOrderChange && !workspace.isRuleTextEditing)
                Button(localized("menu.redo", defaultValue: "Redo")) {
                    if workspace.isRuleTextEditing || UndoCommandRouter.hasNativeTextEditorFocus {
                        UndoCommandRouter.performNativeRedo()
                    } else {
                        workspace.activeModel.redoOrderChange()
                    }
                }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!workspace.canRedoOrderChange && !workspace.isRuleTextEditing)
                Divider()
                Button(localized("menu.undoRename", defaultValue: "Undo Last Rename")) { workspace.activeModel.requestUndo() }
                    .keyboardShortcut("z", modifiers: [.command, .option])
                    .disabled(!workspace.canUndoRename)
                Button(localized("menu.redoRename", defaultValue: "Redo Last Rename")) { workspace.activeModel.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .option, .shift])
                    .disabled(!workspace.canRedoRename)
            }

            CommandGroup(after: .pasteboard) {
                Button(localized("menu.selectAll", defaultValue: "Select All")) { workspace.activeModel.selectAll() }
                    .keyboardShortcut("a", modifiers: .command)
                Button(L10n.format(
                    "menu.removeSelection",
                    defaultValue: "Remove %lld from List",
                    arguments: [workspace.activeModel.selection.count],
                    language: preferences.resolvedLanguage
                )) { workspace.activeModel.removeSelected() }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(!workspace.hasSelection)
            }

            CommandMenu(localized("menu.sort", defaultValue: "Sort")) {
                Button(localized("menu.moveEarlier", defaultValue: "Move Earlier")) { workspace.activeModel.shift(ids: workspace.activeModel.selection, by: -1) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(!workspace.canShiftSelectionEarlier)
                Button(localized("menu.moveLater", defaultValue: "Move Later")) { workspace.activeModel.shift(ids: workspace.activeModel.selection, by: 1) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                    .disabled(!workspace.canShiftSelectionLater)
                Button(localized("menu.moveToStart", defaultValue: "Move to Start")) { workspace.activeModel.moveToEdge(ids: workspace.activeModel.selection, toStart: true) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    .disabled(!workspace.hasSelection)
                Button(localized("menu.moveToEnd", defaultValue: "Move to End")) { workspace.activeModel.moveToEdge(ids: workspace.activeModel.selection, toStart: false) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                    .disabled(!workspace.hasSelection)
                Divider()
                ForEach(SortField.allCases, id: \.self) { field in
                    Menu(field.localizedDisplayName(in: preferences.resolvedLanguage)) {
                        Button(localized("sort.ascending", defaultValue: "Ascending")) { workspace.activeModel.applySort(SortDescriptorOption(field: field, ascending: true)) }
                        Button(localized("sort.descending", defaultValue: "Descending")) { workspace.activeModel.applySort(SortDescriptorOption(field: field, ascending: false)) }
                    }
                }
                Divider()
                Button(localized("menu.reverseOrder", defaultValue: "Reverse Order")) { workspace.activeModel.reverseOrder() }
                Button(localized("menu.togglePositionLock", defaultValue: "Lock / Unlock Position")) {
                    workspace.activeModel.toggleLock(ids: workspace.activeModel.selection)
                }
                    .keyboardShortcut("l", modifiers: .command)
            }

            CommandGroup(after: .help) {
                Button(localized("menu.showTutorial", defaultValue: "Show Tutorial Again")) {
                    TutorialProgress.restart()
                }
            }
        }

        Settings {
            PreferencesView()
                .environmentObject(preferences)
                .environment(\.locale, preferences.displayLocale)
        }
    }

    private func localized(_ key: String, defaultValue: String) -> String {
        L10n.string(key, defaultValue: defaultValue, language: preferences.resolvedLanguage)
    }
}

private struct PreferencesView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @State private var showsPrivacyPolicy = false

    var body: some View {
        Form {
            Section(L10n.string("settings.confirmation", defaultValue: "Confirmation", language: preferences.resolvedLanguage)) {
                Toggle(L10n.string("settings.reviewChangesBeforeRenaming", defaultValue: "Review changes before renaming", language: preferences.resolvedLanguage), isOn: $preferences.confirmsRenameChanges)
                Text(L10n.string("settings.reviewFileNamesImageProcessing", defaultValue: "Review file names, image processing, and original-file handling before continuing.", language: preferences.resolvedLanguage))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(L10n.string("settings.confirmOriginalFileHandlingBefore", defaultValue: "Confirm original-file handling before converting or resizing images", language: preferences.resolvedLanguage), isOn: $preferences.confirmsOriginalProtection)
                Text(L10n.string("settings.whenOffTheOriginalImage", defaultValue: "When off, the original image is replaced. Name-conflict protection and recovery after failure remain active.", language: preferences.resolvedLanguage))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(L10n.string("settings.confirmBeforeUndoingARename", defaultValue: "Confirm before undoing a rename", language: preferences.resolvedLanguage), isOn: $preferences.confirmsUndo)
            }

            Section(L10n.string("settings.imageProcessing", defaultValue: "Image Processing", language: preferences.resolvedLanguage)) {
                Toggle(L10n.string("settings.preventUpscalingByDefaultWhen", defaultValue: "Prevent upscaling by default when resizing", language: preferences.resolvedLanguage), isOn: $preferences.preventsUpscalingByDefault)
                Text(L10n.string("settings.appliedWhenYouFirstEnable", defaultValue: "Applied when you first enable resizing in Image Settings.", language: preferences.resolvedLanguage))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(L10n.string("settings.doNotRecompressJpegFiles", defaultValue: "Do not recompress JPEG files at 100% when format and size are unchanged", language: preferences.resolvedLanguage), isOn: $preferences.preservesJPEGAtMaximumQuality)
                Text(L10n.string("settings.whenOnMatchingJpegData", defaultValue: "When on, matching JPEG data remains unchanged and only the file name is changed.", language: preferences.resolvedLanguage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.string("settings.similarImages", defaultValue: "Similar Images", language: preferences.resolvedLanguage)) {
                Toggle(L10n.string("settings.checkForSimilarImages", defaultValue: "Check for similar images", language: preferences.resolvedLanguage), isOn: $preferences.detectsSimilarImages)

                Toggle(L10n.string("settings.findExactDuplicateFilesOnly", defaultValue: "Find exact duplicate files only", language: preferences.resolvedLanguage), isOn: $preferences.detectsOnlyExactDuplicates)
                    .disabled(!preferences.detectsSimilarImages)

                Picker(L10n.string("settings.detectionSensitivity", defaultValue: "Detection Sensitivity", language: preferences.resolvedLanguage), selection: $preferences.similarImageSensitivity) {
                    ForEach(SimilarImageSensitivity.allCases) { sensitivity in
                        Text(sensitivity.localizedDisplayName(in: preferences.resolvedLanguage)).tag(sensitivity)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!preferences.detectsSimilarImages || preferences.detectsOnlyExactDuplicates)

                Toggle(L10n.string("settings.excludeRawJpegPairsFrom", defaultValue: "Exclude RAW + JPEG pairs from suggestions", language: preferences.resolvedLanguage), isOn: $preferences.excludesRAWJPEGFromSimilarity)
                    .disabled(!preferences.detectsSimilarImages)

                Text(L10n.string("settings.imageFeatureComparisonsStayOn", defaultValue: "Image-feature comparisons stay on this Mac. FileRenamer only shows suggestions; it never removes or excludes files automatically.", language: preferences.resolvedLanguage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.string("settings.display", defaultValue: "Display", language: preferences.resolvedLanguage)) {
                Picker(L10n.string("settings.displayLanguage", defaultValue: "Display Language", language: preferences.resolvedLanguage), selection: $preferences.displayLanguage) {
                    Text(AppLanguage.system.localizedDisplayName(in: preferences.resolvedLanguage)).tag(AppLanguage.system)
                    Text(AppLanguage.japanese.localizedDisplayName(in: preferences.resolvedLanguage)).tag(AppLanguage.japanese)
                    Text("English").tag(AppLanguage.english)
                }

                Text(L10n.string("settings.whenYourSystemLanguageIs", defaultValue: "When your system language is not Japanese, FileRenamer uses English.", language: preferences.resolvedLanguage))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(L10n.string("settings.defaultView", defaultValue: "Default View", language: preferences.resolvedLanguage), selection: $preferences.defaultViewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Text(mode.localizedDisplayName(in: preferences.resolvedLanguage)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text(L10n.string("settings.gridColumns", defaultValue: "Grid Columns", language: preferences.resolvedLanguage))
                    Slider(
                        value: Binding(
                            get: { Double(preferences.gridColumnCount) },
                            set: { preferences.gridColumnCount = Int($0.rounded()) }
                        ),
                        in: 2...8,
                        step: 1
                    )
                    Text(L10n.format(
                        "grid.columnCount",
                        defaultValue: "%d columns",
                        arguments: [preferences.gridColumnCount],
                        language: preferences.resolvedLanguage
                    ))
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }

                Toggle(L10n.string("settings.showSidebarWhenOpeningA", defaultValue: "Show sidebar when opening a window", language: preferences.resolvedLanguage), isOn: $preferences.opensSidebarOnLaunch)
            }

            Section(L10n.string("settings.privacy", defaultValue: "Privacy", language: preferences.resolvedLanguage)) {
                LabeledContent(L10n.string("settings.dataHandling", defaultValue: "Data Handling", language: preferences.resolvedLanguage)) {
                    Text(L10n.string("settings.onThisMacOnly", defaultValue: "On This Mac Only", language: preferences.resolvedLanguage))
                        .foregroundStyle(.secondary)
                }

                Button(L10n.string("settings.showPrivacyPolicy", defaultValue: "Show Privacy Policy…", language: preferences.resolvedLanguage)) {
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
    @Environment(\.locale) private var locale
    private var language: ResolvedAppLanguage { ResolvedAppLanguage(locale: locale) }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.string("settings.privacyPolicy", defaultValue: "Privacy Policy", language: language))
                .font(.title2.weight(.semibold))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    policySection(
                        L10n.string("settings.dataHandling", defaultValue: "Data Handling", language: language),
                        L10n.string("settings.filerenamerProcessesTheFilesYou", defaultValue: "FileRenamer processes the files you select only on this Mac. It does not send or collect your files, names, images, metadata, or usage data.", language: language)
                    )
                    policySection(
                        L10n.string("settings.fileAccess", defaultValue: "File Access", language: language),
                        L10n.string("settings.accessToSelectedFilesIs", defaultValue: "Access to selected files is used only for importing, previewing, renaming, image conversion, resizing, local comparison of similar-image candidates, moving files you explicitly select to Trash, Undo, and recovery after failure.", language: language)
                    )
                    policySection(
                        L10n.string("settings.informationStoredOnThisMac", defaultValue: "Information Stored on This Mac", language: language),
                        L10n.string("settings.settingsNamingRulesUndoHistory", defaultValue: "Settings, naming rules, Undo history, recovery information, and any needed image backups are stored on this Mac. Older Undo history and related backups are removed according to the app’s storage limit.", language: language)
                    )
                    policySection(
                        L10n.string("settings.trackingAndSharing", defaultValue: "Tracking and Sharing", language: language),
                        L10n.string("settings.filerenamerDoesNotUseAdvertising", defaultValue: "FileRenamer does not use advertising, analytics, or user tracking, and does not share data with third parties. If update checking is enabled, it connects to the update server only to check whether a newer version is available; it never sends files, images, or usage data.", language: language)
                    )
                    Text(L10n.string("settings.effectiveDateAugust132026", defaultValue: "Effective date: August 13, 2026", language: language))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button(L10n.string("settings.close", defaultValue: "Close", language: language)) { dismiss() }
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
