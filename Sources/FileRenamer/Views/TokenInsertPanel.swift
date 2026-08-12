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
    /// Inserts at the caret — the panel does not know or care where that is.
    let insert: (RenameToken) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            InsertRow(title: "元の名前", options: Self.originalNameOptions, insert: insert)
            Divider()
            InsertRow(title: "連番と日付", options: Self.counterAndDateOptions, insert: insert)
            Divider()
            InsertRow(title: "写真情報", options: Self.metadataOptions, insert: insert)
            Divider()
            InsertRow(title: "区切り", options: Self.separatorOptions, insert: insert)
        }
    }

    // MARK: - Catalogue

    static let originalNameOptions: [InsertOption] = [
        InsertOption("元のファイル名") { .originalName(OriginalNameConfiguration()) },
        InsertOption("元のファイル名（小文字）") { .originalName(OriginalNameConfiguration(transform: .lowercase)) },
        InsertOption("元のファイル名（大文字）") { .originalName(OriginalNameConfiguration(transform: .uppercase)) }
    ]

    static let counterAndDateOptions: [InsertOption] = [
        InsertOption("連番 (001)") { .counter(CounterConfiguration(start: 1, digits: 3)) },
        InsertOption("連番 (0001)") { .counter(CounterConfiguration(start: 1, digits: 4)) },
        InsertOption("連番 (01)") { .counter(CounterConfiguration(start: 1, digits: 2)) },
        InsertOption("撮影日 (YYYYMMDD)") { .date(DateConfiguration(source: .capture, preset: .compact)) },
        InsertOption("撮影日 (YYYY-MM-DD)") { .date(DateConfiguration(source: .capture, preset: .dashed)) },
        InsertOption("撮影日時 (YYYYMMDD_HHMMSS)") { .date(DateConfiguration(source: .capture, preset: .compactWithTime)) },
        InsertOption("作成日 (YYYYMMDD)") { .date(DateConfiguration(source: .creation, preset: .compact)) },
        InsertOption("更新日 (YYYYMMDD)") { .date(DateConfiguration(source: .modification, preset: .compact)) }
    ]

    static let metadataOptions: [InsertOption] = MetadataField.allCases.map { field in
        InsertOption(field.displayName) { .metadata(MetadataConfiguration(field: field)) }
    }

    // Separators are ordinary characters once the field is typeable; these are just
    // shortcuts for the common ones.
    static let separatorOptions: [InsertOption] = [
        InsertOption("アンダースコア  _") { .text(TextConfiguration(value: "_")) },
        InsertOption("ハイフン  -") { .text(TextConfiguration(value: "-")) },
        InsertOption("ドット  .") { .text(TextConfiguration(value: ".")) },
        InsertOption("スペース") { .text(TextConfiguration(value: " ")) }
    ]
}

struct InsertOption {
    let title: String
    let make: () -> RenameToken

    init(_ title: String, make: @escaping () -> RenameToken) {
        self.title = title
        self.make = make
    }
}

private struct InsertRow: View {
    let title: String
    let options: [InsertOption]
    let insert: (RenameToken) -> Void

    @State private var selection = 0

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)

            Picker("", selection: $selection) {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index].title).tag(index)
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
