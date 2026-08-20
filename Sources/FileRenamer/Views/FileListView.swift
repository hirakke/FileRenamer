import SwiftUI
import RenameKit

/// The main "Arrange" surface: rows in list order, each showing the number it will
/// get, the original name and the resulting name. Dragging a row renumbers everything.
struct FileListView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                List(selection: $model.selection) {
                    ForEach(model.items) { item in
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
                        .onForceClick {
                            model.selection = [item.id]
                            model.quickLookURL = item.originalURL
                        }
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded {
                                model.selection = [item.id]
                                model.quickLookURL = item.originalURL
                            }
                        )
                        .id(item.id)
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

    /// The metadata column heading doubles as a sort control: clicking it re-sorts by
    /// that field and flips direction, the way a Finder column header does.
    private var header: some View {
        HStack(spacing: 12) {
            Text("#").frame(width: 44, alignment: .trailing)
            Text("").frame(width: 36)
            Text("元のファイル名").frame(maxWidth: .infinity, alignment: .leading)
            Text("").frame(width: 42)

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
        if model.similarityBadge(for: item.id) != nil {
            Divider()
            Button("重複候補を確認…") { model.showSimilarImages(for: item.id) }
        }
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
                        ? "同一または類似している画像を確認"
                        : "類似している可能性のある画像を確認"
                )
                .accessibilityLabel("\(similarityBadge.count)件の重複候補")
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
