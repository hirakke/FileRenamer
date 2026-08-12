import SwiftUI
import RenameKit

/// The main "Arrange" surface: rows in list order, each showing the number it will
/// get, the original name and the resulting name. Dragging a row renumbers everything.
struct FileListView: View {
    @EnvironmentObject private var model: AppModel

    private static let viewportSpace = "fileListViewport"
    @State private var rowGeometry = RowGeometryStore()
    @State private var scrollController = ListScrollController()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List(selection: $model.selection) {
                ForEach(model.items) { item in
                    HStack(spacing: 8) {
                        FileRow(item: item, preview: model.preview(for: item), sortField: model.sortOption.field)
                        OrderStepper(id: item.id, axis: .vertical, onStep: step)
                    }
                    .onForceClick {
                        model.selection = [item.id]
                        model.quickLookURL = item.originalURL
                    }
                    .background {
                        RowFrameRecorder(id: item.id, store: rowGeometry, coordinateSpace: Self.viewportSpace)
                        EnclosingScrollViewProbe(controller: scrollController)
                    }
                    .contextMenu { rowMenu(for: item) }
                }
                .onMove { offsets, destination in
                    model.move(fromOffsets: offsets, toOffset: destination)
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
            .scrollContentBackground(.hidden)
            .workSurface(opacity: 0.95)
            .coordinateSpace(.named(Self.viewportSpace))
            .onDeleteCommand { model.removeSelected() }
            .onKeyPress(.space) {
                model.quickLookSelection()
                return .handled
            }
        }
    }

    /// Steps the row and slides the list by exactly the distance the row travelled, so
    /// the row lands back under the pointer and can be clicked again immediately.
    ///
    /// The distance is measured from the current layout *before* the move: stepping
    /// swaps the row with its neighbour, so the row ends up occupying the neighbour's
    /// slot, and the offset is the gap between those two slots.
    private func step(rowID: UUID, delta: Int) {
        let distance = travelDistance(rowID: rowID, delta: delta)
        model.stepFromRow(rowID, by: delta)
        if let distance {
            scrollController.scroll(by: distance)
        }
    }

    private func travelDistance(rowID: UUID, delta: Int) -> CGFloat? {
        let targets = model.stepTargets(for: rowID)
        let indices = model.items.indices.filter { targets.contains(model.items[$0].id) }
        guard let first = indices.first, let last = indices.last else { return nil }
        let frames = rowGeometry.frames

        if delta > 0 {
            let neighbour = last + 1
            guard model.items.indices.contains(neighbour),
                  let moved = frames[model.items[last].id],
                  let target = frames[model.items[neighbour].id]
            else { return nil }
            return target.maxY - moved.maxY
        } else {
            let neighbour = first - 1
            guard model.items.indices.contains(neighbour),
                  let moved = frames[model.items[first].id],
                  let target = frames[model.items[neighbour].id]
            else { return nil }
            return target.minY - moved.minY
        }
    }

    /// The metadata column heading doubles as a sort control: clicking it re-sorts by
    /// that field and flips direction, the way a Finder column header does.
    private var header: some View {
        HStack(spacing: 12) {
            Text("#").frame(width: 44, alignment: .trailing)
            Text("").frame(width: 36)
            Text("元のファイル名").frame(maxWidth: .infinity, alignment: .leading)

            Button {
                model.applySort(SortDescriptorOption(
                    field: model.sortOption.field,
                    ascending: !model.sortOption.ascending
                ))
            } label: {
                HStack(spacing: 3) {
                    Text(SortValueFormatter.columnTitle(for: model.sortOption.field))
                    Image(systemName: model.sortOption.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("並び順を反転します")
            .frame(width: 118, alignment: .trailing)

            Image(systemName: "arrow.right").foregroundStyle(.tertiary).frame(width: 16)
            Text("変更後").frame(maxWidth: .infinity, alignment: .leading)
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
        Button("1つ前へ") { model.shift(ids: ids, by: -1) }
            .disabled(!model.canShift(ids: ids, by: -1))
        Button("1つ後ろへ") { model.shift(ids: ids, by: 1) }
            .disabled(!model.canShift(ids: ids, by: 1))
        Button("先頭へ移動") { model.moveToEdge(ids: ids, toStart: true) }
        Button("末尾へ移動") { model.moveToEdge(ids: ids, toStart: false) }
        Divider()
        Button("Finder で表示") { model.revealInFinder(ids: ids) }
        Button("クイックルック") { model.quickLookURL = item.originalURL }
        Divider()
        Button(item.isLocked ? "位置の固定を解除" : "この位置に固定") { model.toggleLock(ids: ids) }
        Divider()
        Button("リストから除外") {
            model.selection = ids
            model.removeSelected()
        }
    }
}

struct FileRow: View {
    let item: RenameItem
    let preview: RenamePreview?
    var sortField: SortField = .fileName

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

            sortValueColumn

            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 16)

            Text(preview?.proposedName ?? item.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(nameColor)
                .frame(maxWidth: .infinity, alignment: .leading)

            ValidationBadge(item: item, preview: preview)
        }
        .padding(.vertical, 3)
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
                    .help("このファイルには\(SortValueFormatter.columnTitle(for: sortField))がありません")
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

    @State private var isShowingDetail = false

    var body: some View {
        switch preview?.validation {
        case .error(let message):
            badge(systemImage: "exclamationmark.octagon.fill", tint: Palette.error, message: message)
        case .warning(let message):
            badge(systemImage: "exclamationmark.triangle.fill", tint: Palette.warning, message: message)
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
                    Text("元").foregroundStyle(.secondary)
                    Text(item.displayName).textSelection(.enabled)
                }
                GridRow {
                    Text("変更後").foregroundStyle(.secondary)
                    Text(preview?.proposedName ?? "—").textSelection(.enabled)
                }
                GridRow {
                    Text("場所").foregroundStyle(.secondary)
                    Text(item.directoryURL.path).textSelection(.enabled)
                }
            }
            .font(.system(.caption, design: .monospaced))

            HStack {
                Spacer()
                Button("Finder で表示") {
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
