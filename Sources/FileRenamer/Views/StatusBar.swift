import SwiftUI
import RenameKit

/// Bottom bar: what is loaded, what is wrong, and the single destructive action.
struct StatusBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Text(countSummary)
                .font(.callout)
                .foregroundStyle(.secondary)

            if model.errorCount > 0 {
                IssueSummaryButton(
                    title: "\(model.errorCount) 件のエラー",
                    systemImage: "exclamationmark.octagon.fill",
                    tint: Palette.error,
                    issues: model.issues(errorsOnly: true)
                )
            }
            if model.warningCount > 0 {
                IssueSummaryButton(
                    title: "\(model.warningCount) 件の警告",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: Palette.warning,
                    issues: model.issues(errorsOnly: false)
                )
            }
            if model.isValidatingDestinations {
                ProgressView()
                    .controlSize(.small)
                Text("保存先を確認中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !model.isEmpty {
                Button("リストを空にする") { model.removeAll() }
                    .buttonStyle(.link)
            }

            Button {
                model.rename()
            } label: {
                Text(renameButtonTitle)
                    .frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canRename)
            .help(model.errorCount > 0 ? "エラーを解消すると実行できます" : "変更後の名前でリネームします")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .workSurface(opacity: 0.96)
    }

    private var countSummary: String {
        guard !model.isEmpty else { return "ファイルなし" }
        let items = model.items.count
        let files = model.fileCount
        return files == items ? "\(items) 件" : "\(items) 件（\(files) ファイル）"
    }

    private var renameButtonTitle: String {
        model.changedCount > 0 ? "\(model.changedCount) 件をリネーム" : "リネーム"
    }
}

/// Opens the list of files that are blocking the rename. Clicking one selects it in
/// the main list, so a long batch can be worked through without hunting.
private struct IssueSummaryButton: View {
    @EnvironmentObject private var model: AppModel

    let title: String
    let systemImage: String
    let tint: Color
    let issues: [AppModel.Issue]

    @State private var isShowing = false

    var body: some View {
        Button {
            isShowing = true
        } label: {
            Label(title, systemImage: systemImage)
                .font(.callout)
                .foregroundStyle(tint)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowing, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(issues) { issue in
                    Button {
                        model.revealIssue(issue.id)
                        isShowing = false
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.name)
                                .font(.system(.callout, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(issue.message)
                                .font(.caption)
                                .foregroundStyle(issue.isError ? Palette.error : Palette.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
            .frame(width: 420)
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
