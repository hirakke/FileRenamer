import SwiftUI
import RenameKit

/// Categorised insert rows under the rule field.
///
/// Lightroom's editor groups the things you can insert (image name / numbering and
/// date / metadata / custom) and gives each a popup plus an Insert button. That
/// structure is worth keeping: it turns "what can I even put in a file name?" into a
/// short menu instead of documentation. The categories here are ours, matching the
/// blocks this app actually has.
struct TokenInsertPanel: View {
    @EnvironmentObject private var preferences: AppPreferences
    /// Inserts at the caret — the panel does not know or care where that is.
    let insert: (RenameToken) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            InsertRow(title: "元の名前", englishTitle: "Original Name", options: Self.originalNameOptions, insert: insert)
            Divider()
            InsertRow(title: "連番と日付", englishTitle: "Counter and Date", options: Self.counterAndDateOptions, insert: insert)
            Divider()
            InsertRow(title: "写真情報", englishTitle: "Photo Info", options: Self.metadataOptions, insert: insert)
            Divider()
            InsertRow(title: "区切り", englishTitle: "Separators", options: Self.separatorOptions, insert: insert)
        }
    }

    // MARK: - Catalogue

    static let originalNameOptions: [InsertOption] = [
        InsertOption("元のファイル名", englishTitle: "Original File Name") { .originalName(OriginalNameConfiguration()) },
        InsertOption("元のファイル名（小文字）", englishTitle: "Original File Name (Lowercase)") { .originalName(OriginalNameConfiguration(transform: .lowercase)) },
        InsertOption("元のファイル名（大文字）", englishTitle: "Original File Name (Uppercase)") { .originalName(OriginalNameConfiguration(transform: .uppercase)) }
    ]

    static let counterAndDateOptions: [InsertOption] = [
        InsertOption("連番 (001)", englishTitle: "Counter (001)") { .counter(CounterConfiguration(start: 1, digits: 3)) },
        InsertOption("連番 (0001)", englishTitle: "Counter (0001)") { .counter(CounterConfiguration(start: 1, digits: 4)) },
        InsertOption("連番 (01)", englishTitle: "Counter (01)") { .counter(CounterConfiguration(start: 1, digits: 2)) },
        InsertOption("撮影日 (YYYYMMDD)", englishTitle: "Date Taken (YYYYMMDD)") { .date(DateConfiguration(source: .capture, preset: .compact)) },
        InsertOption("撮影日 (YYYY-MM-DD)", englishTitle: "Date Taken (YYYY-MM-DD)") { .date(DateConfiguration(source: .capture, preset: .dashed)) },
        InsertOption("撮影日時 (YYYYMMDD_HHMMSS)", englishTitle: "Date Taken (YYYYMMDD_HHMMSS)") { .date(DateConfiguration(source: .capture, preset: .compactWithTime)) },
        InsertOption("作成日 (YYYYMMDD)", englishTitle: "Date Created (YYYYMMDD)") { .date(DateConfiguration(source: .creation, preset: .compact)) },
        InsertOption("更新日 (YYYYMMDD)", englishTitle: "Date Modified (YYYYMMDD)") { .date(DateConfiguration(source: .modification, preset: .compact)) }
    ]

    static let metadataOptions: [InsertOption] = MetadataField.allCases.map { field in
        InsertOption(field.displayName, englishTitle: field.localizedDisplayName(in: .english)) { .metadata(MetadataConfiguration(field: field)) }
    }

    // Separators are ordinary characters once the field is typeable; these are just
    // shortcuts for the common ones.
    static let separatorOptions: [InsertOption] = [
        InsertOption("アンダースコア  _", englishTitle: "Underscore  _") { .text(TextConfiguration(value: "_")) },
        InsertOption("ハイフン  -", englishTitle: "Hyphen  -") { .text(TextConfiguration(value: "-")) },
        InsertOption("ドット  .", englishTitle: "Period  .") { .text(TextConfiguration(value: ".")) },
        InsertOption("スペース", englishTitle: "Space") { .text(TextConfiguration(value: " ")) }
    ]
}

struct InsertOption {
    let japaneseTitle: String
    let englishTitle: String
    let make: () -> RenameToken

    init(_ japaneseTitle: String, englishTitle: String, make: @escaping () -> RenameToken) {
        self.japaneseTitle = japaneseTitle
        self.englishTitle = englishTitle
        self.make = make
    }

    func title(in language: ResolvedAppLanguage) -> String {
        L10n.string(japaneseTitle, defaultValue: englishTitle, language: language)
    }
}

private struct InsertRow: View {
    @EnvironmentObject private var preferences: AppPreferences
    let title: String
    let englishTitle: String
    let options: [InsertOption]
    let insert: (RenameToken) -> Void

    @State private var selection = 0

    var body: some View {
        HStack(spacing: 10) {
            Text(L10n.string(title, defaultValue: englishTitle, language: preferences.resolvedLanguage))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)

            Picker("", selection: $selection) {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index].title(in: preferences.resolvedLanguage)).tag(index)
                }
            }
            .labelsHidden()

            Button("挿入") {
                guard options.indices.contains(selection) else { return }
                insert(options[selection].make())
            }
        }
    }
}
