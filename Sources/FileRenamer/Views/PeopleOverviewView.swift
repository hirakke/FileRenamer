import AppKit
import RenameKit
import SwiftUI

struct PeopleOverviewView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: AppPreferences
    @ObservedObject var workspace: PeopleWorkspaceModel

    @State private var selectedGroupIDs = Set<PeopleGroupID>()
    @State private var confirmsMerge = false
    @State private var asksForName = false
    @State private var nameTarget: NameTarget?
    @State private var draftName = ""

    private enum NameTarget {
        case group(PeopleGroupID)
        case candidateMerge(Set<PeopleGroupID>)
    }

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 28)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if workspace.projection.groups.isEmpty && workspace.projection.unconfirmed.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                        ForEach(workspace.projection.groups) { group in
                            groupTile(group)
                        }
                        if !workspace.projection.unconfirmed.isEmpty {
                            unconfirmedTile
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .confirmationDialog(
            "選択した人物を統合しますか？",
            isPresented: $confirmsMerge,
            titleVisibility: .visible
        ) {
            Button("同じ人物として統合") { beginMerge() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("人物情報だけを統合します。写真ファイルは変更しません。Command-Zで元に戻せます。")
        }
        .alert("人物の名前", isPresented: $asksForName) {
            TextField("名前", text: $draftName)
            Button("保存") { commitName() }
                .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("キャンセル", role: .cancel) { nameTarget = nil }
        } message: {
            Text("このMac内に名前と顔の特徴量を保存します。")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string(
                    "people.title",
                    defaultValue: "People",
                    language: preferences.resolvedLanguage
                ))
                    .font(.title2.weight(.semibold))
                Text("現在読み込んでいる写真の人物候補")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if selectedGroupIDs.count >= 2 {
                Button(L10n.string(
                    "people.mergePeople",
                    defaultValue: "Merge as the Same Person…",
                    language: preferences.resolvedLanguage
                )) { confirmsMerge = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            workspace.isAnalyzing ? "人物を確認しています…" : "人物候補はありません",
            systemImage: workspace.isAnalyzing ? "person.2" : "person.2.slash",
            description: Text(workspace.isAnalyzing
                ? "写真はこのMac内だけで解析されます。"
                : "人物分類を有効にして写真を読み込むと、ここに候補が表示されます。")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func groupTile(_ group: PeopleGroupProjection) -> some View {
        let selected = selectedGroupIDs.contains(group.id)
        return Button {
            if NSEvent.modifierFlags.contains(.command) {
                toggleSelection(group.id)
            } else {
                selectedGroupIDs = []
                workspace.route = .group(group.id)
            }
        } label: {
            VStack(spacing: 10) {
                representativeFace(group)
                    .frame(width: 128, height: 128)
                    .clipShape(Circle())
                    .overlay {
                        Circle().strokeBorder(
                            selected ? Palette.accent : Color.primary.opacity(0.10),
                            lineWidth: selected ? 3 : 0.7
                        )
                    }
                Text(group.displayName ?? "名前のない人物")
                    .font(.headline)
                    .lineLimit(1)
                Text("\(group.itemIDs.count)枚")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(10)
            .background(selected ? Palette.accent.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if case .candidate = group.id {
                Button("名前を付ける…") { askForName(group.id) }
            } else {
                Button("名前を変更…") { askForName(group.id, current: group.displayName ?? "") }
            }
        }
        .accessibilityLabel("\(group.displayName ?? "名前のない人物")、\(group.itemIDs.count)枚")
    }

    @ViewBuilder
    private func representativeFace(_ group: PeopleGroupProjection) -> some View {
        if let face = workspace.face(group.representativeFaceID),
           let url = model.faceAnalysisURL(for: face.id.itemID) {
            FaceCropView(url: url, normalizedBoundingBox: face.normalizedBoundingBox, size: 128)
        } else {
            Circle()
                .fill(Color.secondary.opacity(0.10))
                .overlay(Image(systemName: "person.fill").font(.largeTitle).foregroundStyle(.tertiary))
        }
    }

    private var unconfirmedTile: some View {
        Button {
            selectedGroupIDs = []
            workspace.route = .unconfirmed
        } label: {
            VStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color.secondary.opacity(0.10))
                    Image(systemName: "person.fill.questionmark")
                        .font(.system(size: 42, weight: .regular))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 128, height: 128)
                Text(L10n.string(
                    "people.unconfirmed",
                    defaultValue: "Unconfirmed",
                    language: preferences.resolvedLanguage
                )).font(.headline)
                Text("\(Set(workspace.projection.unconfirmed.map(\.itemID)).count)枚")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(10)
        }
        .buttonStyle(.plain)
    }

    private func toggleSelection(_ id: PeopleGroupID) {
        if selectedGroupIDs.contains(id) { selectedGroupIDs.remove(id) }
        else { selectedGroupIDs.insert(id) }
    }

    private func askForName(_ groupID: PeopleGroupID, current: String = "") {
        nameTarget = .group(groupID)
        draftName = current
        asksForName = true
    }

    private func beginMerge() {
        let namedDestination = workspace.projection.groups.first { group in
            selectedGroupIDs.contains(group.id) && {
                if case .person = group.id { return true }
                return false
            }()
        }
        if case let .person(personID) = namedDestination?.id {
            model.requestPeopleEdit(.merge(
                groupIDs: selectedGroupIDs,
                destinationPersonID: personID,
                newPersonName: nil
            ))
            selectedGroupIDs = []
        } else {
            nameTarget = .candidateMerge(selectedGroupIDs)
            draftName = ""
            asksForName = true
        }
    }

    private func commitName() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let nameTarget else { return }
        switch nameTarget {
        case let .group(groupID):
            guard let group = workspace.group(groupID) else { return }
            switch groupID {
            case let .person(personID):
                model.requestPeopleEdit(
                    .rename(personID: personID, displayName: name),
                    persistsBiometricData: false
                )
            case .candidate:
                model.requestPeopleEdit(.nameFaces(faceIDs: Set(group.faceIDs), displayName: name))
            }
        case let .candidateMerge(groupIDs):
            model.requestPeopleEdit(.merge(
                groupIDs: groupIDs,
                destinationPersonID: nil,
                newPersonName: name
            ))
            selectedGroupIDs = []
        }
        self.nameTarget = nil
    }
}
