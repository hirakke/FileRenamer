import SwiftUI
import AppKit
import RenameKit

struct WorkspaceSidebar: View {
    @Environment(\.locale) private var locale
    private var language: ResolvedAppLanguage { ResolvedAppLanguage(locale: locale) }
    @EnvironmentObject private var workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("FileRenamer")
                    .font(.headline.weight(.semibold))

                Spacer()

                Button {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                        workspace.addTab()
                    }
                } label: {
                    Text("＋")
                        .font(.system(size: 15, weight: .regular))
                        .frame(width: 25, height: 25)
                }
                .buttonStyle(.plain)
                .help("新しい命名作業を追加（⌘T）")
                .accessibilityLabel("新しい命名作業を追加")
            }
            .padding(.leading, 13)
            .padding(.trailing, 9)
            .frame(height: 43)

            Color.primary.opacity(0.08)
                .frame(height: 1)

            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    ForEach(workspace.tabs) { tab in
                        WorkspaceSidebarRow(tab: tab, model: tab.model)
                    }
                }
                .padding(7)
            }
            .scrollIndicators(.hidden)

            HStack {
                Text(L10n.format(
                    "sidebar.tabCount",
                    defaultValue: "%d tab(s)",
                    arguments: [workspace.tabs.count],
                    language: ResolvedAppLanguage(locale: locale)
                ))
                Spacer()
                Text("⌘Tで追加")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Color.primary.opacity(0.025))
        }
        .background(Color.clear)
    }
}

private struct WorkspaceSidebarRow: View {
    @Environment(\.locale) private var locale
    private var language: ResolvedAppLanguage { ResolvedAppLanguage(locale: locale) }
    @EnvironmentObject private var workspace: WorkspaceModel
    let tab: WorkspaceModel.Tab
    @ObservedObject var model: AppModel
    @State private var isHovering = false

    private var isSelected: Bool { workspace.selectedTabID == tab.id }
    private var showsActions: Bool { isSelected || isHovering }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.14)) {
                    workspace.selectTab(tab.id)
                }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(workspace.title(for: tab))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(model.items.isEmpty
                         ? L10n.string("ファイル未追加", defaultValue: "No Files Added", language: language)
                         : L10n.format("count.files", defaultValue: "%d file(s)", arguments: [model.fileCount], language: language))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if workspace.tabs.count > 1 {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        workspace.closeTab(tab.id)
                    }
                } label: {
                    Text("×")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 15, height: 15)
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
                .help(model.isBusy ? "処理中のタブは閉じられません" : "タブを閉じる")
                .opacity(showsActions ? 1 : 0)
                .allowsHitTesting(showsActions && !model.isBusy)
            }
        }
        .font(.callout.weight(isSelected ? .semibold : .regular))
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Palette.accent.opacity(0.12))
            } else if isHovering {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .opacity(isSelected ? 1 : 0.88)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .contextMenu {
            ForEach(model.importedDirectories, id: \.path) { directory in
                Button(L10n.format(
                    "finder.openFolder",
                    defaultValue: "Open %@ in Finder",
                    arguments: [directory.lastPathComponent],
                    language: language
                )) {
                    model.openDirectoryInFinder(directory)
                }
            }
            if !model.importedDirectories.isEmpty { Divider() }
            Button("タブを閉じる", role: .destructive) {
                workspace.closeTab(tab.id)
            }
            .disabled(workspace.tabs.count == 1 || model.isBusy)
        }
    }
}
