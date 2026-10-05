import SwiftUI
import AppKit
import RenameKit

struct RenameConfirmationView: View {
    @Environment(\.locale) private var locale
    private var language: ResolvedAppLanguage { ResolvedAppLanguage(locale: locale) }
    @Environment(\.dismiss) private var dismiss
    let confirmation: AppModel.RenameConfirmation
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("変更内容を確認")
                    .font(.title2.weight(.semibold))
                Text("次の内容でファイルを変更します。実行前に確認してください。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            summary

            if confirmation.replacesOriginalImages {
                Label(
                    "画像データを再生成し、元画像を置き換えます。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(Palette.warning)
            } else if let directory = confirmation.originalImagesDirectory {
                Label {
                    Text(L10n.format(
                        "confirmation.originalsFolder",
                        defaultValue: "Original images will be saved to “%@”.",
                        arguments: [directory.lastPathComponent],
                        language: language
                    ))
                } icon: {
                    Image(systemName: "folder.badge.plus")
                }
                .font(.callout)
            }

            if let destination = confirmation.destinationDirectory {
                Label {
                    Text(L10n.format(
                        "confirmation.destinationFolder",
                        defaultValue: "Files will be moved to “%@”.",
                        arguments: [destination.lastPathComponent],
                        language: language
                    ))
                } icon: {
                    Image(systemName: "folder")
                }
                .font(.callout)
                .help(destination.path)
            }

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("変更前")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right")
                        .hidden()
                    Text("変更後")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)

                Divider()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(confirmation.rows) { row in
                            confirmationRow(row)
                            if row.id != confirmation.rows.last?.id { Divider() }
                        }
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            }

            HStack {
                Text("実行直前にも保存先の衝突を再確認します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmation.actionTitle) { confirm() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 820, height: 620)
    }

    private var summary: some View {
        HStack(spacing: 0) {
            summaryValue("対象", value: itemCount(confirmation.changedItemCount))
            Divider().frame(height: 32)
            summaryValue("名前変更", value: fileCount(confirmation.renamedFileCount))
            Divider().frame(height: 32)
            summaryValue("画像処理", value: fileCount(confirmation.processedImageCount))
            if confirmation.warningCount > 0 {
                Divider().frame(height: 32)
                summaryValue("警告", value: itemCount(confirmation.warningCount), tint: Palette.warning)
            }
        }
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

    private func itemCount(_ count: Int) -> String {
        L10n.format("count.items", defaultValue: "%d item(s)", arguments: [count], language: language)
    }

    private func fileCount(_ count: Int) -> String {
        L10n.format("count.files", defaultValue: "%d file(s)", arguments: [count], language: language)
    }

    private func summaryValue(_ title: LocalizedStringKey, value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
    }

    private func confirmationRow(_ row: AppModel.RenameConfirmationRow) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                Text(row.sourceName)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: row.changesName ? "arrow.right" : "equal")
                    .foregroundStyle(.tertiary)
                Text(row.destinationName)
                    .foregroundStyle(row.changesName ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(.callout, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)

            HStack(spacing: 8) {
                Text(URL(fileURLWithPath: row.sourceDirectoryPath).lastPathComponent)
                    .help(row.sourceDirectoryPath)
                if let imageChange = row.imageChange {
                    Label(imageChange, systemImage: "photo")
                }
                if let warning = row.warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.warning)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}
