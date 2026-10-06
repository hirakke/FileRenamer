import SwiftUI
import UniformTypeIdentifiers
import RenameKit

/// The main "Arrange" surface: rows in list order, each showing the number it will
/// get, the original name and the resulting name. Dragging a row renumbers everything.
struct FileListView: View {
    @Environment(\.locale) private var locale
    private var language: ResolvedAppLanguage { ResolvedAppLanguage(locale: locale) }
    @EnvironmentObject private var model: AppModel
    @State private var selectionAnchor: UUID?
    /// Captured at drag start, so a multi-selection moves as one contiguous block.
    @State private var draggingIDs: Set<UUID> = []
    /// Gap in the pre-move list where the dragged rows will be inserted.
    @State private var insertionIndex: Int?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 8) {
                            let preview = model.preview(for: item)
                            FileRow(
                                item: item,
                                preview: preview,
                                sortField: model.sortOption.field,
                                imageChangeSummary: model.imageChangeSummary(for: item, preview: preview),
                                similarityBadge: model.similarityBadge(for: item.id),
                                onShowSimilarity: { model.showSimilarImages(for: item.id) }
                            )
                            OrderStepper(id: item.id, axis: .vertical)
                        }
                        .contentShape(Rectangle())
                        .overlay(alignment: .top) {
                            ListInsertionMarker(isActive: insertionIndex == index)
                        }
                        .overlay(alignment: .bottom) {
                            ListInsertionMarker(
                                isActive: index == model.items.count - 1 && insertionIndex == model.items.count
                            )
                        }
                        .onTapGesture {
                            handleTap(on: item)
                        }
                        .onForceClick {
                            model.selection = [item.id]
                            selectionAnchor = item.id
                            model.quickLookURL = item.originalURL
                        }
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded {
                                model.selection = [item.id]
                                selectionAnchor = item.id
                                model.quickLookURL = item.originalURL
                            }
                        )
                        .onDrag {
                            beginDrag(from: item)
                            return NSItemProvider(object: item.id.uuidString as NSString)
                        } preview: {
                            ListDragPreview(item: item, count: draggingIDs.count)
                        }
                        .background {
                            GeometryReader { geometry in
                                Color.clear
                                    .onDrop(
                                        of: Self.reorderTypes,
                                        delegate: ListRowDropDelegate(
                                            index: index,
                                            rowHeight: geometry.size.height,
                                            insertionIndex: $insertionIndex,
                                            isReordering: !draggingIDs.isEmpty,
                                            commit: { target in reorder(to: target) }
                                        )
                                    )
                            }
                        }
                        .listRowBackground(
                            model.selection.contains(item.id)
                                ? Palette.accent.opacity(0.20)
                                : Color.clear
                        )
                        .id(item.id)
                        .contextMenu { rowMenu(for: item) }
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
                .scrollContentBackground(.hidden)
                .workSurface(opacity: 0.95)
                .onDeleteCommand { model.removeSelected() }
                .onKeyPress(.space) {
                    model.quickLookSelection()
                    return .handled
                }
                .onChange(of: model.scrollTick) {
                    guard let target = model.scrollTargetID else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(target)
                    }
                }
            }
        }
    }

    /// List rows use the same explicit selection model as the grid. SwiftUI's
    /// automatic List selection becomes unreliable once a row contains controls,
    /// drag handles, and custom gestures.
    private func handleTap(on item: RenameItem) {
        // A drop outside the list does not call `performDrop`; reset its visual
        // state on the next normal interaction instead of leaving a stale marker.
        draggingIDs = []
        insertionIndex = nil

        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift),
           let anchor = selectionAnchor,
           let anchorIndex = model.index(of: anchor),
           let clickedIndex = model.index(of: item.id) {
            let range = min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)
            let ids = Set(range.map { model.items[$0].id })
            model.selection = modifiers.contains(.command) ? model.selection.union(ids) : ids
        } else if modifiers.contains(.command) {
            if model.selection.contains(item.id) {
                model.selection.remove(item.id)
            } else {
                model.selection.insert(item.id)
            }
            selectionAnchor = item.id
        } else {
            model.selection = [item.id]
            selectionAnchor = item.id
        }
    }

    static let reorderTypes: [UTType] = [.text, .plainText, .utf8PlainText]

    /// Matches Finder: dragging any member of a multi-selection carries the whole
    /// selection; otherwise the dragged row becomes the sole selection.
    private func beginDrag(from item: RenameItem) {
        if model.selection.contains(item.id), model.selection.count > 1 {
            draggingIDs = model.selection
        } else {
            draggingIDs = [item.id]
            model.selection = [item.id]
            selectionAnchor = item.id
        }
    }

    private func reorder(to target: Int) {
        let moving = draggingIDs
        draggingIDs = []
        insertionIndex = nil
        guard !moving.isEmpty else { return }

        withAnimation(.snappy(duration: 0.22)) {
            model.move(ids: moving, toIndex: target)
        }
    }

    /// The metadata column heading doubles as a sort control: clicking it re-sorts by
    /// that field and flips direction, the way a Finder column header does.
    private var header: some View {
        HStack(spacing: 12) {
            Text("#").frame(width: 44, alignment: .trailing)
            Text("").frame(width: 36)
            Text(L10n.string("list.originalName", defaultValue: "Original Name", language: language)).frame(maxWidth: .infinity, alignment: .leading)
            Text("").frame(width: 42)

            Button {
                model.applySort(SortDescriptorOption(
                    field: model.sortOption.field,
                    ascending: !model.sortOption.ascending
                ))
            } label: {
                HStack(spacing: 3) {
                    Text(SortValueFormatter.columnTitle(for: model.sortOption.field, language: language))
                    Image(systemName: model.sortOption.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(L10n.string("list.reverseTheCurrentOrder", defaultValue: "Reverse the current order", language: language))
            .frame(width: 118, alignment: .trailing)

            Image(systemName: "arrow.right").foregroundStyle(.tertiary).frame(width: 16)
            Text(L10n.string("grid.after", defaultValue: "After", language: language)).frame(maxWidth: .infinity, alignment: .leading)
            Spacer().frame(width: 62)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .workSurface(opacity: 0.97)
    }

    @ViewBuilder
    private func rowMenu(for item: RenameItem) -> some View {
        let ids = model.selection.contains(item.id) ? model.selection : [item.id]
        Button(L10n.string("grid.moveEarlier", defaultValue: "Move Earlier", language: language)) { model.shift(ids: ids, by: -1) }
            .disabled(!model.canShift(ids: ids, by: -1))
        Button(L10n.string("grid.moveLater", defaultValue: "Move Later", language: language)) { model.shift(ids: ids, by: 1) }
            .disabled(!model.canShift(ids: ids, by: 1))
        Button(L10n.string("grid.moveToStart", defaultValue: "Move to Start", language: language)) { model.moveToEdge(ids: ids, toStart: true) }
        Button(L10n.string("grid.moveToEnd", defaultValue: "Move to End", language: language)) { model.moveToEdge(ids: ids, toStart: false) }
        if model.similarityBadge(for: item.id) != nil {
            Divider()
            Button(L10n.string("grid.reviewSimilarImages", defaultValue: "Review Similar Images…", language: language)) { model.showSimilarImages(for: item.id) }
        }
        Divider()
        Button(L10n.string("grid.showInFinder", defaultValue: "Show in Finder", language: language)) { model.revealInFinder(ids: ids) }
        Button(L10n.string("grid.quickLook", defaultValue: "Quick Look", language: language)) { model.quickLookURL = item.originalURL }
        Divider()
        Button(L10n.string("grid.moveToTrash", defaultValue: "Move to Trash…", language: language), role: .destructive) {
            model.requestMoveToTrash(ids: ids)
        }
        Divider()
        Button(item.isLocked ? L10n.string("grid.unlockPosition", defaultValue: "Unlock Position", language: language) : L10n.string("grid.lockAtThisPosition", defaultValue: "Lock at This Position", language: language)) { model.toggleLock(ids: ids) }
        Divider()
        Button(L10n.format(
            "list.removeItems",
            defaultValue: "Remove %d Item(s) from List",
            arguments: [ids.count],
            language: language
        )) {
            model.selection = ids
            model.removeSelected()
        }
    }
}

/// A thin, non-interactive gap marker makes it unambiguous whether the rows will
/// land before or after the hovered row.
private struct ListInsertionMarker: View {
    let isActive: Bool

    var body: some View {
        Rectangle()
            .fill(Palette.accent)
            .frame(height: 3)
            .opacity(isActive ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: isActive)
            .allowsHitTesting(false)
    }
}

private struct ListDragPreview: View {
    let item: RenameItem
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            ThumbnailView(url: item.originalURL, size: 44)
            Text(item.displayName)
                .lineLimit(1)
                .frame(maxWidth: 260, alignment: .leading)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if count > 1 {
                Text("\(count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Palette.accent, in: Capsule())
                    .offset(x: 6, y: -6)
            }
        }
    }
}

/// A row is split into an upper and lower half, representing the gaps immediately
/// before and after it. `destinationIndex` remains in pre-move coordinates, exactly
/// matching `ItemSorter.move` and the grid implementation.
private struct ListRowDropDelegate: DropDelegate {
    let index: Int
    let rowHeight: CGFloat
    @Binding var insertionIndex: Int?
    let isReordering: Bool
    let commit: (Int) -> Void

    func validateDrop(info: DropInfo) -> Bool { isReordering }

    func dropEntered(info: DropInfo) {
        insertionIndex = gap(for: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        insertionIndex = gap(for: info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if insertionIndex == index || insertionIndex == index + 1 {
            insertionIndex = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        commit(gap(for: info))
        return true
    }

    private func gap(for info: DropInfo) -> Int {
        info.location.y > rowHeight / 2 ? index + 1 : index
    }
}

struct FileRow: View {
    @Environment(\.locale) private var locale
    private var language: ResolvedAppLanguage { ResolvedAppLanguage(locale: locale) }
    let item: RenameItem
    let preview: RenamePreview?
    var sortField: SortField = .fileName
    var imageChangeSummary: String?
    var similarityBadge: AppModel.SimilarityBadge?
    var onShowSimilarity: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            numberBadge
            ThumbnailView(url: item.originalURL, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let summary = item.groupSummary {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            similarityColumn

            sortValueColumn

            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(preview?.proposedName ?? item.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(nameColor)
                if let imageChangeSummary {
                    Text(imageChangeSummary)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(imageChangeSummary ?? preview?.proposedName ?? item.displayName)

            ValidationBadge(item: item, preview: preview)
        }
        .padding(.vertical, 3)
    }

    /// Marks a row that has a duplicate or near-duplicate elsewhere in the list.
    ///
    /// The slot is always present, empty rows included: a badge that changes the
    /// column widths from row to row would make the whole list harder to scan than
    /// the duplicates are worth.
    private var similarityColumn: some View {
        Group {
            if let similarityBadge {
                Button(action: onShowSimilarity) {
                    Label(
                        "\(similarityBadge.count)",
                        systemImage: similarityBadge.containsExactMatch
                            ? "doc.on.doc.fill"
                            : "square.on.square.intersection.dashed"
                    )
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        similarityBadge.containsExactMatch
                            ? Palette.duplicateExact
                            : Palette.duplicateSimilar,
                        in: Capsule()
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(
                    similarityBadge.containsExactMatch
                        ? L10n.string("list.reviewIdenticalOrSimilarImages", defaultValue: "Review Identical or Similar Images", language: language)
                        : L10n.string("settings.checkForSimilarImages", defaultValue: "Check for similar images", language: language)
                )
                .accessibilityLabel(L10n.format(
                    "similarity.badge.accessibility",
                    defaultValue: "%d similar image(s)",
                    arguments: [similarityBadge.count],
                    language: language
                ))
            } else {
                Color.clear
            }
        }
        .frame(width: 42)
    }

    /// The value the list is currently sorted by. Dimmed dash when the file has none
    /// (a PDF has no capture date) — which is also why such rows sit at the bottom.
    private var sortValueColumn: some View {
        Group {
            if let value = SortValueFormatter.value(for: item, field: sortField) {
                Text(value)
                    .foregroundStyle(.secondary)
            } else {
                Text("—")
                    .foregroundStyle(.quaternary)
                    .help(L10n.format(
                        "sort.valueMissing",
                        defaultValue: "No %@ for this file",
                        arguments: [SortValueFormatter.columnTitle(for: sortField, language: language)],
                        language: language
                    ))
            }
        }
        .font(.system(.caption, design: .monospaced))
        .lineLimit(1)
        .frame(width: 118, alignment: .trailing)
    }

    private var numberBadge: some View {
        HStack(spacing: 4) {
            if item.isLocked {
                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
            }
            Text(numberText)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(width: 44, alignment: .trailing)
    }

    /// Shows the actual counter value when the rule has one, otherwise the row index —
    /// the position is meaningful either way.
    private var numberText: String {
        if let value = preview?.counterValue { return String(value) }
        return String(item.order + 1)
    }

    private var nameColor: Color {
        preview?.validation.isError == true ? Palette.error : .primary
    }
}

/// Status mark for one row. Errors and warnings are clickable: the full reason is
/// often longer than the row, so it lives in a popover instead of being truncated.
struct ValidationBadge: View {
    let item: RenameItem
    let preview: RenamePreview?

    @EnvironmentObject private var preferences: AppPreferences
    @State private var isShowingDetail = false

    var body: some View {
        switch preview?.validation {
        case .error(let message):
            badge(
                systemImage: "exclamationmark.octagon.fill",
                tint: Palette.error,
                message: L10n.string(message, language: preferences.resolvedLanguage)
            )
        case .warning(let message):
            badge(
                systemImage: "exclamationmark.triangle.fill",
                tint: Palette.warning,
                message: L10n.string(message, language: preferences.resolvedLanguage)
            )
        default:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Palette.ok.opacity(0.8))
        }
    }

    private func badge(systemImage: String, tint: Color, message: String) -> some View {
        Button {
            isShowingDetail = true
        } label: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowingDetail, arrowEdge: .leading) {
            ValidationDetail(item: item, preview: preview, message: message, tint: tint)
        }
    }
}

struct ValidationDetail: View {
    @Environment(\.locale) private var locale
    private var language: ResolvedAppLanguage { ResolvedAppLanguage(locale: locale) }
    let item: RenameItem
    let preview: RenamePreview?
    let message: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(.callout.weight(.medium))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text(L10n.string("list.original", defaultValue: "Original", language: language)).foregroundStyle(.secondary)
                    Text(item.displayName).textSelection(.enabled)
                }
                GridRow {
                    Text(L10n.string("grid.after", defaultValue: "After", language: language)).foregroundStyle(.secondary)
                    Text(preview?.proposedName ?? "—").textSelection(.enabled)
                }
                GridRow {
                    Text(L10n.string("list.location", defaultValue: "Location", language: language)).foregroundStyle(.secondary)
                    Text(item.directoryURL.path).textSelection(.enabled)
                }
            }
            .font(.system(.caption, design: .monospaced))

            HStack {
                Spacer()
                Button(L10n.string("grid.showInFinder", defaultValue: "Show in Finder", language: language)) {
                    NSWorkspace.shared.activateFileViewerSelecting([item.originalURL])
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(14)
        .frame(width: 380)
    }
}
