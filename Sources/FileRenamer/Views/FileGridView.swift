import SwiftUI
import RenameKit

/// Lightroom-style grid. Same ordering model as the list — dropping a cell onto
/// another cell inserts it there and every number updates.
struct FileGridView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draggingID: UUID?
    @State private var thumbnailSize: Double = 140
    @State private var selectionAnchor: UUID?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: thumbnailSize, maximum: thumbnailSize * 1.6), spacing: 16)]
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        GridCell(
                            item: item,
                            preview: model.preview(for: item),
                            size: thumbnailSize,
                            isSelected: model.selection.contains(item.id)
                        )
                        .onTapGesture { handleTap(on: item) }
                        .onForceClick {
                            model.selection = [item.id]
                            model.quickLookURL = item.originalURL
                        }
                        .draggable(item.id.uuidString) {
                            // Drag preview.
                            ThumbnailView(url: item.originalURL, size: 80)
                        }
                        .dropDestination(for: String.self) { payload, _ in
                            handleDrop(payload, at: index)
                        }
                        .id(item.id)
                        .contextMenu { cellMenu(for: item) }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(item.displayName)、\(index + 1)番目")
                        .accessibilityValue(model.preview(for: item)?.proposedName ?? item.displayName)
                        .accessibilityHint("クリックして選択。スペースキーでクイックルック")
                    }
                }
                .padding(16)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .onKeyPress(.space) {
                model.quickLookSelection()
                return .handled
            }
            .onDeleteCommand { model.removeSelected() }
            // Scrolls along with the cell being stepped, same as the list.
            .onChange(of: model.scrollTick) {
                guard let target = model.scrollTargetID else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(target)
                }
            }
            }

            Divider()
            sizeSlider
        }
        .workSurface(opacity: 0.90)
    }

    private var sizeSlider: some View {
        HStack {
            Spacer()
            Image(systemName: "photo").font(.caption2).foregroundStyle(.secondary)
            Slider(value: $thumbnailSize, in: 90...260).frame(width: 140)
            Image(systemName: "photo.fill").foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .workSurface(opacity: 0.96)
    }

    private func handleTap(on item: RenameItem) {
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

    /// The payload is a UUID string. Anything already selected travels with it, so a
    /// multi-selection can be moved in one drag.
    private func handleDrop(_ payload: [String], at index: Int) -> Bool {
        let dropped = Set(payload.compactMap(UUID.init(uuidString:)))
        guard !dropped.isEmpty else { return false }
        let moving = dropped.isSubset(of: model.selection) && model.selection.count > 1
            ? model.selection
            : dropped
        model.move(ids: moving, toIndex: index)
        return true
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
        Divider()
        Button(item.isLocked ? "位置の固定を解除" : "この位置に固定") { model.toggleLock(ids: ids) }
        Divider()
        Button("リストから除外") {
            model.selection = ids
            model.removeSelected()
        }
    }
}

private struct GridCell: View {
    let item: RenameItem
    let preview: RenamePreview?
    let size: Double
    let isSelected: Bool

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

            ThumbnailView(url: item.originalURL, size: size)

            VStack(spacing: 2) {
                Text(item.displayName)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(preview?.proposedName ?? item.displayName)
                    .font(.caption)
                    .foregroundStyle(nameColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
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
        return isSelected ? .white : .primary
    }
}
