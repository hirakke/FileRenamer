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
                Text(L10n.string("confirm.reviewChanges", defaultValue: "Review Changes", language: language))
                    .font(.title2.weight(.semibold))
                Text(L10n.string("confirm.theseChangesWillBeApplied", defaultValue: "These changes will be applied to your files. Please review them before continuing.", language: language))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            summary

            if confirmation.replacesOriginalImages {
                Label(
                    L10n.string("confirm.imageDataWillBeRecreated", defaultValue: "Image data will be recreated and the originals will be replaced.", language: language),
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
                    Text(L10n.string("grid.before", defaultValue: "Before", language: language))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right")
                        .hidden()
                    Text(L10n.string("grid.after", defaultValue: "After", language: language))
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
                Text(L10n.string("confirm.fileNameConflictsAreChecked", defaultValue: "File name conflicts are checked again immediately before running.", language: language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.string("main.cancel", defaultValue: "Cancel", language: language)) { dismiss() }
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
            summaryValue(L10n.string("confirm.scope", defaultValue: "Scope", language: language), value: itemCount(confirmation.changedItemCount))
            Divider().frame(height: 32)
            summaryValue(L10n.string("confirm.rename", defaultValue: "Rename", language: language), value: fileCount(confirmation.renamedFileCount))
            Divider().frame(height: 32)
            summaryValue(L10n.string("settings.imageProcessing", defaultValue: "Image Processing", language: language), value: fileCount(confirmation.processedImageCount))
            if confirmation.warningCount > 0 {
                Divider().frame(height: 32)
                summaryValue(L10n.string("confirm.warnings", defaultValue: "Warnings", language: language), value: itemCount(confirmation.warningCount), tint: Palette.warning)
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

    private func summaryValue(_ title: String, value: String, tint: Color = .primary) -> some View {
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
