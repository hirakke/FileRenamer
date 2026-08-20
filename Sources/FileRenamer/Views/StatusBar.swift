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
            if model.isScanningSimilarImages {
                ProgressView()
                    .controlSize(.small)
                Text("類似画像を確認中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.duplicateGroupCount > 0 {
                Button {
                    model.showFirstSimilarImageGroup()
                } label: {
                    Label(
                        "\(model.duplicateGroupCount) 組の重複候補",
                        systemImage: "square.on.square"
                    )
                    .font(.callout)
                    .foregroundStyle(model.hasExactDuplicates
                                     ? Palette.duplicateExact
                                     : Palette.duplicateSimilar)
                }
                .buttonStyle(.plain)
                .help("重複している可能性のある画像を確認して削除します")
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
            .help(model.errorCount > 0 ? "エラーを解消すると実行できます" : "名前・拡張子・画像サイズの変更を実行します")
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
        model.changedCount > 0 ? "\(model.changedCount) 件を変更" : "変更を実行"
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
    @State private var contentHeight: CGFloat = 0

    private static let maximumPopoverHeight: CGFloat = 360

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
            // A long batch can produce far more issues than fit on screen. The list
            // scrolls, and the popover is only as tall as it needs to be: measuring
            // the content keeps a two-item list from opening at full height.
            ScrollView {
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
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { contentHeight = geometry.size.height }
                            .onChange(of: geometry.size.height) { _, height in contentHeight = height }
                    }
                }
            }
            .frame(width: 420, height: min(max(contentHeight, 44), Self.maximumPopoverHeight))
        }
    }
}
