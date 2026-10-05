import SwiftUI
import AppKit
import RenameKit

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
struct SimilarImageReviewView: View {
    @Environment(\.locale) private var locale
    private var language: ResolvedAppLanguage { ResolvedAppLanguage(locale: locale) }
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
            L10n.format(
                "trash.confirmation.title",
                defaultValue: "Move %d item(s) to Trash?",
                arguments: [selectedItems.count],
                language: language
            ),
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
                Text(L10n.format(
                    "similarity.review.summary",
                    defaultValue: "%d group(s) · %d image(s). Choose which to keep and which to delete.",
                    arguments: [groups.count, allItems.count],
                    language: language
                ))
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
                Text(L10n.format(
                    "count.images",
                    defaultValue: "%d image(s)",
                    arguments: [group.count],
                    language: language
                ))
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
                    .help(L10n.format(
                        "similarity.group.markedForDeletion",
                        defaultValue: "%d item(s) marked for deletion",
                        arguments: [selectedInGroup],
                        language: language
                    ))
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
                    Text(L10n.format(
                        "count.files",
                        defaultValue: "%d file(s)",
                        arguments: [item.allURLs.count],
                        language: language
                    ))
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

            Button(L10n.format(
                "list.removeItems",
                defaultValue: "Remove %d Item(s) from List",
                arguments: [selectedIDs.count],
                language: language
            )) {
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
        guard !selectedIDs.isEmpty else {
            return L10n.string("選択なし", defaultValue: "Nothing Selected", language: language)
        }
        var text = L10n.format(
            "selection.itemCount",
            defaultValue: "%d item(s) selected",
            arguments: [selectedItems.count],
            language: language
        )
        if selectedFileCount != selectedItems.count {
            text += L10n.format(
                "selection.fileCount",
                defaultValue: " (%d files)",
                arguments: [selectedFileCount],
                language: language
            )
        }
        if selectedByteCount > 0 {
            text += " · \(ByteCountFormatter.string(fromByteCount: selectedByteCount, countStyle: .file))"
        }
        return text
    }

    private var trashConfirmationDetail: String {
        let names = selectedItems.prefix(5).map(\.displayName).joined(separator: "\n")
        let remainder = selectedItems.count > 5
            ? L10n.format(
                "trash.confirmation.remainder",
                defaultValue: "\n%d more item(s)",
                arguments: [selectedItems.count - 5],
                language: language
            )
            : ""
        return L10n.format(
            "trash.confirmation.detail",
            defaultValue: "Files will be moved to Finder’s Trash and can be restored there.\n\n%@%@",
            arguments: [names, remainder],
            language: language
        )
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
