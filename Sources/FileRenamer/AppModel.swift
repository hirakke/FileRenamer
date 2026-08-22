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

    func generate(
        items: [RenameItem],
        rule: RenameRule,
        jpegQuality: JPEGQualitySetting,
        preservesJPEGAtMaximumQuality: Bool
    ) throws -> [RenamePreview] {
        try Task.checkCancellation()
        let generated = engine.makePreviews(
            items: items,
            rule: rule,
            jpegQuality: jpegQuality,
            preservesJPEGAtMaximumQuality: preservesJPEGAtMaximumQuality
        )
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
    @Published private(set) var importedFolderRoots: [URL] = []
    @Published private(set) var workingDirectories: [URL] = []
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
    /// Set only while the inline naming-rule text editor is actively editing. This
    /// distinguishes a deliberate text edit from the stale field editor AppKit can
    /// leave as first responder after the user starts arranging files.
    @Published var isRuleTextEditing = false

    @Published private(set) var isBusy = false
    @Published private(set) var busyLabel = ""
    @Published private(set) var progress: Double = 0
    @Published private(set) var canCancelBusyOperation = false
    @Published private(set) var preventsTermination = false
    @Published private(set) var isValidatingDestinations = false
    @Published private(set) var isScanningSimilarImages = false
    @Published private(set) var similarImageMatchesByItemID: [UUID: [SimilarImageMatch]] = [:]
    @Published var similarityReview: SimilarityReview?
    @Published var alertMessage: AlertMessage?
    @Published var resultMessage: ResultMessage?
    @Published var quickLookURL: URL?
    @Published var renameConfirmation: RenameConfirmation?
    @Published var trashConfirmation: TrashConfirmation?
    @Published var isUndoConfirmationPresented = false
    @Published var isImageResizeOriginalChoicePresented = false
    @Published var isOriginalImagesFolderNamePresented = false
    @Published var originalImagesFolderName = ""
    @Published var jpegQualitySetting: JPEGQualitySetting {
        didSet {
            guard jpegQualitySetting != oldValue else { return }
            imageSettingsStore.saveJPEGQuality(jpegQualitySetting)
            refreshPreviews()
        }
    }

    @Published private(set) var history = RenameHistory()

    // MARK: Collaborators

    private let previewWorker = PreviewGenerationWorker()
    private let destinationWorker = DestinationValidationWorker()
    private let importer = FileImporter()
    private let trasher = FileTrasher()
    private let executor = RenameExecutor()
    private let imageProcessor = ImageProcessor()
    private let presetStore: RulePresetStore
    private let historyStore: RenameHistoryStore
    private let imageSettingsStore: ImageSettingsStore
    private let preferences: AppPreferences
    private var busyTask: Task<Void, Never>?
    private var validationTask: Task<Void, Never>?
    private var similarityTask: Task<Void, Never>?
    private var isPreviewRefreshScheduled = false
    private var previewRevision = 0
    private var similarityRevision = 0

    /// Ordering is intentionally separate from filesystem Undo. It only remembers
    /// the row sequence (and selection), so ⌘Z can immediately correct an accidental
    /// drag without implying that files on disk have been touched.
    private struct OrderSnapshot {
        let itemIDs: [UUID]
        let selection: Set<UUID>
    }

    private struct OrderChange {
        let before: OrderSnapshot
        let after: OrderSnapshot
    }

    // Notify the Edit menu when a file order becomes undoable.
    @Published private var orderUndoStack: [OrderChange] = []
    @Published private var orderRedoStack: [OrderChange] = []
    private let maximumOrderHistoryCount = 50

    private struct FolderAccess {
        let url: URL
        let bookmark: Data
        let isActivelyAccessed: Bool
    }

    /// Folder grants are kept for the session and copied into rename history so
    /// Undo can still reach the files after a relaunch.
    private var folderAccess: [String: FolderAccess] = [:]
    private var pendingFolderAccessDirectory: URL?

    struct AlertMessage: Identifiable {
        enum Action {
            case addWorkingFolder
        }

        let id = UUID()
        var title: String
        var detail: String
        var action: Action?
        var actionTitle: String?
    }

    struct ResultMessage: Identifiable {
        let id = UUID()
        var text: String
        var offersUndo: Bool = false
    }

    struct RenameConfirmation: Identifiable {
        let id = UUID()
        let rows: [RenameConfirmationRow]
        let changedItemCount: Int
        let renamedFileCount: Int
        let processedImageCount: Int
        let warningCount: Int
        let originalImagesDirectory: URL?

        var replacesOriginalImages: Bool {
            processedImageCount > 0 && originalImagesDirectory == nil
        }
    }

    struct RenameConfirmationRow: Identifiable {
        let id = UUID()
        let sourceName: String
        let destinationName: String
        let sourceDirectoryPath: String
        let changesName: Bool
        let imageChange: String?
        let warning: String?
    }

    struct TrashConfirmation: Identifiable {
        let id = UUID()
        let itemIDs: Set<UUID>
    }

    /// One cluster of pictures that resemble each other.
    ///
    /// Similarity is transitive in practice — if A matches B and B matches C, the
    /// three are one burst, not two separate pairs — so groups are the connected
    /// components of the match graph rather than raw pairs. Reviewing a burst of five
    /// as one group is the difference between one decision and ten.
    struct DuplicateGroup: Identifiable {
        let id: UUID
        let items: [RenameItem]
        let containsExactMatch: Bool

        var count: Int { items.count }

        /// All-exact groups are safe to sweep; mixed ones need looking at.
        var isEntirelyExact: Bool { containsExactMatch }
    }

    struct SimilarityReview: Identifiable {
        let id = UUID()
        let groups: [DuplicateGroup]
        let focusedGroupID: UUID
    }

    struct SimilarityBadge {
        let count: Int
        let containsExactMatch: Bool
    }

    init(
        presetStore: RulePresetStore = RulePresetStore(),
        historyStore: RenameHistoryStore = RenameHistoryStore(),
        imageSettingsStore: ImageSettingsStore = ImageSettingsStore(),
        preferences: AppPreferences? = nil,
        recoversPendingRenames: Bool = true
    ) {
        self.presetStore = presetStore
        self.historyStore = historyStore
        self.imageSettingsStore = imageSettingsStore
        self.preferences = preferences ?? AppPreferences()
        jpegQualitySetting = imageSettingsStore.loadJPEGQuality()
        viewMode = self.preferences.defaultViewMode
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
    var canUndoOrderChange: Bool { !isBusy && !orderUndoStack.isEmpty }
    var canRedoOrderChange: Bool { !isBusy && !orderRedoStack.isEmpty }
    var showsJPEGQualitySetting: Bool {
        rule.showsJPEGQuality(for: items.flatMap(\.allURLs))
    }
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
    /// User-selected folder roots, plus parent folders for any individually added
    /// files that sit outside those roots. A recursive folder import therefore stays
    /// one understandable workspace instead of expanding into every subdirectory.
    private func calculateWorkingDirectories() -> [URL] {
        guard !items.isEmpty else { return [] }
        let fileDirectories = importedDirectories
        var result = importedFolderRoots.filter { root in
            fileDirectories.contains { directory in
                root.standardizedFileURL == directory.standardizedFileURL
                    || isAncestor(root, of: directory)
            }
        }
        for directory in fileDirectories where !result.contains(where: { root in
            root.standardizedFileURL == directory.standardizedFileURL
                || isAncestor(root, of: directory)
        }) {
            result.append(directory)
        }
        return uniqueDirectories(result)
    }
    var undoConfirmationMessage: String {
        guard let transaction = history.lastTransaction else {
            return "元に戻せるリネーム履歴がありません。"
        }
        return "直前に変更した\(transaction.fileCount)ファイルを、元の状態に戻します。"
    }

    func imageChangeSummary(for item: RenameItem, preview: RenamePreview?) -> String? {
        guard let preview,
              preview.requiresContentProcessing,
              let width = item.metadata.pixelWidth,
              let height = item.metadata.pixelHeight
        else { return nil }

        let target = rule.imageResize.targetDimensions(width: width, height: height)
        let sourceDimensions = "\(width)×\(height)"
        let targetDimensions = "\(target.width)×\(target.height)"
        let targetFormat = preview.destinationURL.pathExtension.uppercased()
        return sourceDimensions == targetDimensions
            ? "\(sourceDimensions) • \(targetFormat)へ再保存"
            : "\(sourceDimensions) → \(targetDimensions) • \(targetFormat)"
    }

    func preferencesDidChange() {
        refreshPreviews()
    }

    func similarityPreferencesDidChange() {
        scheduleSimilarityScan()
    }

    func preview(for item: RenameItem) -> RenamePreview? { previewsByItemID[item.id] }

    func similarityBadge(for itemID: UUID) -> SimilarityBadge? {
        guard let matches = similarImageMatchesByItemID[itemID], !matches.isEmpty else { return nil }
        return SimilarityBadge(
            count: matches.count,
            containsExactMatch: matches.contains { $0.kind == .exact }
        )
    }

    /// Connected components of the match graph, in list order.
    ///
    /// Rebuilt on demand rather than cached: the input is at most a few hundred
    /// items, and a stale group list would be far worse than a recomputation.
    var duplicateGroups: [DuplicateGroup] {
        guard !similarImageMatchesByItemID.isEmpty else { return [] }

        var parent: [UUID: UUID] = [:]
        func find(_ id: UUID) -> UUID {
            var root = id
            while let next = parent[root], next != root { root = next }
            // Path compression keeps repeated lookups flat.
            var cursor = id
            while let next = parent[cursor], next != root {
                parent[cursor] = root
                cursor = next
            }
            return root
        }
        func union(_ lhs: UUID, _ rhs: UUID) {
            let left = find(lhs)
            let right = find(rhs)
            guard left != right else { return }
            parent[left] = right
        }

        for (itemID, matches) in similarImageMatchesByItemID {
            parent[itemID] = parent[itemID] ?? itemID
            for match in matches {
                parent[match.otherItemID] = parent[match.otherItemID] ?? match.otherItemID
                union(itemID, match.otherItemID)
            }
        }

        // Walking `items` rather than the dictionary keeps groups, and the pictures
        // inside them, in the order the user already sees.
        var membersByRoot: [UUID: [RenameItem]] = [:]
        var rootOrder: [UUID] = []
        for item in items where parent[item.id] != nil {
            let root = find(item.id)
            if membersByRoot[root] == nil { rootOrder.append(root) }
            membersByRoot[root, default: []].append(item)
        }

        return rootOrder.compactMap { root in
            guard let members = membersByRoot[root], members.count > 1 else { return nil }
            let memberIDs = Set(members.map(\.id))
            let containsExact = members.contains { item in
                (similarImageMatchesByItemID[item.id] ?? []).contains {
                    $0.kind == .exact && memberIDs.contains($0.otherItemID)
                }
            }
            return DuplicateGroup(id: root, items: members, containsExactMatch: containsExact)
        }
    }

    var duplicateGroupCount: Int { duplicateGroups.count }

    /// True when at least one group is byte-identical rather than merely alike.
    /// Drives the colour of the aggregate badge: the stronger verdict wins.
    var hasExactDuplicates: Bool {
        similarImageMatchesByItemID.values.contains { matches in
            matches.contains { $0.kind == .exact }
        }
    }

    func showSimilarImages(for itemID: UUID) {
        let groups = duplicateGroups
        guard let focused = groups.first(where: { group in
            group.items.contains { $0.id == itemID }
        }) else { return }
        similarityReview = SimilarityReview(groups: groups, focusedGroupID: focused.id)
    }

    func showFirstSimilarImageGroup() {
        let groups = duplicateGroups
        guard let first = groups.first else { return }
        similarityReview = SimilarityReview(groups: groups, focusedGroupID: first.id)
    }

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
        requestFolderAccessForIndividuallyImportedFiles(in: urls)
        guard beginBusy("読み込み中…", cancellable: true) else { return }
        let transientAccess = beginImportAccess(for: urls)
        // Resolve directory metadata only after opening the security-scoped URLs;
        // external volumes and sandboxed drag-and-drop locations may require it.
        let folderRoots = folderURLs(in: urls)
        let options = importOptions
        busyTask = Task { [weak self] in
            await self?.performImport(
                urls,
                options: options,
                transientAccess: transientAccess,
                folderRoots: folderRoots
            )
        }
    }

    private func performImport(
        _ urls: [URL],
        options: ImportOptions,
        transientAccess: [URL],
        folderRoots: [URL]
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
            workingDirectories = calculateWorkingDirectories()
            resultMessage = ResultMessage(text: "読み込みをキャンセルしました")
            return
        } catch {
            workingDirectories = calculateWorkingDirectories()
            alertMessage = AlertMessage(title: "読み込めませんでした", detail: error.localizedDescription)
            return
        }

        // Dropping the same file twice should not create a second row.
        let known = Set(items.flatMap { $0.allURLs.map(\.standardizedFileURL.path) })
        let fresh = result.items.filter { item in
            !item.allURLs.contains { known.contains($0.standardizedFileURL.path) }
        }

        items = ItemSorter.reindexed(items + fresh)
        invalidateOrderHistory()
        if !result.items.isEmpty {
            recordImportedFolderRoots(folderRoots)
        }
        workingDirectories = calculateWorkingDirectories()
        endBusy()
        endedBusy = true

        refreshPreviews()
        scheduleSimilarityScan()

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
        invalidateOrderHistory()
        clearSimilarityResults()
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

    func presentFolderAccessPanel() {
        guard let directory = pendingFolderAccessDirectory else { return }
        defer { pendingFolderAccessDirectory = nil }
        _ = requestFolderAccess(to: directory, reportsErrors: true)
    }

    /// A folder selected through the import command already carries a directory
    /// grant. Files selected one by one only carry file-level access, so request
    /// their containing folder immediately rather than interrupting Rename later.
    private func requestFolderAccessForIndividuallyImportedFiles(in urls: [URL]) {
        let fileDirectories = urls.compactMap { url -> URL? in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            return isDirectory ? nil : url.deletingLastPathComponent()
        }

        for directory in uniqueDirectories(fileDirectories) {
            guard !hasFolderAccess(covering: directory),
                  !canWriteWithoutAdditionalGrant(to: directory)
            else { continue }
            guard requestFolderAccess(to: directory, reportsErrors: false) else { break }
        }
    }

    @discardableResult
    private func requestFolderAccess(to directory: URL, reportsErrors: Bool) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = directory.deletingLastPathComponent()
        panel.title = "「\(directory.lastPathComponent)」へのアクセスを許可"
        panel.prompt = "アクセスを許可"
        panel.message = "「\(directory.lastPathComponent)」または親フォルダへのアクセスを許可してください。"

        guard panel.runModal() == .OK, let selected = panel.url else { return false }
        guard selected.standardizedFileURL == directory.standardizedFileURL
                || isAncestor(selected, of: directory) else {
            if reportsErrors {
                alertMessage = AlertMessage(
                    title: "「\(directory.lastPathComponent)」を選択してください",
                    detail: "このフォルダ、または親フォルダを選択してください。"
                )
            }
            return false
        }

        let started = selected.startAccessingSecurityScopedResource()
        guard let bookmark = try? selected.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            if started { selected.stopAccessingSecurityScopedResource() }
            if reportsErrors {
                alertMessage = AlertMessage(
                    title: "アクセスを許可できませんでした",
                    detail: "もう一度お試しください。"
                )
            }
            return false
        }

        registerFolderAccess(url: selected, bookmark: bookmark, isActive: started)
        return true
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

    private func folderURLs(in urls: [URL]) -> [URL] {
        uniqueDirectories(urls.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        })
    }

    private func recordImportedFolderRoots(_ roots: [URL]) {
        var merged = importedFolderRoots.map(\.standardizedFileURL)
        for root in roots.map(\.standardizedFileURL) {
            if merged.contains(where: {
                $0 == root || isAncestor($0, of: root)
            }) {
                continue
            }
            merged.removeAll(where: { isAncestor(root, of: $0) })
            merged.append(root)
        }
        importedFolderRoots = uniqueDirectories(merged)
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
            if showCancellationAlert {
                pendingFolderAccessDirectory = directory
                alertMessage = AlertMessage(
                    title: "「\(directory.lastPathComponent)」へのアクセスを許可",
                    detail: "リネームを続けるには、現在読み込んでいるフォルダへのアクセスを許可してください。",
                    action: .addWorkingFolder,
                    actionTitle: "「\(directory.lastPathComponent)」を選択…"
                )
            }
            return false
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
        items = ItemSorter.reindexed(items.filter { !selection.contains($0.id) })
        invalidateOrderHistory()
        if items.isEmpty { importedFolderRoots = [] }
        workingDirectories = calculateWorkingDirectories()
        selection.removeAll()
        refreshPreviews()
        scheduleSimilarityScan()
    }

    /// Drops rows without touching the files. The safe half of duplicate review:
    /// the picture stays on disk, it just stops being part of this rename.
    func removeFromList(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        items = ItemSorter.reindexed(items.filter { !ids.contains($0.id) })
        invalidateOrderHistory()
        if items.isEmpty { importedFolderRoots = [] }
        workingDirectories = calculateWorkingDirectories()
        selection.subtract(ids)
        refreshPreviews()
        scheduleSimilarityScan()
    }

    /// Moves the chosen rows' files to the Trash and drops them from the list.
    ///
    /// Every file of an item goes together — a RAW+JPEG pair is one picture, and
    /// leaving half of it behind would be a worse outcome than leaving both.
    /// Files go to the Trash rather than being erased, so a mistaken pick during a
    /// side-by-side comparison is always recoverable from the Finder.
    func moveToTrash(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        Task { await performTrash(ids: ids) }
    }

    /// Finder-style contextual actions operate on the current multi-selection when
    /// the clicked item is already selected; otherwise they affect just that item.
    /// Destructive actions always pause for an explicit confirmation.
    func requestMoveToTrash(ids: Set<UUID>) {
        guard !isBusy else { return }
        let targets = effectiveTargets(for: ids)
        guard !targets.isEmpty else { return }
        selection = targets
        trashConfirmation = TrashConfirmation(itemIDs: targets)
    }

    func confirmMoveToTrash() {
        guard let request = trashConfirmation else { return }
        trashConfirmation = nil
        moveToTrash(ids: request.itemIDs)
    }

    func cancelMoveToTrashConfirmation() {
        trashConfirmation = nil
    }

    var trashConfirmationItems: [RenameItem] {
        guard let request = trashConfirmation else { return [] }
        return items.filter { request.itemIDs.contains($0.id) }
    }

    private func performTrash(ids: Set<UUID>) async {
        let targets = items.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }
        let directories = targets
            .flatMap(\.allURLs)
            .map { $0.deletingLastPathComponent() }
        guard ensureFolderAccess(forDirectories: directories, showCancellationAlert: true) else { return }

        guard beginBusy("ゴミ箱に移動中…", critical: true) else { return }
        let outcome = await trasher.moveToTrash(groups: targets.map(\.allURLs))
        endBusy()

        // Only rows whose files actually left are dropped; anything that failed stays
        // visible so the problem is not silently swallowed.
        let failedPaths = Set(outcome.failures.map(\.url.standardizedFileURL.path))
        let removedIDs = Set(
            targets
                .filter { item in !item.allURLs.contains { failedPaths.contains($0.standardizedFileURL.path) } }
                .map(\.id)
        )
        if !removedIDs.isEmpty {
            removeFromList(ids: removedIDs)
        }

        if outcome.failures.isEmpty {
            let fileCount = outcome.trashedURLs.count
            let itemCount = removedIDs.count
            resultMessage = ResultMessage(
                text: fileCount == 0
                    ? "既に見つからない \(itemCount) 件をリストから除外しました"
                    : itemCount == fileCount
                        ? "\(itemCount) 件をゴミ箱に移動しました"
                        : "\(itemCount) 件（\(fileCount) ファイル）をゴミ箱に移動しました"
            )
        } else {
            let detail = outcome.failures
                .prefix(5)
                .map { "\($0.url.lastPathComponent): \($0.message)" }
                .joined(separator: "\n")
            alertMessage = AlertMessage(
                title: "ゴミ箱に移動できないファイルがあります",
                detail: detail
            )
        }
    }

    func removeAll() {
        items = []
        invalidateOrderHistory()
        importedFolderRoots = []
        workingDirectories = []
        selection.removeAll()
        refreshPreviews()
        scheduleSimilarityScan()
    }

    func selectAll() {
        selection = Set(items.map(\.id))
    }

    /// Drag & drop in the list.
    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        applyOrderChange {
            ItemSorter.move($0, fromOffsets: offsets, toOffset: destination)
        }
    }

    /// Drag & drop in the grid, where a drop lands on a cell instead of a gap.
    func move(ids: Set<UUID>, toIndex index: Int) {
        applyOrderChange {
            ItemSorter.move($0, ids: ids, toIndex: index)
        }
    }

    /// Backs the per-row ◀ ▶ buttons and the ⌘↑ / ⌘↓ shortcuts.
    /// Acts on the whole selection when the row is part of it, matching Finder.
    func shift(ids: Set<UUID>, by delta: Int) {
        let targets = effectiveTargets(for: ids)
        guard !targets.isEmpty else { return }
        applyOrderChange {
            ItemSorter.shift($0, ids: targets, by: delta)
        }
    }

    /// Row that should remain visible after a single-step move or issue selection.
    /// `ScrollViewReader` only moves the viewport when this row would leave it.
    @Published private(set) var scrollTargetID: UUID?
    @Published private(set) var scrollTick = 0

    func stepFromRow(_ id: UUID, by delta: Int) {
        let targets = effectiveTargets(for: [id])
        guard !targets.isEmpty, ItemSorter.canShift(items, ids: targets, by: delta) else { return }

        applyOrderChange(
            { ItemSorter.shift($0, ids: targets, by: delta) },
            selectionAfterChange: targets
        )
        requestScroll(towards: delta, among: targets)
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
        ItemSorter.canShift(items, ids: effectiveTargets(for: [id]), by: delta)
    }

    func moveToEdge(ids: Set<UUID>, toStart: Bool) {
        let targets = effectiveTargets(for: ids)
        guard !targets.isEmpty else { return }
        applyOrderChange {
            ItemSorter.moveToEdge($0, ids: targets, toStart: toStart)
        }
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
        sortOption = option
        applyOrderChange { ItemSorter.sorted($0, by: option) }
    }

    func reverseOrder() {
        applyOrderChange { ItemSorter.reindexed($0.reversed()) }
    }

    func undoOrderChange() {
        guard !isBusy, let change = orderUndoStack.popLast() else { return }
        guard applyOrderSnapshot(change.before) else {
            invalidateOrderHistory()
            return
        }
        orderRedoStack.append(change)
    }

    func redoOrderChange() {
        guard !isBusy, let change = orderRedoStack.popLast() else { return }
        guard applyOrderSnapshot(change.after) else {
            invalidateOrderHistory()
            return
        }
        orderUndoStack.append(change)
    }

    private func applyOrderChange(
        _ transform: ([RenameItem]) -> [RenameItem],
        selectionAfterChange: Set<UUID>? = nil
    ) {
        let before = makeOrderSnapshot()
        let updatedItems = transform(items)
        let updatedIDs = updatedItems.map(\.id)
        guard updatedIDs != before.itemIDs else { return }

        endRuleTextEditing()
        items = updatedItems
        if let selectionAfterChange {
            selection = selectionAfterChange
        }

        let change = OrderChange(before: before, after: makeOrderSnapshot())
        orderUndoStack.append(change)
        if orderUndoStack.count > maximumOrderHistoryCount {
            orderUndoStack.removeFirst(orderUndoStack.count - maximumOrderHistoryCount)
        }
        orderRedoStack.removeAll()
        refreshPreviews()
    }

    private func makeOrderSnapshot() -> OrderSnapshot {
        OrderSnapshot(itemIDs: items.map(\.id), selection: selection)
    }

    /// Restoring by IDs, rather than storing whole `RenameItem` values, preserves
    /// fresh URLs and metadata if a successful rename happened after a reorder.
    private func applyOrderSnapshot(_ snapshot: OrderSnapshot) -> Bool {
        guard snapshot.itemIDs.count == items.count else { return false }
        let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        guard snapshot.itemIDs.allSatisfy({ itemsByID[$0] != nil }) else { return false }

        items = ItemSorter.reindexed(snapshot.itemIDs.compactMap { itemsByID[$0] })
        selection = snapshot.selection.intersection(Set(snapshot.itemIDs))
        refreshPreviews()
        return true
    }

    private func invalidateOrderHistory() {
        orderUndoStack.removeAll()
        orderRedoStack.removeAll()
    }

    private func endRuleTextEditing() {
        guard isRuleTextEditing
                || (NSApp.keyWindow?.firstResponder as? NSTextView)?.isFieldEditor == true
        else { return }

        NSApp.keyWindow?.makeFirstResponder(nil)
        // AppKit normally sends `controlTextDidEndEditing` synchronously. Set this
        // here as well so the command menu cannot see a stale editing state during
        // the same drag/drop event cycle.
        isRuleTextEditing = false
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

    // MARK: - Similar images

    /// Starts a local background scan for the current immutable item snapshot.
    /// Ordering changes do not call this method because results are keyed by item ID.
    private func scheduleSimilarityScan() {
        similarityTask?.cancel()
        similarityRevision &+= 1
        let revision = similarityRevision
        similarityReview = nil

        guard preferences.detectsSimilarImages else {
            clearSimilarityResults(cancelTask: false)
            return
        }

        let candidates = items.compactMap { item -> SimilarImageCandidate? in
            let imageURLs = item.allURLs.filter(FileKinds.isImage)
            guard !imageURLs.isEmpty else { return nil }
            let analysisURL = imageURLs.first(where: { !FileKinds.isRAW($0) }) ?? imageURLs[0]
            return SimilarImageCandidate(
                itemID: item.id,
                analysisURL: analysisURL,
                allURLs: item.allURLs
            )
        }
        guard candidates.count > 1 else {
            clearSimilarityResults(cancelTask: false)
            return
        }

        let configuration = preferences.similarImageScanConfiguration
        isScanningSimilarImages = true
        similarityTask = Task { [weak self] in
            guard let self else { return }
            do {
                let matches = try await SimilarImageDetector.shared.scan(
                    candidates: candidates,
                    configuration: configuration
                )
                guard !Task.isCancelled, self.similarityRevision == revision else { return }
                self.similarImageMatchesByItemID = matches
                self.isScanningSimilarImages = false
            } catch is CancellationError {
                if self.similarityRevision == revision {
                    self.isScanningSimilarImages = false
                }
            } catch {
                if self.similarityRevision == revision {
                    self.similarImageMatchesByItemID = [:]
                    self.isScanningSimilarImages = false
                }
            }
        }
    }

    private func clearSimilarityResults(cancelTask: Bool = true) {
        if cancelTask { similarityTask?.cancel() }
        similarityTask = nil
        similarImageMatchesByItemID = [:]
        isScanningSimilarImages = false
        similarityReview = nil
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
                    rule: ruleSnapshot,
                    jpegQuality: self.jpegQualitySetting,
                    preservesJPEGAtMaximumQuality: self.preferences.preservesJPEGAtMaximumQuality
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
        // These values describe one snapshot and must be published atomically. The
        // notification is deferred because preview generation can complete while a
        // rule field is still inside SwiftUI's update transaction.
        previews = newPreviews
        previewsByItemID = Dictionary(uniqueKeysWithValues: newPreviews.map { ($0.itemID, $0) })
        errorCount = newPreviews.errorCount
        warningCount = newPreviews.warningCount
        changedCount = newPreviews.changedCount

        guard !isPreviewRefreshScheduled else { return }
        isPreviewRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isPreviewRefreshScheduled = false
            self.objectWillChange.send()
        }
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
        if previews.contains(where: { $0.requiresContentProcessing }),
           preferences.confirmsOriginalProtection {
            isImageResizeOriginalChoicePresented = true
            return
        }
        requestRename(originalImagesDirectory: nil)
    }

    func replaceOriginalImagesForResize() {
        isImageResizeOriginalChoicePresented = false
        DispatchQueue.main.async { [weak self] in
            self?.requestRename(originalImagesDirectory: nil)
        }
    }

    func chooseOriginalImagesDestinationForResize() {
        isImageResizeOriginalChoicePresented = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.originalImagesFolderName = self.defaultOriginalImagesFolderName()
            self.isOriginalImagesFolderNamePresented = true
        }
    }

    func confirmOriginalImagesFolderName() {
        let name = originalImagesFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains(":") else {
            alertMessage = AlertMessage(
                title: "フォルダ名を使用できません",
                detail: "空欄、`.`、`..`、`/`、`:` はフォルダ名に使用できません。"
            )
            return
        }
        originalImagesFolderName = name
        isOriginalImagesFolderNamePresented = false
        DispatchQueue.main.async { [weak self] in
            self?.presentOriginalImagesDestinationPanel()
        }
    }

    private func presentOriginalImagesDestinationPanel() {
        guard canRename else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "保存場所を選択"
        panel.message = "選択した場所に元画像専用の新しいフォルダを作成します。"
        panel.directoryURL = importedDirectories.count == 1 ? importedDirectories.first : nil
        guard panel.runModal() == .OK, let parentDirectory = panel.url else { return }

        let started = parentDirectory.startAccessingSecurityScopedResource()
        guard let bookmark = try? parentDirectory.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            if started { parentDirectory.stopAccessingSecurityScopedResource() }
            alertMessage = AlertMessage(
                title: "保存先へのアクセスを許可できませんでした",
                detail: "別のフォルダを選択して、もう一度お試しください。"
            )
            return
        }
        registerFolderAccess(url: parentDirectory, bookmark: bookmark, isActive: started)

        let originalsDirectory = parentDirectory.appendingPathComponent(
            originalImagesFolderName,
            isDirectory: true
        )
        guard !FileManager.default.fileExists(atPath: originalsDirectory.path) else {
            alertMessage = AlertMessage(
                title: "同名の保存フォルダがあります",
                detail: "「\(originalsDirectory.lastPathComponent)」が既に存在します。ファイルは変更していません。もう一度保存場所を選択してください。"
            )
            return
        }

        let collisions = originalImageNameCollisions()
        guard collisions.isEmpty else {
            let shownNames = collisions.prefix(5).joined(separator: "、")
            let remainder = collisions.count > 5 ? " ほか\(collisions.count - 5)件" : ""
            alertMessage = AlertMessage(
                title: "同名の元画像があります",
                detail: "保存対象内で「\(shownNames)」\(remainder)の名前が重複しています。ファイルは変更していません。重複する画像名を変更してから、もう一度実行してください。"
            )
            return
        }
        requestRename(originalImagesDirectory: originalsDirectory)
    }

    private func defaultOriginalImagesFolderName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "FileRenamer 元画像 \(formatter.string(from: Date()))"
    }

    private func originalImageNameCollisions() -> [String] {
        var seenNames = Set<String>()
        var collisions = Set<String>()
        for preview in previews {
            for operation in preview.operations {
                guard rule.imageEditConfiguration(
                    for: operation.source,
                    jpegQuality: jpegQualitySetting,
                    preservesJPEGAtMaximumQuality: preferences.preservesJPEGAtMaximumQuality
                ) != nil else { continue }
                let name = operation.source.lastPathComponent
                let comparisonName = name.precomposedStringWithCanonicalMapping.lowercased()
                if !seenNames.insert(comparisonName).inserted {
                    collisions.insert(name)
                }
            }
        }
        return collisions.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private func requestRename(originalImagesDirectory: URL?) {
        guard canRename else { return }
        guard preferences.confirmsRenameChanges else {
            beginRename(originalImagesDirectory: originalImagesDirectory)
            return
        }
        renameConfirmation = makeRenameConfirmation(
            originalImagesDirectory: originalImagesDirectory
        )
    }

    func confirmRename() {
        guard let confirmation = renameConfirmation else { return }
        let originalImagesDirectory = confirmation.originalImagesDirectory
        renameConfirmation = nil
        DispatchQueue.main.async { [weak self] in
            self?.beginRename(originalImagesDirectory: originalImagesDirectory)
        }
    }

    private func makeRenameConfirmation(
        originalImagesDirectory: URL?
    ) -> RenameConfirmation {
        var rows: [RenameConfirmationRow] = []
        var changedItemIDs = Set<UUID>()

        for item in items {
            guard let preview = previewsByItemID[item.id],
                  !preview.validation.isError else { continue }

            var includedItem = false
            for operation in preview.operations {
                let imageConfiguration = rule.imageEditConfiguration(
                    for: operation.source,
                    jpegQuality: jpegQualitySetting,
                    preservesJPEGAtMaximumQuality: preferences.preservesJPEGAtMaximumQuality
                )
                guard !operation.isNoop || imageConfiguration != nil else { continue }

                rows.append(RenameConfirmationRow(
                    sourceName: operation.source.lastPathComponent,
                    destinationName: operation.destination.lastPathComponent,
                    sourceDirectoryPath: operation.source.deletingLastPathComponent().path,
                    changesName: !operation.isNoop,
                    imageChange: imageConfiguration == nil
                        ? nil
                        : imageConfirmationSummary(for: item, operation: operation),
                    warning: preview.validation.message
                ))
                includedItem = true
            }
            if includedItem { changedItemIDs.insert(item.id) }
        }

        return RenameConfirmation(
            rows: rows,
            changedItemCount: changedItemIDs.count,
            renamedFileCount: rows.filter(\.changesName).count,
            processedImageCount: rows.filter { $0.imageChange != nil }.count,
            warningCount: changedItemIDs.reduce(into: 0) { count, itemID in
                if previewsByItemID[itemID]?.validation.isWarning == true { count += 1 }
            },
            originalImagesDirectory: originalImagesDirectory
        )
    }

    private func imageConfirmationSummary(
        for item: RenameItem,
        operation: RenameOperation
    ) -> String {
        var details: [String] = []

        if rule.imageResize.isEnabled,
           let width = item.metadata.pixelWidth,
           let height = item.metadata.pixelHeight {
            let target = rule.imageResize.targetDimensions(width: width, height: height)
            if width == target.width, height == target.height {
                details.append("サイズ維持 \(width)×\(height) px")
            } else {
                details.append("\(width)×\(height) → \(target.width)×\(target.height) px")
            }
        } else if rule.imageResize.isEnabled {
            details.append("長辺 \(rule.imageResize.normalizedLongEdge) px")
        }

        let sourceExtension = operation.source.pathExtension.uppercased()
        let destinationExtension = operation.destination.pathExtension.uppercased()
        if sourceExtension != destinationExtension {
            details.append("\(sourceExtension.isEmpty ? "拡張子なし" : sourceExtension) → \(destinationExtension.isEmpty ? "拡張子なし" : destinationExtension)")
        } else if !destinationExtension.isEmpty {
            details.append("\(destinationExtension)で再保存")
        }

        if FileKinds.isJPEG(operation.destination) {
            details.append("品質 \(jpegQualitySetting.percent)%")
        }

        return details.isEmpty ? "画像データを再生成" : details.joined(separator: "・")
    }

    private func beginRename(originalImagesDirectory: URL?) {
        guard canRename else { return }
        var changedDirectories = previews
            .flatMap { preview in
                preview.requiresContentProcessing ? preview.operations : preview.effectiveOperations
            }
            .flatMap { [$0.source.deletingLastPathComponent(), $0.destination.deletingLastPathComponent()] }
        if let originalImagesDirectory { changedDirectories.append(originalImagesDirectory) }
        guard ensureFolderAccess(forDirectories: changedDirectories, showCancellationAlert: true) else { return }
        guard beginBusy("ファイルを変更中…", critical: true) else { return }
        busyTask = Task { [weak self] in
            await self?.performRename(originalImagesDirectory: originalImagesDirectory)
        }
    }

    private func performRename(originalImagesDirectory: URL?) async {
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
            structural = try await previewWorker.generate(
                items: itemSnapshot,
                rule: ruleSnapshot,
                jpegQuality: jpegQualitySetting,
                preservesJPEGAtMaximumQuality: preferences.preservesJPEGAtMaximumQuality
            )
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
                + [originalImagesDirectory].compactMap { $0 }
        )
        do {
            let hasMoves = snapshot.contains { !$0.effectiveOperations.isEmpty }
            var transaction: RenameTransaction
            if hasMoves {
                transaction = try await executor.execute(
                    previews: snapshot,
                    accessBookmarks: accessBookmarks
                ) { [weak self] value in
                    Task { @MainActor in self?.progress = value * 0.55 }
                }
            } else {
                transaction = RenameTransaction(moves: [], accessBookmarks: accessBookmarks)
            }

            let imageRequests = snapshot.flatMap { preview in
                preview.operations.compactMap { operation -> ImageEditRequest? in
                    guard let configuration = ruleSnapshot.imageEditConfiguration(
                        for: operation.source,
                        jpegQuality: jpegQualitySetting,
                        preservesJPEGAtMaximumQuality: preferences.preservesJPEGAtMaximumQuality
                    ) else {
                        return nil
                    }
                    return ImageEditRequest(
                        url: operation.destination,
                        configuration: configuration,
                        originalCopyDirectory: originalImagesDirectory,
                        originalFileName: operation.source.lastPathComponent
                    )
                }
            }
            if !imageRequests.isEmpty {
                do {
                    let records = try await imageProcessor.apply(
                        requests: imageRequests,
                        transactionID: transaction.id,
                        renameMoves: transaction.moves,
                        accessBookmarks: accessBookmarks
                    ) { [weak self] value in
                        Task { @MainActor in self?.progress = 0.55 + value * 0.45 }
                    }
                    transaction = transaction.addingImageEdits(records)
                } catch {
                    if hasMoves { _ = try? await executor.revert(transaction) }
                    throw error
                }
            }
            let discardedHistory = history.record(transaction)
            imageProcessor.removeBackups(for: discardedHistory)
            persistHistory()
            adoptRenamedURLs(from: transaction)
            progress = 1
            let action = imageRequests.isEmpty ? "リネーム" : "変更"
            resultMessage = ResultMessage(
                text: "\(transaction.fileCount) ファイルを\(action)しました",
                offersUndo: true
            )
        } catch {
            alertMessage = AlertMessage(title: "変更に失敗しました", detail: error.localizedDescription)
        }
    }

    func requestUndo() {
        guard canUndo else { return }
        if preferences.confirmsUndo {
            isUndoConfirmationPresented = true
        } else {
            resultMessage = nil
            performUndo()
        }
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
        } + transaction.imageEdits.map { $0.fileURL.deletingLastPathComponent() }
        guard ensureFolderAccess(forDirectories: directories, showCancellationAlert: true) else { return }
        guard beginBusy("元に戻しています…", critical: true) else { return }
        busyTask = Task { [weak self] in await self?.revert(transaction) }
    }

    func redo() {
        guard canRedo, let transaction = history.beginRedo() else { return }
        restoreFolderAccess(from: transaction.accessBookmarks)
        let directories = transaction.moves.flatMap {
            [$0.source.deletingLastPathComponent(), $0.destination.deletingLastPathComponent()]
        } + transaction.imageEdits.map { $0.fileURL.deletingLastPathComponent() }
        guard ensureFolderAccess(forDirectories: directories, showCancellationAlert: true) else { return }
        guard beginBusy("やり直しています…", critical: true) else { return }
        busyTask = Task { [weak self] in await self?.reapply(transaction) }
    }

    private func revert(_ transaction: RenameTransaction) async {
        defer { endBusy() }
        do {
            var restoredImages = false
            if !transaction.imageEdits.isEmpty {
                try await imageProcessor.restore(transaction.imageEdits) { [weak self] value in
                    Task { @MainActor in self?.progress = value * 0.45 }
                }
                restoredImages = true
            }
            if !transaction.moves.isEmpty {
                do {
                    _ = try await executor.revert(transaction) { [weak self] value in
                        Task { @MainActor in self?.progress = 0.45 + value * 0.55 }
                    }
                } catch {
                    if restoredImages { try? await imageProcessor.reapply(transaction.imageEdits) }
                    throw error
                }
            }
            history.finishUndo()
            persistHistory()
            adoptRenamedURLs(from: transaction.inverted)
            resultMessage = ResultMessage(text: "\(transaction.fileCount) ファイルを元の状態に戻しました")
        } catch {
            alertMessage = AlertMessage(title: "元に戻せませんでした", detail: error.localizedDescription)
        }
    }

    private func reapply(_ transaction: RenameTransaction) async {
        defer { endBusy() }
        do {
            var reappliedRename: RenameTransaction?
            if !transaction.moves.isEmpty {
                let previews = transaction.moves.map { operation in
                    RenamePreview(
                        itemID: UUID(),
                        counterValue: nil,
                        proposedBaseName: operation.destination.deletingPathExtension().lastPathComponent,
                        operations: [operation]
                    )
                }
                reappliedRename = try await executor.execute(
                    previews: previews,
                    accessBookmarks: transaction.accessBookmarks
                ) { [weak self] value in
                    Task { @MainActor in self?.progress = value * 0.55 }
                }
            }
            if !transaction.imageEdits.isEmpty {
                do {
                    try await imageProcessor.reapply(transaction.imageEdits) { [weak self] value in
                        Task { @MainActor in self?.progress = 0.55 + value * 0.45 }
                    }
                } catch {
                    if let reappliedRename { _ = try? await executor.revert(reappliedRename) }
                    throw error
                }
            }
            history.finishRedo()
            persistHistory()
            adoptRenamedURLs(from: transaction)
            resultMessage = ResultMessage(
                text: "\(transaction.fileCount) ファイルの変更をやり直しました",
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
        let editedPaths = Set(transaction.imageEdits.map { $0.fileURL.standardizedFileURL.path })
        let metadataLoader = MetadataLoader()
        items = items.map { item in
            let updatedURLs = item.allURLs.map { mapping[$0.standardizedFileURL.path] ?? $0 }
            guard let primary = updatedURLs.first else { return item }
            let touchesEditedImage = item.allURLs.contains {
                editedPaths.contains($0.standardizedFileURL.path)
            } || updatedURLs.contains {
                editedPaths.contains($0.standardizedFileURL.path)
            }
            return RenameItem(
                id: item.id,
                originalURL: primary,
                companionURLs: Array(updatedURLs.dropFirst()),
                order: item.order,
                isLocked: item.isLocked,
                metadata: touchesEditedImage ? metadataLoader.load(for: updatedURLs) : item.metadata
            )
        }
        workingDirectories = calculateWorkingDirectories()
        refreshPreviews()
        scheduleSimilarityScan()
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

    func copyDirectoryPath(_ directory: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(directory.path, forType: .string)
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
        let imageReport = await imageProcessor.recoverPendingTransactions()
        let report = await executor.recoverPendingTransactions()
        guard imageReport.hasWork || report.hasWork else { return }

        if imageReport.hasUnresolvedWork || report.hasUnresolvedWork {
            alertMessage = AlertMessage(
                title: "自動復旧できない処理があります",
                detail: (imageReport.messages + report.messages).joined(separator: "\n")
            )
        } else {
            let recoveredCount = imageReport.recoveredFileCount + report.recoveredFileCount
            resultMessage = ResultMessage(
                text: "前回中断された \(recoveredCount) ファイルを元の状態へ復旧しました"
            )
        }
    }
}
