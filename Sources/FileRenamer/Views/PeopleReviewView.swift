import RenameKit
import SwiftUI

struct PeopleReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: AppPreferences

    let review: AppModel.PeopleReview

    @State private var selectedGroupID: String?
    @State private var draftNames: [String: String] = [:]
    @State private var personPendingDeletion: PersonProfileSnapshot?

    init(review: AppModel.PeopleReview) {
        self.review = review
        _selectedGroupID = State(initialValue: review.focusedGroupID)
    }

    private var groups: [AppModel.PeopleReviewGroup] { model.peopleReviewGroups }

    private var selectedGroup: AppModel.PeopleReviewGroup? {
        groups.first { $0.id == selectedGroupID } ?? groups.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                groupList
                    .frame(width: 240)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 920, height: 680)
        .onAppear { synchronizeSelectionAndName() }
        .onChange(of: groups.map(\.id)) { _, _ in synchronizeSelectionAndName() }
        .onChange(of: selectedGroupID) { _, _ in synchronizeName() }
        .confirmationDialog(
            "このMacに人物データを保存しますか？",
            isPresented: Binding(
                get: { model.pendingPersonRegistration != nil },
                set: { if !$0 { model.cancelPersonRegistration() } }
            ),
            titleVisibility: .visible
        ) {
            Button("名前を登録") { model.confirmPersonRegistration() }
            Button("キャンセル", role: .cancel) { model.cancelPersonRegistration() }
        } message: {
            Text("登録した名前と代表特徴量をこのMac内に保存します。顔画像や写真の場所は保存しません。")
        }
        .confirmationDialog(
            L10n.format(
                "people.confirmRemoveRegistration",
                defaultValue: "Remove the registration for “%@”?",
                arguments: [personPendingDeletion?.displayName ?? ""],
                language: preferences.resolvedLanguage
            ),
            isPresented: Binding(
                get: { personPendingDeletion != nil },
                set: { if !$0 { personPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("登録を解除", role: .destructive) {
                if let person = personPendingDeletion { model.deletePerson(id: person.id) }
                personPendingDeletion = nil
            }
            Button("キャンセル", role: .cancel) { personPendingDeletion = nil }
        } message: {
            Text("名前と代表特徴量だけを削除します。写真ファイルは変更しません。")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("人物候補")
                    .font(.title2.weight(.semibold))
                Text("同じ人物の可能性がある写真です。確認して、必要な候補だけに名前を登録できます。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("閉じる") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(18)
    }

    private var groupList: some View {
        List(groups, selection: $selectedGroupID) { group in
            VStack(alignment: .leading, spacing: 2) {
                Text(groupTitle(group))
                    .font(.callout.weight(group.isKnownPerson ? .semibold : .regular))
                    .lineLimit(1)
                Text(photoCount(group.faces.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .tag(group.id)
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var detail: some View {
        if let group = selectedGroup {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(groupTitle(group))
                        .font(.headline)
                    Text(photoCount(group.faces.count))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 144), spacing: 14)],
                        spacing: 14
                    ) {
                        ForEach(group.faces) { face in
                            faceCard(face)
                        }
                    }
                    .padding(.vertical, 2)
                }

                Divider()
                namingControls(group)
            }
            .padding(20)
        } else {
            ContentUnavailableView(
                "人物候補はありません",
                systemImage: "person.2.slash",
                description: Text("設定を有効にして写真を読み込むと、候補がここに表示されます。")
            )
        }
    }

    private func faceCard(_ face: ClassifiedFace) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let url = model.faceAnalysisURL(for: face.id.itemID) {
                FaceCropView(
                    url: url,
                    normalizedBoundingBox: face.normalizedBoundingBox,
                    size: 132
                )
                Text(url.lastPathComponent)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 132, alignment: .leading)
            }
            if let quality = face.captureQuality {
                Text(L10n.format(
                    "people.captureQuality",
                    defaultValue: "Quality %lld%%",
                    arguments: [Int((quality * 100).rounded())],
                    language: preferences.resolvedLanguage
                ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func namingControls(_ group: AppModel.PeopleReviewGroup) -> some View {
        HStack(spacing: 10) {
            TextField(
                group.isKnownPerson ? "名前" : "誰ですか？",
                text: Binding(
                    get: { draftNames[group.id, default: group.person?.displayName ?? ""] },
                    set: { draftNames[group.id] = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 320)

            if let person = group.person {
                Button("名前を変更") {
                    model.renamePerson(
                        id: person.id,
                        displayName: draftNames[group.id, default: person.displayName]
                    )
                }
                .disabled(draftNames[group.id, default: person.displayName]
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("登録を解除…", role: .destructive) {
                    personPendingDeletion = person
                }
            } else {
                Button("名前を登録") {
                    model.requestPersonRegistration(
                        groupID: group.id,
                        displayName: draftNames[group.id, default: ""]
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(draftNames[group.id, default: ""]
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Spacer()
        }
    }

    private func synchronizeSelectionAndName() {
        if !groups.contains(where: { $0.id == selectedGroupID }) {
            selectedGroupID = groups.first?.id
        }
        synchronizeName()
        if groups.isEmpty { dismiss() }
    }

    private func synchronizeName() {
        guard let group = selectedGroup, draftNames[group.id] == nil else { return }
        draftNames[group.id] = group.person?.displayName ?? ""
    }

    private func photoCount(_ count: Int) -> String {
        L10n.format(
            "people.photoCount",
            defaultValue: "%lld Photos",
            arguments: [count],
            language: preferences.resolvedLanguage
        )
    }

    private func groupTitle(_ group: AppModel.PeopleReviewGroup) -> String {
        group.person?.displayName ?? L10n.string(
            "people.unknownPerson",
            defaultValue: "Who is this?",
            language: preferences.resolvedLanguage
        )
    }
}
