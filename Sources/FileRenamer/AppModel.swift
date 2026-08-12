import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import RenameKit

/// Serial workers keep expensive synchronous RenameKit work off the main actor.
/// Separate workers mean a slow destination scan never blocks generation of the
/// newest names while the user keeps typing or arranging files.
private actor PreviewGenerationWorker {
    private let engine = RenameEngine()
    private let validator = RenameValidator()

    func generate(items: [RenameItem], rule: RenameRule) throws -> [RenamePreview] {
        try Task.checkCancellation()
        let generated = engine.makePreviews(items: items, rule: rule)
        try Task.checkCancellation()
        return validator.validate(generated, checkExistingFiles: false)
    }
}

private actor DestinationValidationWorker {
    private let validator = RenameValidator()

    func validate(_ previews: [RenamePreview]) throws -> [RenamePreview] {
        try Task.checkCancellation()
        let validated = validator.validate(previews)
        try Task.checkCancellation()
        return validated
    }
}

enum ViewMode: String, CaseIterable, Identifiable {
    case list
    case grid

    var id: String { rawValue }
    var displayName: String { self == .list ? "リスト" : "グリッド" }
    var systemImageName: String { self == .list ? "list.bullet" : "square.grid.2x2" }
}

/// The single piece of app state. Owns the item order, the naming rule and the
/// history; delegates every non-trivial decision to RenameKit.
///
/// Views read `previews` and call methods here — no view builds a file name or
/// touches the filesystem itself.
@MainActor
final class AppModel: ObservableObject {
    // MARK: Published state

    @Published private(set) var items: [RenameItem] = []
    private(set) var previews: [RenamePreview] = []
    private(set) var previewsByItemID: [UUID: RenamePreview] = [:]
    private(set) var errorCount = 0
    private(set) var warningCount = 0
    private(set) var changedCount = 0

    /// Always kept in text-editing shape: literal runs and blocks alternate, with an
    /// empty run at each end for the caret. Empty runs render as nothing, so the
    /// engine is unaffected.
    @Published var rule: RenameRule = RenameRule.default.normalizedForTextEditing() {
        didSet {
            guard rule != oldValue else { return }
            // Hand-editing detaches the rule from the preset it came from. Compared on
            // the saved shape, since the live rule carries editing scaffolding.
            if let id = selectedPresetID,
               presets.first(where: { $0.id == id })?.rule.compactedAfterTextEditing() != savedRule {
                selectedPresetID = nil
            }
            refreshPreviews()
        }
    }

    /// The rule as it would be stored in a preset.
    var savedRule: RenameRule { rule.compactedAfterTextEditing() }

    @Published private(set) var presets: [RenameRulePreset] = []
    @Published private(set) var selectedPresetID: UUID?
    @Published var importOptions: ImportOptions = .default {
        didSet { if importOptions != oldValue { reimportIfNeeded(previous: oldValue) } }
    }

    @Published var selection: Set<UUID> = []
    @Published var viewMode: ViewMode = .list
    @Published var sortOption = SortDescriptorOption(field: .fileName, ascending: true)

    @Published private(set) var isBusy = false
    @Published private(set) var busyLabel = ""
    @Published private(set) var progress: Double = 0
    @Published private(set) var canCancelBusyOperation = false
    @Published private(set) var preventsTermination = false
    @Published private(set) var isValidatingDestinations = false
    @Published var alertMessage: AlertMessage?
    @Published var resultMessage: ResultMessage?
    @Published var quickLookURL: URL?
    @Published var isUndoConfirmationPresented = false

    @Published private(set) var history = RenameHistory()

    // MARK: Collaborators

    private let previewWorker = PreviewGenerationWorker()
    private let destinationWorker = DestinationValidationWorker()
    private let importer = FileImporter()
    private let executor = RenameExecutor()
    private let presetStore: RulePresetStore
    private let historyStore: RenameHistoryStore
    private var busyTask: Task<Void, Never>?
    private var validationTask: Task<Void, Never>?
    private var previewRevision = 0

    private struct FolderAccess {
        let url: URL
        let bookmark: Data
        let isActivelyAccessed: Bool
    }

    /// Folder grants are kept for the session and copied into rename history so
    /// Undo can still reach the files after a relaunch.
    private var folderAccess: [String: FolderAccess] = [:]

    struct AlertMessage: Identifiable {
        let id = UUID()
        var title: String
        var detail: String
    }

    struct ResultMessage: Identifiable {
        let id = UUID()
        var text: String
        var offersUndo: Bool = false
    }

    init(
        presetStore: RulePresetStore = RulePresetStore(),
        historyStore: RenameHistoryStore = RenameHistoryStore(),
        recoversPendingRenames: Bool = true
    ) {
        self.presetStore = presetStore
        self.historyStore = historyStore
        history = historyStore.load()
        let loadedPresets = presetStore.loadWithDiagnostics()
        presets = RenameRulePreset.builtIns + loadedPresets.presets
        if let first = presets.first {
            rule = first.rule.normalizedForTextEditing()
            selectedPresetID = first.id
        }
        if let recoveryMessage = loadedPresets.recoveryMessage {
            alertMessage = AlertMessage(title: "プリセットを復旧しました", detail: recoveryMessage)
        }
        if recoversPendingRenames {
            Task { [weak self] in await self?.recoverPendingRenames() }
        }
    }

    // MARK: Derived

    var isEmpty: Bool { items.isEmpty }
    var fileCount: Int { items.reduce(0) { $0 + $1.allURLs.count } }
    var canRename: Bool {
        !isBusy && !isValidatingDestinations && !items.isEmpty && errorCount == 0 && changedCount > 0
    }
    var canUndo: Bool { !isBusy && history.canUndo }
    var canRedo: Bool { !isBusy && history.canRedo }
    var importedDirectories: [URL] {
        var seenPaths = Set<String>()
        return items
            .flatMap(\.allURLs)
            .map { $0.deletingLastPathComponent().standardizedFileURL }
            .filter { seenPaths.insert($0.path).inserted }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
    }
    var undoConfirmationMessage: String {
        guard let transaction = history.lastTransaction else {
            return "元に戻せるリネーム履歴がありません。"
        }
        return "直前に変更した\(transaction.fileCount)ファイルを、元の名前に戻します。"
    }

    func preview(for item: RenameItem) -> RenamePreview? { previewsByItemID[item.id] }

    /// One row's validation problem, flattened for the status-bar popover.
    struct Issue: Identifiable, Hashable {
        let id: UUID
        let name: String
        let message: String
        let isError: Bool
    }

    func issues(errorsOnly: Bool) -> [Issue] {
        items.compactMap { item in
            guard let preview = previewsByItemID[item.id],
                  let message = preview.validation.message,
                  errorsOnly ? preview.validation.isError : preview.validation.isWarning
            else { return nil }
            return Issue(
                id: item.id,
                name: item.displayName,
                message: message,
                isError: preview.validation.isError
            )
        }
    }

    func index(of id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    var selectedItems: [RenameItem] { items.filter { selection.contains($0.id) } }

    // MARK: - Import

    func importURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard beginBusy("読み込み中…", cancellable: true) else { return }
        let transientAccess = beginImportAccess(for: urls)
        let options = importOptions
        busyTask = Task { [weak self] in
            await self?.performImport(urls, options: options, transientAccess: transientAccess)
        }
    }

    private func performImport(
        _ urls: [URL],
        options: ImportOptions,
        transientAccess: [URL]
    ) async {
        var endedBusy = false
        defer {
            transientAccess.forEach { $0.stopAccessingSecurityScopedResource() }
            if !endedBusy { endBusy() }
        }

        let result: ImportResult
        do {
            result = try await importer.importItems(from: urls, options: options)
            try Task.checkCancellation()
        } catch is CancellationError {
            resultMessage = ResultMessage(text: "読み込みをキャンセルしました")
            return
        } catch {
            alertMessage = AlertMessage(title: "読み込めませんでした", detail: error.localizedDescription)
            return
        }

        // Dropping the same file twice should not create a second row.
        let known = Set(items.flatMap { $0.allURLs.map(\.standardizedFileURL.path) })
        let fresh = result.items.filter { item in
            !item.allURLs.contains { known.contains($0.standardizedFileURL.path) }
        }

        items = ItemSorter.reindexed(items + fresh)
        endBusy()
        endedBusy = true

        refreshPreviews()

        if fresh.isEmpty && !result.items.isEmpty {
            alertMessage = AlertMessage(title: "追加できるファイルがありません", detail: "すべて既にリストに含まれています。")
        } else if !result.skippedPackages.isEmpty {
            let names = result.skippedPackages.prefix(5).map(\.lastPathComponent).joined(separator: ", ")
            alertMessage = AlertMessage(
                title: "パッケージを除外しました",
                detail: "アプリやパッケージ形式の書類は中身を壊す恐れがあるため対象外です: \(names)"
            )
        }
    }

    /// Re-grouping changes how files map to rows, so the list has to be rebuilt from
    /// the URLs we already hold. Manual ordering cannot survive that and is reset.
    private func reimportIfNeeded(previous: ImportOptions) {
        guard previous.groupCompanionFiles != importOptions.groupCompanionFiles, !items.isEmpty else { return }
        let urls = items.flatMap(\.allURLs)
        items = []
        importURLs(urls)
    }

    func presentOpenPanel(directories: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directories
        panel.canChooseDirectories = directories
        panel.allowsMultipleSelection = true
        panel.prompt = "追加"
        panel.message = directories ? "追加するフォルダを選択" : "追加するファイルを選択"
        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls)
    }

    /// Starts the short-lived scope needed to read imported file metadata. Directory
    /// selections are retained as reusable write grants; individual file scopes are
    /// released when importing finishes to avoid exhausting the system scope limit.
    private func beginImportAccess(for urls: [URL]) -> [URL] {
        var transient: [URL] = []
        for url in urls {
            let started = url.startAccessingSecurityScopedResource()
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDirectory,
               let bookmark = try? url.bookmarkData(
                   options: .withSecurityScope,
                   includingResourceValuesForKeys: nil,
                   relativeTo: nil
               ) {
                registerFolderAccess(url: url, bookmark: bookmark, isActive: started)
            } else if started {
                transient.append(url)
            }
        }
        return transient
    }

    private func ensureFolderAccess(
        forDirectories directories: [URL],
        showCancellationAlert: Bool
    ) -> Bool {
        let required = uniqueDirectories(directories)
        for directory in required {
            // Do not show a permission panel merely because the app has no stored
            // bookmark. Locations already writable through the sandbox/container,
            // an inherited grant, or ordinary filesystem access need no approval.
            if hasFolderAccess(covering: directory) || canWriteWithoutAdditionalGrant(to: directory) {
                continue
            }

            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = false
            panel.directoryURL = directory.deletingLastPathComponent()
            panel.prompt = "アクセスを許可"
            panel.message = "「\(directory.lastPathComponent)」内のファイル名を変更するため、このフォルダ（または親フォルダ）を選択してください。"

            guard panel.runModal() == .OK, let selected = panel.url else {
                if showCancellationAlert {
                    alertMessage = AlertMessage(
                        title: "フォルダへのアクセスが必要です",
                        detail: "リネーム前に「\(directory.lastPathComponent)」への書き込みを許可してください。ファイルはまだ変更されていません。"
                    )
                }
                return false
            }

            guard selected.standardizedFileURL == directory.standardizedFileURL
                    || isAncestor(selected, of: directory) else {
                alertMessage = AlertMessage(
                    title: "別のフォルダが選択されました",
                    detail: "「\(directory.lastPathComponent)」または、その親フォルダを選択してください。"
                )
                return false
            }

            let started = selected.startAccessingSecurityScopedResource()
            guard let bookmark = try? selected.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) else {
                if started { selected.stopAccessingSecurityScopedResource() }
                alertMessage = AlertMessage(
                    title: "アクセス許可を保存できませんでした",
                    detail: "フォルダをもう一度選択してください。"
                )
                return false
            }
            registerFolderAccess(url: selected, bookmark: bookmark, isActive: started)
        }
        return true
    }

    /// A real write probe is more accurate than POSIX mode bits on a sandboxed app:
    /// a directory can look writable to `isWritableFile` while App Sandbox still
    /// denies creating the temporary directory entry required for a rename.
    /// The probe is empty, uniquely named, and removed immediately.
    private func canWriteWithoutAdditionalGrant(to directory: URL) -> Bool {
        let probe = directory.appendingPathComponent(
            ".filerenamer-access-check-\(UUID().uuidString)",
            isDirectory: false
        )
        do {
            try Data().write(to: probe, options: .withoutOverwriting)
            do {
                try FileManager.default.removeItem(at: probe)
                return true
            } catch {
                try? FileManager.default.removeItem(at: probe)
                return false
            }
        } catch {
            return false
        }
    }

    private func registerFolderAccess(url: URL, bookmark: Data, isActive: Bool) {
        let normalized = url.standardizedFileURL
        let key = normalized.path
        if let old = folderAccess[key], old.isActivelyAccessed {
            old.url.stopAccessingSecurityScopedResource()
        }
        folderAccess[key] = FolderAccess(
            url: normalized,
            bookmark: bookmark,
            isActivelyAccessed: isActive
        )
    }

    private func hasFolderAccess(covering directory: URL) -> Bool {
        folderAccess.values.contains { access in
            access.url.standardizedFileURL == directory.standardizedFileURL
                || isAncestor(access.url, of: directory)
        }
    }

    private func bookmarks(covering directories: [URL]) -> [Data] {
        var seen = Set<String>()
        var result: [Data] = []
        for directory in uniqueDirectories(directories) {
            guard let access = folderAccess.values.first(where: {
                $0.url.standardizedFileURL == directory.standardizedFileURL
                    || isAncestor($0.url, of: directory)
            }) else { continue }
            if seen.insert(access.url.path).inserted { result.append(access.bookmark) }
        }
        return result
    }

    private func restoreFolderAccess(from bookmarks: [Data]) {
        for bookmark in bookmarks {
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else { continue }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            guard isDirectory else { continue }
            let started = url.startAccessingSecurityScopedResource()
            registerFolderAccess(url: url, bookmark: bookmark, isActive: started)
        }
    }

    private func uniqueDirectories(_ directories: [URL]) -> [URL] {
        var seen = Set<String>()
        return directories
            .map(\.standardizedFileURL)
            .filter { seen.insert($0.path).inserted }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func isAncestor(_ possibleAncestor: URL, of child: URL) -> Bool {
        let root = possibleAncestor.standardizedFileURL.path
        let path = child.standardizedFileURL.path
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    // MARK: - List mutation

    func removeSelected() {
        guard !selection.isEmpty else { return }
        releaseStepGrab()
        items = ItemSorter.reindexed(items.filter { !selection.contains($0.id) })
        selection.removeAll()
        refreshPreviews()
    }

    func removeAll() {
        releaseStepGrab()
        items = []
        selection.removeAll()
        refreshPreviews()
    }

    func selectAll() {
        selection = Set(items.map(\.id))
    }

    /// Drag & drop in the list.
    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        releaseStepGrab()
        items = ItemSorter.move(items, fromOffsets: offsets, toOffset: destination)
        refreshPreviews()
    }

    /// Drag & drop in the grid, where a drop lands on a cell instead of a gap.
    func move(ids: Set<UUID>, toIndex index: Int) {
        releaseStepGrab()
        items = ItemSorter.move(items, ids: ids, toIndex: index)
        refreshPreviews()
    }

    /// Backs the per-row ◀ ▶ buttons and the ⌘↑ / ⌘↓ shortcuts.
    /// Acts on the whole selection when the row is part of it, matching Finder.
    func shift(ids: Set<UUID>, by delta: Int) {
        let targets = effectiveTargets(for: ids)
        guard !targets.isEmpty else { return }
        releaseStepGrab()
        items = ItemSorter.shift(items, ids: targets, by: delta)
        refreshPreviews()
    }

    // MARK: Repeat-clicking a stepper
    //
    // Stepping a row moves it out from under the cursor, so the button now sitting
    // there belongs to the item that was displaced. Without help, a second click
    // would move the wrong file back. So a step "grabs" its target: for a short
    // while, any stepper click keeps moving the same item, and the cursor can stay
    // parked on one spot and click it all the way down the list.
    //
    // The grab expires shortly after the last click, so a deliberate click on some
    // other row later behaves normally.

    private static let stepGrabTimeout: Duration = .milliseconds(1600)

    @Published private(set) var grabbedStepIDs: Set<UUID>?
    private var stepGrabExpiry: Task<Void, Never>?

    /// Row the list should scroll to keep visible. The tick makes repeated requests
    /// for the *same* row distinguishable, which is the normal case here: click the
    /// arrow twenty times and the list follows the file down twenty rows.
    @Published private(set) var scrollTargetID: UUID?
    @Published private(set) var scrollTick = 0

    /// The rows a stepper button on `id` would actually move. The list needs this to
    /// measure how far they are about to travel.
    func stepTargets(for rowID: UUID) -> Set<UUID> {
        if let grabbed = grabbedStepIDs, !grabbed.isEmpty { return grabbed }
        return effectiveTargets(for: [rowID])
    }

    func stepFromRow(_ id: UUID, by delta: Int) {
        let targets = stepTargets(for: id)
        guard !targets.isEmpty, ItemSorter.canShift(items, ids: targets, by: delta) else { return }

        items = ItemSorter.shift(items, ids: targets, by: delta)
        // Keep the moving rows highlighted so it stays obvious which file is sliding.
        selection = targets
        grab(targets)
        requestScroll(towards: delta, among: targets)
        refreshPreviews()
    }

    /// Follows the leading edge of the moving block — the bottom row when going down,
    /// the top row when going up — so the list scrolls in the direction of travel.
    private func requestScroll(towards delta: Int, among targets: Set<UUID>) {
        let moved = items.filter { targets.contains($0.id) }
        scrollTargetID = (delta > 0 ? moved.last : moved.first)?.id
        scrollTick &+= 1
    }

    func revealIssue(_ id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        selection = [id]
        scrollTargetID = id
        scrollTick &+= 1
    }

    func canStepFromRow(_ id: UUID, by delta: Int) -> Bool {
        ItemSorter.canShift(items, ids: stepTargets(for: id), by: delta)
    }

    /// True while this row is the one a parked cursor keeps moving — the view uses it
    /// to keep the button visibly attached to that item.
    func isGrabbedForStepping(_ id: UUID) -> Bool {
        grabbedStepIDs?.contains(id) ?? false
    }

    private func grab(_ ids: Set<UUID>) {
        grabbedStepIDs = ids
        stepGrabExpiry?.cancel()
        stepGrabExpiry = Task { [weak self] in
            try? await Task.sleep(for: Self.stepGrabTimeout)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.grabbedStepIDs = nil }
        }
    }

    /// Any other way of changing the order releases the grab.
    private func releaseStepGrab() {
        stepGrabExpiry?.cancel()
        stepGrabExpiry = nil
        grabbedStepIDs = nil
    }

    func moveToEdge(ids: Set<UUID>, toStart: Bool) {
        let targets = effectiveTargets(for: ids)
        guard !targets.isEmpty else { return }
        releaseStepGrab()
        items = ItemSorter.moveToEdge(items, ids: targets, toStart: toStart)
        refreshPreviews()
    }

    func canShift(ids: Set<UUID>, by delta: Int) -> Bool {
        ItemSorter.canShift(items, ids: effectiveTargets(for: ids), by: delta)
    }

    /// Pressing a button on a row inside the selection moves the whole selection;
    /// on a row outside it, only that row.
    private func effectiveTargets(for ids: Set<UUID>) -> Set<UUID> {
        guard let first = ids.first, ids.count == 1 else { return ids }
        return selection.contains(first) ? selection : ids
    }

    func applySort(_ option: SortDescriptorOption) {
        releaseStepGrab()
        sortOption = option
        items = ItemSorter.sorted(items, by: option)
        refreshPreviews()
    }

    func reverseOrder() {
        releaseStepGrab()
        items = ItemSorter.reindexed(items.reversed())
        refreshPreviews()
    }

    func toggleLock(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        // If anything in the selection is unlocked, lock everything; otherwise unlock.
        let shouldLock = items.contains { ids.contains($0.id) && !$0.isLocked }
        items = items.map { item in
            guard ids.contains(item.id) else { return item }
            var item = item
            item.isLocked = shouldLock
            return item
        }
        refreshPreviews()
    }

    // MARK: - Preview

    /// Coalesces rapid edits/reordering and performs all O(n) work off the main actor.
    /// Existing previews remain visible until the newest revision is ready, avoiding
    /// a blank/flickering list while typing.
    func refreshPreviews() {
        validationTask?.cancel()
        previewRevision &+= 1
        let revision = previewRevision
        let itemSnapshot = items
        let ruleSnapshot = rule
        guard !itemSnapshot.isEmpty else {
            applyPreviews([])
            isValidatingDestinations = false
            return
        }

        isValidatingDestinations = true
        validationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let structural = try await self.previewWorker.generate(
                    items: itemSnapshot,
                    rule: ruleSnapshot
                )
                guard !Task.isCancelled, self.previewRevision == revision else { return }
                self.applyPreviews(structural)

                // Filesystem checks are deliberately delayed: ten keystrokes should
                // cause one directory scan, not ten scans of the same batch.
                try await Task.sleep(for: .milliseconds(160))
                let validated = try await self.destinationWorker.validate(structural)
                guard !Task.isCancelled, self.previewRevision == revision else { return }
                self.applyPreviews(validated)
                self.isValidatingDestinations = false
            } catch is CancellationError {
                if self.previewRevision == revision {
                    self.isValidatingDestinations = false
                }
            } catch {
                if self.previewRevision == revision {
                    self.isValidatingDestinations = false
                }
            }
        }
    }

    private func applyPreviews(_ newPreviews: [RenamePreview]) {
        // These values describe one snapshot and must be published atomically. Five
        // independent @Published assignments caused five complete SwiftUI updates.
        objectWillChange.send()
        previews = newPreviews
        previewsByItemID = Dictionary(uniqueKeysWithValues: newPreviews.map { ($0.itemID, $0) })
        errorCount = newPreviews.errorCount
        warningCount = newPreviews.warningCount
        changedCount = newPreviews.changedCount
    }

    // MARK: - Presets
    //
    // The blocks themselves are edited through `Binding<RenameRule>` in
    // `RuleBuilderView`, which is why there are no per-token methods here.

    var selectedPresetName: String? {
        selectedPresetID.flatMap { id in presets.first { $0.id == id }?.name }
    }

    var userPresets: [RenameRulePreset] { presets.filter { !$0.isBuiltIn } }
    var builtInPresets: [RenameRulePreset] { presets.filter(\.isBuiltIn) }

    func applyPreset(_ preset: RenameRulePreset) {
        rule = preset.rule.normalizedForTextEditing()
        selectedPresetID = preset.id
    }

    /// Drops a block into the live rule at the caret.
    func insertBlock(_ token: RenameToken, atRun runID: UUID?, caret: Int) {
        rule = rule.inserting(token, atRun: runID, caret: caret)
    }

    /// Saving the same name again overwrites that preset instead of creating a
    /// second entry the user cannot tell apart.
    func saveCurrentRuleAsPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let index = presets.firstIndex(where: { !$0.isBuiltIn && $0.name == trimmed }) {
            presets[index].rule = savedRule
            selectedPresetID = presets[index].id
        } else {
            let preset = RenameRulePreset(name: trimmed, rule: savedRule)
            presets.append(preset)
            selectedPresetID = preset.id
        }
        persistPresets()
    }

    /// Saves a rule that was assembled in the preset editor rather than in the toolbar.
    /// Does not touch the rule currently being applied to the list.
    func addPreset(named name: String, rule: RenameRule) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let index = presets.firstIndex(where: { !$0.isBuiltIn && $0.name == trimmed }) {
            presets[index].rule = rule
        } else {
            presets.append(RenameRulePreset(name: trimmed, rule: rule))
        }
        persistPresets()
    }

    func updatePreset(id: UUID, name: String, rule: RenameRule) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = presets.firstIndex(where: { $0.id == id }),
              !presets[index].isBuiltIn
        else { return }

        presets[index].name = trimmed
        presets[index].rule = rule
        // Editing the preset that is currently applied should update the live rule too.
        if selectedPresetID == id {
            self.rule = rule.normalizedForTextEditing()
            selectedPresetID = id
        }
        persistPresets()
    }

    func deletePreset(id: UUID) {
        guard let index = presets.firstIndex(where: { $0.id == id }), !presets[index].isBuiltIn else { return }
        presets.remove(at: index)
        if selectedPresetID == id { selectedPresetID = nil }
        persistPresets()
    }

    func renamePreset(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = presets.firstIndex(where: { $0.id == id }),
              !presets[index].isBuiltIn
        else { return }
        presets[index].name = trimmed
        persistPresets()
    }

    func importPresets() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "読み込む"
        panel.message = "FileRenamerのプリセットJSONを選択"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let imported = try presetStore.decodeImportedPresets(from: Data(contentsOf: url))
            for preset in imported {
                if let index = presets.firstIndex(where: { !$0.isBuiltIn && $0.name == preset.name }) {
                    presets[index].rule = preset.rule
                } else {
                    presets.append(RenameRulePreset(name: preset.name, rule: preset.rule))
                }
            }
            persistPresets()
            resultMessage = ResultMessage(text: "\(imported.count) 件のプリセットを読み込みました")
        } catch {
            alertMessage = AlertMessage(title: "プリセットを読み込めませんでした", detail: error.localizedDescription)
        }
    }

    func exportPresets() {
        guard !userPresets.isEmpty else {
            alertMessage = AlertMessage(title: "書き出すプリセットがありません", detail: "マイプリセットを作成してから実行してください。")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "FileRenamer-Presets.json"
        panel.canCreateDirectories = true
        panel.prompt = "書き出す"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try presetStore.exportData(userPresets).write(to: url, options: .atomic)
            resultMessage = ResultMessage(text: "\(userPresets.count) 件のプリセットを書き出しました")
        } catch {
            alertMessage = AlertMessage(title: "プリセットを書き出せませんでした", detail: error.localizedDescription)
        }
    }

    private func persistPresets() {
        do {
            try presetStore.save(presets)
        } catch {
            alertMessage = AlertMessage(
                title: "プリセットを保存できませんでした",
                detail: error.localizedDescription
            )
        }
    }

    // MARK: - Rename

    func rename() {
        guard canRename else { return }
        let changedDirectories = previews
            .flatMap(\.effectiveOperations)
            .flatMap { [$0.source.deletingLastPathComponent(), $0.destination.deletingLastPathComponent()] }
        guard ensureFolderAccess(forDirectories: changedDirectories, showCancellationAlert: true) else { return }
        guard beginBusy("リネーム中…", critical: true) else { return }
        busyTask = Task { [weak self] in await self?.performRename() }
    }

    private func performRename() async {
        defer { endBusy() }

        // Re-validate right before executing: the folder may have changed while the
        // user was arranging.
        validationTask?.cancel()
        previewRevision &+= 1
        isValidatingDestinations = false
        let itemSnapshot = items
        let ruleSnapshot = rule
        let structural: [RenamePreview]
        let validated: [RenamePreview]
        do {
            structural = try await previewWorker.generate(items: itemSnapshot, rule: ruleSnapshot)
            validated = try await destinationWorker.validate(structural)
        } catch {
            alertMessage = AlertMessage(title: "検証に失敗しました", detail: error.localizedDescription)
            return
        }
        applyPreviews(validated)
        guard errorCount == 0 else {
            alertMessage = AlertMessage(title: "実行できません", detail: "\(errorCount) 件のエラーを解消してください。")
            return
        }

        let snapshot = previews
        let accessBookmarks = bookmarks(
            covering: itemSnapshot.flatMap(\.allURLs).map { $0.deletingLastPathComponent() }
        )
        do {
            let transaction = try await executor.execute(
                previews: snapshot,
                accessBookmarks: accessBookmarks
            ) { [weak self] value in
                Task { @MainActor in self?.progress = value }
            }
            history.record(transaction)
            persistHistory()
            adoptRenamedURLs(from: transaction)
            resultMessage = ResultMessage(
                text: "\(transaction.fileCount) ファイルをリネームしました",
                offersUndo: true
            )
        } catch {
            alertMessage = AlertMessage(title: "リネームに失敗しました", detail: error.localizedDescription)
        }
    }

    func requestUndo() {
        guard canUndo else { return }
        isUndoConfirmationPresented = true
    }

    func confirmUndo() {
        isUndoConfirmationPresented = false
        resultMessage = nil
        performUndo()
    }

    private func performUndo() {
        guard canUndo, let transaction = history.beginUndo() else { return }
        restoreFolderAccess(from: transaction.accessBookmarks)
        let directories = transaction.moves.flatMap {
            [$0.source.deletingLastPathComponent(), $0.destination.deletingLastPathComponent()]
        }
        guard ensureFolderAccess(forDirectories: directories, showCancellationAlert: true) else { return }
        guard beginBusy("元に戻しています…", critical: true) else { return }
        busyTask = Task { [weak self] in await self?.revert(transaction) }
    }

    func redo() {
        guard canRedo, let transaction = history.beginRedo() else { return }
        restoreFolderAccess(from: transaction.accessBookmarks)
        let directories = transaction.moves.flatMap {
            [$0.source.deletingLastPathComponent(), $0.destination.deletingLastPathComponent()]
        }
        guard ensureFolderAccess(forDirectories: directories, showCancellationAlert: true) else { return }
        guard beginBusy("やり直しています…", critical: true) else { return }
        busyTask = Task { [weak self] in await self?.reapply(transaction) }
    }

    private func revert(_ transaction: RenameTransaction) async {
        defer { endBusy() }
        do {
            _ = try await executor.revert(transaction)
            history.finishUndo()
            persistHistory()
            adoptRenamedURLs(from: transaction.inverted)
            resultMessage = ResultMessage(text: "\(transaction.fileCount) ファイルを元の名前に戻しました")
        } catch {
            alertMessage = AlertMessage(title: "元に戻せませんでした", detail: error.localizedDescription)
        }
    }

    private func reapply(_ transaction: RenameTransaction) async {
        defer { endBusy() }
        do {
            let previews = transaction.moves.map { operation in
                RenamePreview(
                    itemID: UUID(),
                    counterValue: nil,
                    proposedBaseName: operation.destination.deletingPathExtension().lastPathComponent,
                    operations: [operation]
                )
            }
            _ = try await executor.execute(
                previews: previews,
                accessBookmarks: transaction.accessBookmarks
            )
            history.finishRedo()
            persistHistory()
            adoptRenamedURLs(from: transaction)
            resultMessage = ResultMessage(
                text: "\(transaction.fileCount) ファイルのリネームをやり直しました",
                offersUndo: true
            )
        } catch {
            alertMessage = AlertMessage(title: "やり直せませんでした", detail: error.localizedDescription)
        }
    }

    /// After a successful batch the rows must point at the new paths, otherwise the
    /// next preview would be computed against files that no longer exist.
    private func adoptRenamedURLs(from transaction: RenameTransaction) {
        var mapping: [String: URL] = [:]
        for move in transaction.moves {
            mapping[move.source.standardizedFileURL.path] = move.destination
        }
        items = items.map { item in
            let updatedURLs = item.allURLs.map { mapping[$0.standardizedFileURL.path] ?? $0 }
            guard let primary = updatedURLs.first else { return item }
            return RenameItem(
                id: item.id,
                originalURL: primary,
                companionURLs: Array(updatedURLs.dropFirst()),
                order: item.order,
                isLocked: item.isLocked,
                metadata: item.metadata
            )
        }
        refreshPreviews()
    }

    private func persistHistory() {
        do {
            try historyStore.save(history)
        } catch {
            alertMessage = AlertMessage(title: "履歴を保存できませんでした", detail: error.localizedDescription)
        }
    }

    // MARK: - Finder integration

    func revealInFinder(ids: Set<UUID>) {
        let urls = items.filter { ids.contains($0.id) }.flatMap(\.allURLs)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func openDirectoryInFinder(_ directory: URL) {
        NSWorkspace.shared.open(directory)
    }

    func quickLookSelection() {
        if quickLookURL != nil {
            quickLookURL = nil
            return
        }
        guard let id = selection.first, let item = items.first(where: { $0.id == id }) else { return }
        quickLookURL = item.originalURL
    }

    // MARK: - Busy state

    @discardableResult
    private func beginBusy(
        _ label: String,
        critical: Bool = false,
        cancellable: Bool = false
    ) -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        busyLabel = label
        progress = 0
        preventsTermination = critical
        canCancelBusyOperation = cancellable
        if critical {
            ProcessInfo.processInfo.disableSuddenTermination()
        }
        return true
    }

    private func endBusy() {
        if preventsTermination {
            ProcessInfo.processInfo.enableSuddenTermination()
        }
        isBusy = false
        busyLabel = ""
        progress = 0
        preventsTermination = false
        canCancelBusyOperation = false
        busyTask = nil
    }

    func cancelBusyOperation() {
        guard canCancelBusyOperation else { return }
        busyTask?.cancel()
    }

    private func recoverPendingRenames() async {
        guard beginBusy("前回の処理を確認中…", critical: true) else { return }
        defer { endBusy() }
        let report = await executor.recoverPendingTransactions()
        guard report.hasWork else { return }

        if report.hasUnresolvedWork {
            alertMessage = AlertMessage(
                title: "自動復旧できない処理があります",
                detail: report.messages.joined(separator: "\n")
            )
        } else {
            resultMessage = ResultMessage(
                text: "前回中断された \(report.recoveredFileCount) ファイルを元の名前へ復旧しました"
            )
        }
    }
}
