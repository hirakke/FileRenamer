import Foundation
import RenameKit

/// Renders the value a row is currently being sorted by, so the list shows the
/// evidence behind the order instead of asking the user to trust it.
enum SortValueFormatter {
    /// Column heading for the current sort field.
    static func columnTitle(for field: SortField, language: ResolvedAppLanguage) -> String {
        switch field {
        // Sorting by name needs no extra column, so the slot shows the modification
        // date — the most generally useful fallback.
        case .fileName: return L10n.string("更新日時", defaultValue: "Date Modified", language: language)
        case .creationDate: return L10n.string("作成日時", defaultValue: "Date Created", language: language)
        case .modificationDate: return L10n.string("更新日時", defaultValue: "Date Modified", language: language)
        case .captureDate: return L10n.string("撮影日時", defaultValue: "Date Taken", language: language)
        case .fileSize: return L10n.string("サイズ", defaultValue: "Size", language: language)
        }
    }

    /// `nil` when the item has no value for that field — those rows sink to the
    /// bottom on sort, and the column shows a dash to explain why.
    static func value(for item: RenameItem, field: SortField) -> String? {
        switch field {
        case .fileName, .modificationDate:
            return item.metadata.modificationDate.map(format)
        case .creationDate:
            return item.metadata.creationDate.map(format)
        case .captureDate:
            return item.metadata.captureDate.map(format)
        case .fileSize:
            return item.metadata.fileSize.map(formatBytes)
        }
    }

    /// True when the value shown is the real capture date rather than a fallback —
    /// lets the row flag "this file has no EXIF".
    static func isMissing(_ item: RenameItem, field: SortField) -> Bool {
        value(for: item, field: field) == nil
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter
    }()

    private static func format(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }
}
