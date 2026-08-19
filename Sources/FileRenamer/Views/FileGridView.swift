import SwiftUI
import UniformTypeIdentifiers
import RenameKit

/// Lightroom-style grid. Same ordering model as the list — dropping a cell onto
/// another cell inserts it there and every number updates.
struct FileGridView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: AppPreferences
    @State private var selectionAnchor: UUID?
    /// Cells currently being dragged, captured when the drag starts so the drop does
    /// not have to decode the payload to know what is moving.
    @State private var draggingIDs: Set<UUID> = []
    /// Gap the drop would land in, as an index into the pre-move array.
    @State private var insertionIndex: Int?
    /// Scrolls the grid while a cell is held near the top or bottom edge.
    @State private var autoScroller = DragAutoScroller()

    private let columnChoices = Array(2...8)
    private let gridSpacing: CGFloat = 16
    private let horizontalPadding: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                GeometryReader { geometry in
                    let layout = gridLayout(for: geometry.size.width)

                    ScrollView {
                        LazyVGrid(columns: layout.columns, spacing: gridSpacing) {
                            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                                GridCell(
                                    item: item,
                                    preview: model.preview(for: item),
                                    size: layout.thumbnailSize,
                                    isSelected: model.selection.contains(item.id),
                                    imageChangeSummary: model.imageChangeSummary(
                                        for: item,
                                        preview: model.preview(for: item)
                                    ),
                                    similarityBadge: model.similarityBadge(for: item.id),
                                    onShowSimilarity: { model.showSimilarImages(for: item.id) }
                                )
                                .opacity(draggingIDs.contains(item.id) ? 0.35 : 1)
                                .overlay(alignment: .leading) {
                                    InsertionCaret(isActive: insertionIndex == index, height: layout.thumbnailSize)
                                        .offset(x: -gridSpacing / 2)
                                }
                                .overlay(alignment: .trailing) {
                                    // Only the last cell owns the gap after it; every
                                    // other gap is drawn by the cell that follows.
                                    InsertionCaret(
                                        isActive: index == model.items.count - 1 && insertionIndex == model.items.count,
                                        height: layout.thumbnailSize
                                    )
                                    .offset(x: gridSpacing / 2)
                                }
                                .onTapGesture { handleTap(on: item) }
                                .simultaneousGesture(
                                    TapGesture(count: 2).onEnded {
                                        model.selection = [item.id]
                                        model.quickLookURL = item.originalURL
                                    }
                                )
                                .onForceClick {
                                    model.selection = [item.id]
                                    model.quickLookURL = item.originalURL
                                }
                                .onDrag {
                                    beginDrag(from: item)
                                    return NSItemProvider(object: item.id.uuidString as NSString)
                                } preview: {
                                    DragPreview(item: item, count: dragCount(startingFrom: item))
                                }
                                .onDrop(
                                    of: Self.reorderTypes,
                                    delegate: CellDropDelegate(
                                        index: index,
                                        cellWidth: layout.cellWidth,
                                        insertionIndex: $insertionIndex,
                                        isReordering: !draggingIDs.isEmpty,
                                        commit: { target in reorder(to: target) }
                                    )
                                )
                                .background {
                                    EnclosingScrollViewProbe(controller: autoScroller.controller)
                                }
                                .id(item.id)
                                .contextMenu { cellMenu(for: item) }
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("\(item.displayName)、\(index + 1)番目")
                                .accessibilityValue(model.preview(for: item)?.proposedName ?? item.displayName)
                                .accessibilityHint("クリックして選択。ダブルクリックまたはスペースキーでプレビュー")
                            }
                        }
                        .padding(horizontalPadding)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
                        // Empty space under the grid means "put it last".
                        .onDrop(
                            of: Self.reorderTypes,
                            delegate: CellDropDelegate(
                                index: model.items.count,
                                cellWidth: 0,
                                insertionIndex: $insertionIndex,
                                isReordering: !draggingIDs.isEmpty,
                                commit: { target in reorder(to: target) }
                            )
                        )
                    }
                    .background(Color(nsColor: .controlBackgroundColor))
                    .onKeyPress(.space) {
                        model.quickLookSelection()
                        return .handled
                    }
                    .onDeleteCommand { model.removeSelected() }
                    .onAppear {
                        autoScroller.onDragEnded = {
                            // The drop, if there was one, clears this first; the delay
                            // keeps the two from racing on mouse-up.
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(250))
                                draggingIDs = []
                                insertionIndex = nil
                            }
                        }
                    }
                    // Scrolls along with the cell being stepped, same as the list.
                    .onChange(of: model.scrollTick) {
                        guard let target = model.scrollTargetID else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(target)
                        }
                    }
                }
            }

            Divider()
            columnCountControl
        }
        .workSurface(opacity: 0.90)
    }

    private var columnCountControl: some View {
        HStack(spacing: 10) {
            Spacer()

            Text("横の列数")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 1) {
                Slider(
                    value: columnSliderValue,
                    in: Double(columnChoices.first ?? 3)...Double(columnChoices.last ?? 8),
                    step: 1
                )
                .accessibilityLabel("横の列数")
                .accessibilityValue("\(preferences.gridColumnCount)列")

                HStack(spacing: 0) {
                    ForEach(columnChoices, id: \.self) { count in
                        Text("\(count)")
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(count == preferences.gridColumnCount ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(width: 210)

            Text("\(preferences.gridColumnCount)列")
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .frame(width: 30, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .workSurface(opacity: 0.96)
    }

    /// The system slider supplies pointer and keyboard behavior, while this binding
    /// guarantees that layout state can only ever be one of the six integer steps.
    private var columnSliderValue: Binding<Double> {
        Binding(
            get: { Double(preferences.gridColumnCount) },
            set: { newValue in
                let lower = columnChoices.first ?? 3
                let upper = columnChoices.last ?? 8
                preferences.gridColumnCount = min(max(Int(newValue.rounded()), lower), upper)
            }
        )
    }

    /// A selected column count is invariant. Resizing the window only redistributes
    /// the available width and never crosses an adaptive-grid threshold.
    private func gridLayout(for containerWidth: CGFloat) -> GridLayoutMetrics {
        let count = min(
            max(preferences.gridColumnCount, columnChoices.first ?? 2),
            columnChoices.last ?? 8
        )
        let contentWidth = max(1, containerWidth - horizontalPadding * 2)
        let totalSpacing = gridSpacing * CGFloat(count - 1)
        let cellWidth = max(48, floor((contentWidth - totalSpacing) / CGFloat(count)))
        let thumbnailSize = max(24, cellWidth - 24)
        let columns = Array(
            repeating: GridItem(.fixed(cellWidth), spacing: gridSpacing, alignment: .top),
            count: count
        )
        return GridLayoutMetrics(columns: columns, thumbnailSize: thumbnailSize, cellWidth: cellWidth)
    }

    private func handleTap(on item: RenameItem) {
        // A drag that ended outside the window leaves no callback behind; the next
        // click is a good moment to drop the leftover state.
        autoScroller.stop()
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

    /// Dragging a cell that is part of the selection moves the whole selection, the
    /// way Finder does; dragging an unselected cell picks that one up on its own.
    private func beginDrag(from item: RenameItem) {
        if model.selection.contains(item.id), model.selection.count > 1 {
            draggingIDs = model.selection
        } else {
            draggingIDs = [item.id]
            model.selection = [item.id]
            selectionAnchor = item.id
        }
        autoScroller.start()
    }

    private func dragCount(startingFrom item: RenameItem) -> Int {
        model.selection.contains(item.id) ? max(model.selection.count, 1) : 1
    }

    /// `target` is a gap index in the pre-move array — the same convention `onMove`
    /// uses, so it can be handed straight to the shared ordering code.
    private func reorder(to target: Int) {
        autoScroller.stop()
        let moving = draggingIDs
        draggingIDs = []
        insertionIndex = nil
        guard !moving.isEmpty else { return }
        withAnimation(.snappy(duration: 0.22)) {
            model.move(ids: moving, toIndex: target)
        }
    }

    @ViewBuilder
    private func cellMenu(for item: RenameItem) -> some View {
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
        if model.similarityBadge(for: item.id) != nil {
            Button("類似候補を比較") { model.showSimilarImages(for: item.id) }
        }
        Divider()
        Button(item.isLocked ? "位置の固定を解除" : "この位置に固定") { model.toggleLock(ids: ids) }
        Divider()
        Button("リストから除外") {
            model.selection = ids
            model.removeSelected()
        }
    }
}

private struct GridLayoutMetrics {
    let columns: [GridItem]
    let thumbnailSize: CGFloat
    let cellWidth: CGFloat
}

/// The bar that shows where a dragged cell will land.
private struct InsertionCaret: View {
    let isActive: Bool
    let height: CGFloat

    var body: some View {
        Capsule()
            .fill(Palette.accent)
            .frame(width: 3, height: height)
            .opacity(isActive ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: isActive)
            .allowsHitTesting(false)
    }
}

/// What follows the pointer during a drag.
private struct DragPreview: View {
    let item: RenameItem
    let count: Int

    var body: some View {
        ThumbnailView(url: item.originalURL, size: 80)
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

/// Tracks the pointer across a cell so the drop lands in the nearer gap: left half
/// inserts before the cell, right half after it. Without this a drop could only ever
/// mean "before", and dragging one cell to the right by a single position would do
/// nothing at all.
private struct CellDropDelegate: DropDelegate {
    let index: Int
    let cellWidth: CGFloat
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
        guard cellWidth > 0 else { return index }
        return info.location.x > cellWidth / 2 ? index + 1 : index
    }
}

private struct GridCell: View {
    let item: RenameItem
    let preview: RenamePreview?
    let size: Double
    let isSelected: Bool
    let imageChangeSummary: String?
    let similarityBadge: AppModel.SimilarityBadge?
    let onShowSimilarity: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 2) {
                OrderStepButton(id: item.id, delta: -1, axis: .horizontal)
                if item.isLocked {
                    Image(systemName: "lock.fill").font(.caption2)
                }
                Text(numberText)
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                    .frame(minWidth: 30)
                OrderStepButton(id: item.id, delta: 1, axis: .horizontal)
            }
            .foregroundStyle(isSelected ? Color.white : Color.secondary)

            ZStack(alignment: .bottomTrailing) {
                ThumbnailView(url: item.originalURL, size: size)

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
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Palette.warning, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .help(
                        similarityBadge.containsExactMatch
                            ? "同一または類似している画像を比較"
                            : "類似している可能性のある画像を比較"
                    )
                    .accessibilityLabel("\(similarityBadge.count)件の類似画像候補")
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                nameSectionLabel("変更前", emphasized: false)
                Text(item.displayName)
                    .font(.caption2)
                    .foregroundStyle(originalNameColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.displayName)

                Divider()
                    .opacity(isSelected ? 0.38 : 0.55)

                nameSectionLabel(isUnchanged ? "変更後（変更なし）" : "変更後", emphasized: true)
                Text(proposedName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(nameColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(proposedName)

                if let imageChangeSummary {
                    Text(imageChangeSummary)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.76) : Color.secondary)
                        .lineLimit(1)
                        .help(imageChangeSummary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(width: size + 24)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Palette.accent)
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.93))
            }
        }
        .overlay {
            if !isSelected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.32), lineWidth: 0.7)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let validation = preview?.validation,
               validation.isError || validation.isWarning {
                Image(systemName: validation.isError
                      ? "exclamationmark.octagon.fill"
                      : "exclamationmark.triangle.fill")
                    .foregroundStyle(validation.isError ? Palette.error : Palette.warning)
                    .padding(6)
                    .help(validation.message ?? "名前を確認してください")
                    .accessibilityLabel(validation.message ?? "名前の問題")
            }
        }
    }

    private var numberText: String {
        if let value = preview?.counterValue { return String(value) }
        return String(item.order + 1)
    }

    private var nameColor: Color {
        if preview?.validation.isError == true { return Palette.error }
        return isSelected ? .white : Palette.accent
    }

    private var originalNameColor: Color {
        isSelected ? Color.white.opacity(0.76) : Color.secondary
    }

    private var proposedName: String {
        preview?.proposedName ?? item.displayName
    }

    private var isUnchanged: Bool {
        proposedName == item.displayName
    }

    private func nameSectionLabel(_ title: String, emphasized: Bool) -> some View {
        Text(title)
            .font(.system(size: 9, weight: emphasized ? .semibold : .medium))
            .foregroundStyle(
                isSelected
                    ? Color.white.opacity(emphasized ? 1 : 0.72)
                    : (emphasized ? Palette.accent : Color.secondary)
            )
            .lineLimit(1)
    }
}
