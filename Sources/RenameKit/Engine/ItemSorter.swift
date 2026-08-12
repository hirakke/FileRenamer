import Foundation

public enum SortField: String, CaseIterable, Hashable, Sendable, Codable {
    case fileName
    case creationDate
    case modificationDate
    case fileSize
    case captureDate

    public var displayName: String {
        switch self {
        case .fileName: return "元ファイル名"
        case .creationDate: return "作成日時"
        case .modificationDate: return "更新日時"
        case .fileSize: return "ファイルサイズ"
        case .captureDate: return "撮影日時"
        }
    }
}

public struct SortDescriptorOption: Hashable, Sendable, Codable {
    public var field: SortField
    public var ascending: Bool

    public init(field: SortField, ascending: Bool = true) {
        self.field = field
        self.ascending = ascending
    }

    public var displayName: String {
        "\(field.displayName) \(ascending ? "昇順" : "降順")"
    }

    public static let allOptions: [SortDescriptorOption] = SortField.allCases.flatMap {
        [SortDescriptorOption(field: $0, ascending: true), SortDescriptorOption(field: $0, ascending: false)]
    }
}

/// Auto-sort that respects manually pinned rows.
///
/// A locked item keeps its exact index; the unlocked ones are sorted among themselves
/// and poured into the remaining slots. This is also what makes "sort by capture date,
/// then hand-tweak a few" work without the tweaks being lost on the next sort.
public enum ItemSorter {
    public static func sorted(_ items: [RenameItem], by option: SortDescriptorOption) -> [RenameItem] {
        let lockedSlots = items.enumerated().filter { $0.element.isLocked }
        let movable = items.filter { !$0.isLocked }.sorted { compare($0, $1, option: option) }

        guard !lockedSlots.isEmpty else { return reindexed(movable) }

        var result = [RenameItem?](repeating: nil, count: items.count)
        for (index, item) in lockedSlots {
            result[index] = item
        }
        var iterator = movable.makeIterator()
        for index in result.indices where result[index] == nil {
            result[index] = iterator.next()
        }
        return reindexed(result.compactMap { $0 })
    }

    /// Applies a manual drag & drop move and rewrites `order`.
    ///
    /// Same semantics as SwiftUI's `onMove`: `toOffset` is an index in the *pre-move*
    /// array, so it has to be shifted by the number of moved elements before it.
    /// Reimplemented here to keep RenameKit free of SwiftUI.
    public static func move(_ items: [RenameItem], fromOffsets: IndexSet, toOffset: Int) -> [RenameItem] {
        let indices = fromOffsets.filter { items.indices.contains($0) }.sorted()
        guard !indices.isEmpty else { return items }

        let moving = indices.map { items[$0] }
        var result = items
        for index in indices.reversed() {
            result.remove(at: index)
        }
        let removedBefore = indices.filter { $0 < toOffset }.count
        let insertion = min(max(toOffset - removedBefore, 0), result.count)
        result.insert(contentsOf: moving, at: insertion)
        return reindexed(result)
    }

    /// Moves the given items so they land at `destinationIndex` in the current array.
    /// Used by the grid, where a drop targets a cell rather than a gap.
    public static func move(_ items: [RenameItem], ids: Set<UUID>, toIndex destinationIndex: Int) -> [RenameItem] {
        let offsets = IndexSet(items.indices.filter { ids.contains(items[$0].id) })
        guard !offsets.isEmpty else { return items }
        return move(items, fromOffsets: offsets, toOffset: destinationIndex)
    }

    /// Nudges items one step earlier (`delta < 0`) or later (`delta > 0`).
    ///
    /// Backs the per-row ◀ ▶ buttons: precise single-step reordering without a drag.
    /// Items already at the edge stay put instead of the whole selection refusing to
    /// move, and a contiguous selection keeps its internal order and stays contiguous.
    public static func shift(_ items: [RenameItem], ids: Set<UUID>, by delta: Int) -> [RenameItem] {
        guard delta != 0, !ids.isEmpty else { return items }
        var result = items
        let selected = result.indices.filter { ids.contains(result[$0].id) }
        guard !selected.isEmpty else { return items }

        // Walk from the edge we are moving toward, so each item's neighbour has already
        // settled by the time we look at it.
        let ordered = delta < 0 ? selected : selected.reversed()
        let step = delta < 0 ? -1 : 1

        for index in ordered {
            let target = index + step
            guard result.indices.contains(target) else { continue }
            // The neighbour is part of the same selection: it moved with us, so there
            // is nothing to swap past.
            guard !ids.contains(result[target].id) else { continue }
            result.swapAt(index, target)
        }
        return reindexed(result)
    }

    /// Sends items to the very start or end of the list.
    public static func moveToEdge(_ items: [RenameItem], ids: Set<UUID>, toStart: Bool) -> [RenameItem] {
        guard !ids.isEmpty else { return items }
        let offsets = IndexSet(items.indices.filter { ids.contains(items[$0].id) })
        guard !offsets.isEmpty else { return items }
        return move(items, fromOffsets: offsets, toOffset: toStart ? 0 : items.count)
    }

    /// True when nothing in `ids` can move any further in that direction — used to
    /// disable the buttons at the ends of the list.
    public static func canShift(_ items: [RenameItem], ids: Set<UUID>, by delta: Int) -> Bool {
        guard delta != 0, !ids.isEmpty else { return false }
        let selected = items.indices.filter { ids.contains(items[$0].id) }
        guard !selected.isEmpty else { return false }
        return delta < 0 ? (selected.first ?? 0) > 0 : (selected.last ?? 0) < items.count - 1
    }

    /// `order` mirrors the array index. Keep them in sync after every mutation so the
    /// counter, the list and the grid can never disagree.
    public static func reindexed(_ items: [RenameItem]) -> [RenameItem] {
        items.enumerated().map { index, item in
            var item = item
            item.order = index
            return item
        }
    }

    private static func compare(_ lhs: RenameItem, _ rhs: RenameItem, option: SortDescriptorOption) -> Bool {
        let ascending = option.ascending
        switch option.field {
        case .fileName:
            let result = lhs.displayName.localizedStandardCompare(rhs.displayName)
            if result == .orderedSame { return tieBreak(lhs, rhs) }
            return ascending ? result == .orderedAscending : result == .orderedDescending

        case .creationDate:
            return compareOptional(lhs.metadata.creationDate, rhs.metadata.creationDate, lhs, rhs, ascending)

        case .modificationDate:
            return compareOptional(lhs.metadata.modificationDate, rhs.metadata.modificationDate, lhs, rhs, ascending)

        case .captureDate:
            return compareOptional(lhs.date(for: .capture), rhs.date(for: .capture), lhs, rhs, ascending)

        case .fileSize:
            return compareOptional(lhs.metadata.fileSize, rhs.metadata.fileSize, lhs, rhs, ascending)
        }
    }

    /// Items missing the sort key always sink to the bottom, in either direction —
    /// otherwise a few PDFs mixed into a photo set would scatter through the list.
    private static func compareOptional<T: Comparable>(
        _ lhs: T?, _ rhs: T?,
        _ lhsItem: RenameItem, _ rhsItem: RenameItem,
        _ ascending: Bool
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return tieBreak(lhsItem, rhsItem)
        case (nil, _): return false
        case (_, nil): return true
        case (let l?, let r?):
            if l == r { return tieBreak(lhsItem, rhsItem) }
            return ascending ? l < r : l > r
        }
    }

    /// Stable, deterministic fallback so equal keys never produce a random shuffle.
    private static func tieBreak(_ lhs: RenameItem, _ rhs: RenameItem) -> Bool {
        lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }
}
