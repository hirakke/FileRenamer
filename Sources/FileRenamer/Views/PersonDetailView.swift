import AppKit
import RenameKit
import SwiftUI

struct PersonDetailView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: AppPreferences
    @ObservedObject var workspace: PeopleWorkspaceModel
    let route: PeopleRoute

    @State private var selectionAnchor: UUID?
    @State private var asksForSplitName = false
    @State private var asksForGroupName = false
    @State private var draftName = ""
    @State private var pendingSplitFaceIDs = Set<FaceDescriptorID>()

    private let spacing: CGFloat = 16
    private let horizontalPadding: CGFloat = 16

    private var group: PeopleGroupProjection? {
        guard case let .group(groupID) = route else { return nil }
        return workspace.group(groupID)
    }

    private var sourcePersonID: UUID? {
        guard case let .person(personID) = group?.id else { return nil }
        return personID
    }

    private var displayedFaceIDs: [FaceDescriptorID] {
        switch route {
        case let .group(groupID): workspace.group(groupID)?.faceIDs ?? []
        case .unconfirmed: workspace.projection.unconfirmed.map(\.faceID)
        case .overview: []
        }
    }

    private var displayedItemIDs: [UUID] {
        let included = Set(displayedFaceIDs.map(\.itemID))
        return model.items.compactMap { included.contains($0.id) ? $0.id : nil }
    }

    private var displayedItems: [RenameItem] {
        let included = Set(displayedItemIDs)
        return model.items.filter { included.contains($0.id) }
    }

    private var selectedFaceIDs: Set<FaceDescriptorID> {
        let selectedItems = model.selection.intersection(Set(displayedItemIDs))
        return Set(displayedFaceIDs.filter { selectedItems.contains($0.itemID) })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { geometry in
                let layout = gridLayout(for: geometry.size.width)
                ScrollView {
                    LazyVGrid(columns: layout.columns, spacing: spacing) {
                        ForEach(displayedItems) { item in
                            photoCell(item, size: layout.thumbnailSize)
                        }
                    }
                    .padding(horizontalPadding)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
                }
                .onKeyPress(.space) {
                    model.quickLookSelection()
                    return .handled
                }
            }
            Divider()
            DiscreteGridColumnControl(
                columnCount: $preferences.gridColumnCount,
                range: 2...8
            )
        }
        .onAppear { model.selection.formIntersection(Set(displayedItemIDs)) }
        .onChange(of: displayedItemIDs) { _, ids in
            model.selection.formIntersection(Set(ids))
        }
        .alert("新しい人物の名前", isPresented: $asksForSplitName) {
            TextField("名前", text: $draftName)
            Button("分離") { splitSelection() }
                .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("選択した顔を新しい人物として登録します。")
        }
        .alert("人物の名前", isPresented: $asksForGroupName) {
            TextField("名前", text: $draftName)
            Button("保存") { saveGroupName() }
                .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("キャンセル", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                workspace.route = .overview
            } label: {
                Label("人物一覧", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text("\(displayedItems.count)枚")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let group {
                Button(group.displayName == nil ? "名前を付ける…" : "名前を変更…") {
                    draftName = group.displayName ?? ""
                    asksForGroupName = true
                }
            }
            if !selectedFaceIDs.isEmpty {
                Menu("選択した\(model.selection.count)件を分類") {
                    correctionMenu
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var title: String {
        switch route {
        case .overview:
            L10n.string("people.title", defaultValue: "People", language: preferences.resolvedLanguage)
        case .unconfirmed:
            L10n.string("people.unconfirmed", defaultValue: "Unconfirmed", language: preferences.resolvedLanguage)
        case .group: group?.displayName ?? "名前のない人物"
        }
    }

    private func photoCell(_ item: RenameItem, size: CGFloat) -> some View {
        let selected = model.selection.contains(item.id)
        return VStack(alignment: .leading, spacing: 6) {
            ThumbnailView(url: item.originalURL, size: size)
            Text(item.displayName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(width: size + 16)
        .background(selected ? Palette.accent : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
        .foregroundStyle(selected ? Color.white : Color.primary)
        .contentShape(RoundedRectangle(cornerRadius: 13))
        .gesture(
            TapGesture(count: 2)
                .exclusively(before: TapGesture(count: 1))
                .onEnded { value in
                    switch value {
                    case .first:
                        model.selection = [item.id]
                        model.quickLookURL = item.originalURL
                    case .second:
                        select(item)
                    }
                }
        )
        .onForceClick {
            model.selection = [item.id]
            model.quickLookURL = item.originalURL
        }
        .contextMenu {
            let clickedFaceIDs = faceIDs(for: item.id)
            Button("クイックルック") { model.quickLookURL = item.originalURL }
            Divider()
            correctionMenu(faceIDs: model.selection.contains(item.id) ? selectedFaceIDs : clickedFaceIDs)
        }
        .accessibilityLabel("\(item.displayName)、\(selected ? "選択中" : "未選択")")
        .accessibilityHint("クリックして選択。ダブルクリックまたは押し込みでプレビュー")
    }

    @ViewBuilder
    private var correctionMenu: some View {
        correctionMenu(faceIDs: selectedFaceIDs)
    }

    @ViewBuilder
    private func correctionMenu(faceIDs: Set<FaceDescriptorID>) -> some View {
        if let sourcePersonID {
            Button(L10n.string(
                "people.notThisPerson",
                defaultValue: "Not This Person",
                language: preferences.resolvedLanguage
            )) {
                model.requestPeopleEdit(.reject(faceIDs: faceIDs, from: sourcePersonID))
            }
        }
        let otherPeople = workspace.currentPeople().filter { $0.id != sourcePersonID }
        if !otherPeople.isEmpty {
            Menu(L10n.string(
                "people.moveToPerson",
                defaultValue: "Move to Another Person…",
                language: preferences.resolvedLanguage
            )) {
                ForEach(otherPeople) { person in
                    Button(person.displayName) {
                        model.requestPeopleEdit(.reassign(
                            faceIDs: faceIDs,
                            from: sourcePersonID,
                            to: person.id
                        ))
                    }
                }
            }
        }
        Button(L10n.string(
            "people.splitPerson",
            defaultValue: "Split as a New Person…",
            language: preferences.resolvedLanguage
        )) {
            pendingSplitFaceIDs = faceIDs
            draftName = ""
            asksForSplitName = true
        }
    }

    private func select(_ item: RenameItem) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift),
           let anchor = selectionAnchor,
           let anchorIndex = displayedItemIDs.firstIndex(of: anchor),
           let clickedIndex = displayedItemIDs.firstIndex(of: item.id) {
            let range = min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)
            let ids = Set(range.map { displayedItemIDs[$0] })
            model.selection = modifiers.contains(.command) ? model.selection.union(ids) : ids
        } else if modifiers.contains(.command) {
            if model.selection.contains(item.id) { model.selection.remove(item.id) }
            else { model.selection.insert(item.id) }
            selectionAnchor = item.id
        } else {
            model.selection = [item.id]
            selectionAnchor = item.id
        }
    }

    private func faceIDs(for itemID: UUID) -> Set<FaceDescriptorID> {
        Set(displayedFaceIDs.filter { $0.itemID == itemID })
    }

    private func splitSelection() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !pendingSplitFaceIDs.isEmpty else { return }
        model.requestPeopleEdit(.split(
            faceIDs: pendingSplitFaceIDs,
            from: sourcePersonID,
            displayName: name
        ))
        pendingSplitFaceIDs = []
    }

    private func saveGroupName() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let group else { return }
        switch group.id {
        case let .person(personID):
            model.requestPeopleEdit(
                .rename(personID: personID, displayName: name),
                persistsBiometricData: false
            )
        case .candidate:
            model.requestPeopleEdit(.nameFaces(faceIDs: Set(group.faceIDs), displayName: name))
        }
    }

    private func gridLayout(for width: CGFloat) -> (columns: [GridItem], thumbnailSize: CGFloat) {
        let count = min(max(preferences.gridColumnCount, 2), 8)
        let contentWidth = max(1, width - horizontalPadding * 2)
        let cellWidth = max(64, floor((contentWidth - spacing * CGFloat(count - 1)) / CGFloat(count)))
        let thumbnailSize = max(48, cellWidth - 16)
        return (
            Array(repeating: GridItem(.fixed(cellWidth), spacing: spacing, alignment: .top), count: count),
            thumbnailSize
        )
    }
}
