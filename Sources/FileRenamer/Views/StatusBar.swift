import SwiftUI
import RenameKit

/// Bottom bar: what is loaded, what is wrong, and the single destructive action.
struct StatusBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        HStack(spacing: 12) {
            Text(countSummary)
                .font(.callout)
                .foregroundStyle(.secondary)

            if model.errorCount > 0 {
                IssueSummaryButton(
                    title: L10n.format(
                        "status.errorCount",
                        defaultValue: "%lld Errors",
                        arguments: [model.errorCount],
                        language: preferences.resolvedLanguage
                    ),
                    systemImage: "exclamationmark.octagon.fill",
                    tint: Palette.error,
                    issues: model.issues(errorsOnly: true)
                )
            }
            if model.warningCount > 0 {
                IssueSummaryButton(
                    title: L10n.format(
                        "status.warningCount",
                        defaultValue: "%lld Warnings",
                        arguments: [model.warningCount],
                        language: preferences.resolvedLanguage
                    ),
                    systemImage: "exclamationmark.triangle.fill",
                    tint: Palette.warning,
                    issues: model.issues(errorsOnly: false)
                )
            }
            if model.isScanningSimilarImages {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.string("status.checkingSimilarImages", defaultValue: "Checking Similar Images", language: preferences.resolvedLanguage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.duplicateGroupCount > 0 {
                Button {
                    model.showFirstSimilarImageGroup()
                } label: {
                    Label(
                        L10n.format(
                            "status.duplicateGroups",
                            defaultValue: "%lld Duplicate Groups",
                            arguments: [model.duplicateGroupCount],
                            language: preferences.resolvedLanguage
                        ),
                        systemImage: "square.on.square"
                    )
                    .font(.callout)
                    .foregroundStyle(model.hasExactDuplicates
                                     ? Palette.duplicateExact
                                     : Palette.duplicateSimilar)
                }
                .buttonStyle(.plain)
                .help(L10n.string("status.reviewDuplicatesHelp", defaultValue: "Review potentially duplicate images before removing any files.", language: preferences.resolvedLanguage))
            }
            if model.isValidatingDestinations {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.string("status.checkingDestination", defaultValue: "Checking Destination", language: preferences.resolvedLanguage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !model.isEmpty {
                Button(L10n.string("action.clearList", defaultValue: "Clear List", language: preferences.resolvedLanguage)) { model.removeAll() }
                    .buttonStyle(.link)
            }

            if let destinationDirectory = model.renameDestination.directory {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                    Text(destinationDirectory.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        model.useInPlaceRename()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .font(.callout)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.6), in: Capsule())
                .frame(maxWidth: 180)
                .help(destinationDirectory.path)
            }

            // One accent pill: primary rename on the left, destination menu on the
            // right, joined by a thin divider. A custom control, because SwiftUI
            // menus can't draw as a `borderedProminent` segment.
            HStack(spacing: 0) {
                Button {
                    model.rename()
                } label: {
                    Text(renameButtonTitle)
                        .frame(minWidth: 140)
                        .opacity(model.canRename ? 1 : 0.55)
                }
                .buttonStyle(SplitSegmentButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canRename)
                .help(renameButtonHelp)

                Rectangle()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 1, height: 14)

                Menu {
                    destinationMenu
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .tint(.white)
                .disabled(model.isEmpty || model.isBusy)
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(
                Palette.accent.opacity(!model.canRename && (model.isEmpty || model.isBusy) ? 0.55 : 1),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            // Attached outside the white foreground/tint so the tip keeps its own colors.
            .tutorialTip(RenameOrGatherTip(language: preferences.resolvedLanguage), step: 3, arrowEdge: .bottom)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .workSurface(opacity: 0.96)
    }

    private var countSummary: String {
        guard !model.isEmpty else {
            return L10n.string("status.noFiles", defaultValue: "No Files", language: preferences.resolvedLanguage)
        }
        let items = model.items.count
        let files = model.fileCount
        return files == items
            ? L10n.format("status.itemCount", defaultValue: "%lld Items", arguments: [items], language: preferences.resolvedLanguage)
            : L10n.format("status.itemAndFileCount", defaultValue: "%1$lld Items (%2$lld Files)", arguments: [items, files], language: preferences.resolvedLanguage)
    }

    private var renameButtonTitle: String {
        model.renameActionTitle
    }

    private var renameButtonHelp: String {
        if model.errorCount > 0 {
            return L10n.string(
                "status.fixErrorsHelp",
                defaultValue: "Resolve the errors to continue.",
                language: preferences.resolvedLanguage
            )
        }
        if let directory = model.renameDestination.directory {
            return L10n.format(
                "status.moveHelp",
                defaultValue: "Rename the files and move them into “%@”.",
                arguments: [directory.lastPathComponent],
                language: preferences.resolvedLanguage
            )
        }
        return L10n.string(
            "status.renameHelp",
            defaultValue: "Change file names, extensions, and image size.",
            language: preferences.resolvedLanguage
        )
    }

    @ViewBuilder
    private var destinationMenu: some View {
        Button { model.useInPlaceRename() } label: {
            HStack {
                Image(systemName: "checkmark")
                    .opacity(model.renameDestination == .inPlace ? 1 : 0)
                Text(L10n.string(
                    "menu.renameInPlace",
                    defaultValue: "Rename in Place",
                    language: preferences.resolvedLanguage
                ))
            }
        }
        Button { model.chooseExistingDestinationFolder() } label: {
            HStack {
                if case .existingFolder(let url) = model.renameDestination {
                    Image(systemName: "checkmark")
                    Text(L10n.format(
                        "menu.moveToFolder",
                        defaultValue: "Move to “%@”",
                        arguments: [url.lastPathComponent],
                        language: preferences.resolvedLanguage
                    ))
                } else {
                    Image(systemName: "checkmark").opacity(0)
                    Text(L10n.string(
                        "menu.moveToFolderChoose",
                        defaultValue: "Move to Folder…",
                        language: preferences.resolvedLanguage
                    ))
                }
            }
        }
    }
}

/// The left half of the split rename control: plain hit-area over the shared
/// accent background, darkening on press like the prominent button does.
private struct SplitSegmentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .overlay {
                Color.black.opacity(configuration.isPressed ? 0.15 : 0)
            }
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
