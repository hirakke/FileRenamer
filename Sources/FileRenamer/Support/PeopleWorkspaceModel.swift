import Foundation
import RenameKit
import SwiftUI

struct PeopleAnalysisProgress: Equatable, Sendable {
    let completed: Int
    let total: Int

    static let zero = PeopleAnalysisProgress(completed: 0, total: 0)

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

enum PeopleRoute: Equatable, Sendable {
    case overview
    case group(PeopleGroupID)
    case unconfirmed
}

enum PeopleEditCommand: Sendable {
    case rename(personID: UUID, displayName: String)
    case nameFaces(faceIDs: Set<FaceDescriptorID>, displayName: String)
    case reject(faceIDs: Set<FaceDescriptorID>, from: UUID)
    case reassign(faceIDs: Set<FaceDescriptorID>, from: UUID?, to: UUID)
    case split(faceIDs: Set<FaceDescriptorID>, from: UUID?, displayName: String)
    case merge(
        groupIDs: Set<PeopleGroupID>,
        destinationPersonID: UUID?,
        newPersonName: String?
    )
}

enum PeopleWorkspaceError: LocalizedError {
    case storeUnavailable
    case noEligibleFaces
    case groupNotFound
    case mergeNeedsTwoGroups
    case mergeNeedsName

    var errorDescription: String? {
        switch self {
        case .storeUnavailable: "人物データの保存領域を開けませんでした。"
        case .noEligibleFaces: "学習に利用できる顔が選択されていません。"
        case .groupNotFound: "人物候補が更新されたため、もう一度選択してください。"
        case .mergeNeedsTwoGroups: "統合する人物を2人以上選択してください。"
        case .mergeNeedsName: "新しい人物の名前を入力してください。"
        }
    }
}

private enum PeopleAssignmentOverride: Hashable {
    case person(UUID)
    case unconfirmed
}

@MainActor
final class PeopleWorkspaceModel: ObservableObject {
    @Published private(set) var projection = PeopleWorkspaceProjection.empty
    @Published private(set) var isAnalyzing = false
    @Published private(set) var progress = PeopleAnalysisProgress.zero
    @Published private(set) var errorMessage: String?
    @Published var route: PeopleRoute = .overview
    @Published private(set) var undoStateRevision = 0

    private(set) var result = OfflineFaceClassificationResult.empty

    private let personStore: PersonStore?
    private var task: Task<Void, Never>?
    private var revision = 0
    private var latestItems: [RenameItem] = []
    private var latestSensitivity = FaceGroupingDefaults.sensitivity
    private var isEnabled = false
    private weak var undoManager: UndoManager?
    private var assignmentOverrides: [FaceDescriptorID: PeopleAssignmentOverride] = [:]

    private struct EditState {
        let store: PersonStoreSnapshot
        let overrides: [FaceDescriptorID: PeopleAssignmentOverride]
    }

    init(personStore: PersonStore?) {
        self.personStore = personStore
    }

    func schedule(
        items: [RenameItem],
        sensitivity: FaceGroupingSensitivity,
        enabled: Bool
    ) {
        revision &+= 1
        let scheduledRevision = revision
        task?.cancel()
        let previousItemIDs = Set(latestItems.map(\.id))
        let nextItemIDs = Set(items.map(\.id))
        if previousItemIDs != nextItemIDs || latestItems.count != items.count {
            result = .empty
            projection = .empty
            route = .overview
            assignmentOverrides = assignmentOverrides.filter {
                nextItemIDs.contains($0.key.itemID)
            }
        }
        latestItems = items
        latestSensitivity = sensitivity
        isEnabled = enabled

        guard enabled else {
            clearPublishedState()
            return
        }
        guard let personStore else {
            clearPublishedState()
            errorMessage = "人物データの保存領域を開けませんでした。"
            return
        }
        let candidates = Self.candidates(from: items)
        guard !candidates.isEmpty else {
            clearPublishedState()
            return
        }

        let people: [PersonProfileSnapshot]
        do {
            people = try personStore.people()
        } catch {
            clearPublishedState()
            errorMessage = error.localizedDescription
            return
        }

        errorMessage = nil
        isAnalyzing = true
        progress = PeopleAnalysisProgress(completed: 0, total: candidates.count)
        let configuration = OfflineFaceClassifierConfiguration(sensitivity: sensitivity)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let newResult = try await OfflineFaceClassifier.shared.scan(
                    candidates: candidates,
                    knownPeople: people,
                    configuration: configuration
                )
                guard !Task.isCancelled, revision == scheduledRevision else { return }
                result = newResult
                projection = makeProjection(result: newResult, people: people)
                progress = PeopleAnalysisProgress(
                    completed: candidates.count,
                    total: candidates.count
                )
                isAnalyzing = false
                task = nil
                normalizeRoute()
            } catch is CancellationError {
                if revision == scheduledRevision {
                    isAnalyzing = false
                    task = nil
                }
            } catch {
                guard revision == scheduledRevision else { return }
                result = .empty
                projection = .empty
                progress = .zero
                errorMessage = error.localizedDescription
                isAnalyzing = false
                task = nil
                route = .overview
            }
        }
    }

    func reclassifyUsingCachedEmbeddings() {
        schedule(
            items: latestItems,
            sensitivity: latestSensitivity,
            enabled: isEnabled
        )
    }

    /// Reorders only presentation. The active analysis keeps running and publishes
    /// against the newest order because face identity is keyed independently.
    func updatePresentationOrder(items: [RenameItem]) {
        guard Set(items.map(\.id)) == Set(latestItems.map(\.id)),
              items.count == latestItems.count
        else {
            schedule(items: items, sensitivity: latestSensitivity, enabled: isEnabled)
            return
        }
        latestItems = items
        guard result.classification != .empty else { return }
        projection = makeProjection(
            result: result,
            people: (try? personStore?.people()) ?? []
        )
        normalizeRoute()
    }

    func clear(cancelTask: Bool = true) {
        revision &+= 1
        if cancelTask { task?.cancel() }
        task = nil
        latestItems = []
        assignmentOverrides = [:]
        clearPublishedState()
    }

    func attachUndoManager(_ undoManager: UndoManager?) {
        self.undoManager = undoManager
        publishUndoState()
    }

    var canUndoPeopleEdit: Bool { undoManager?.canUndo == true }
    var canRedoPeopleEdit: Bool { undoManager?.canRedo == true }

    func undoPeopleEdit() {
        undoManager?.undo()
        publishUndoState()
    }

    func redoPeopleEdit() {
        undoManager?.redo()
        publishUndoState()
    }

    func perform(_ command: PeopleEditCommand) throws {
        guard let personStore else { throw PeopleWorkspaceError.storeUnavailable }
        let before = EditState(
            store: try personStore.snapshot(),
            overrides: assignmentOverrides
        )
        let actionName: String
        let after: EditState
        do {
            actionName = try apply(command, using: personStore)
            after = EditState(
                store: try personStore.snapshot(),
                overrides: assignmentOverrides
            )
        } catch {
            try? personStore.restore(before.store)
            assignmentOverrides = before.overrides
            refreshProjection()
            throw error
        }
        registerUndo(restoring: before, reciprocal: after, actionName: actionName)
        refreshProjection()
        reclassifyUsingCachedEmbeddings()
    }

    func faces(for groupID: PeopleGroupID) -> [ClassifiedFace] {
        guard let group = projection.groups.first(where: { $0.id == groupID }) else { return [] }
        let facesByID = Dictionary(uniqueKeysWithValues: result.facesByItemID.values
            .flatMap { $0 }
            .map { ($0.id, $0) })
        return group.faceIDs.compactMap { facesByID[$0] }
    }

    func face(_ id: FaceDescriptorID) -> ClassifiedFace? {
        result.facesByItemID[id.itemID]?.first { $0.id == id }
    }

    func group(_ id: PeopleGroupID) -> PeopleGroupProjection? {
        projection.groups.first { $0.id == id }
    }

    func currentPeople() -> [PersonProfileSnapshot] {
        (try? personStore?.people()) ?? []
    }

    private func clearPublishedState() {
        result = .empty
        projection = .empty
        isAnalyzing = false
        progress = .zero
        errorMessage = nil
        route = .overview
    }

    private func apply(
        _ command: PeopleEditCommand,
        using store: PersonStore
    ) throws -> String {
        switch command {
        case let .rename(personID, displayName):
            _ = try store.renamePerson(id: personID, displayName: displayName)
            return "人物名を変更"

        case let .nameFaces(faceIDs, displayName):
            let samples = try prototypeSamples(for: faceIDs)
            let person = try store.createPerson(
                displayName: displayName,
                prototypes: samples
            )
            setOverride(.person(person.id), for: faceIDs)
            route = .group(.person(person.id))
            return "人物に名前を付ける"

        case let .reject(faceIDs, personID):
            let samples = try prototypeSamples(for: faceIDs)
            _ = try store.rejectPrototypes(samples, from: personID)
            setOverride(.unconfirmed, for: faceIDs)
            return "人物から除外"

        case let .reassign(faceIDs, sourceID, destinationID):
            let samples = try prototypeSamples(for: faceIDs)
            _ = try store.reassignPrototypes(
                samples,
                from: sourceID,
                to: destinationID
            )
            setOverride(.person(destinationID), for: faceIDs)
            route = .group(.person(destinationID))
            return "人物を移動"

        case let .split(faceIDs, sourceID, displayName):
            let samples = try prototypeSamples(for: faceIDs)
            let person = try store.splitPerson(
                displayName: displayName,
                prototypes: samples,
                from: sourceID
            )
            setOverride(.person(person.id), for: faceIDs)
            route = .group(.person(person.id))
            return "人物を分離"

        case let .merge(groupIDs, destinationPersonID, newPersonName):
            guard groupIDs.count >= 2 else { throw PeopleWorkspaceError.mergeNeedsTwoGroups }
            let groups = try groupIDs.map { id in
                guard let group = group(id) else { throw PeopleWorkspaceError.groupNotFound }
                return group
            }
            let faceIDs = Set(groups.flatMap(\.faceIDs))
            let samples = try prototypeSamples(for: faceIDs)
            let storedPersonIDs = Set(groupIDs.compactMap { id -> UUID? in
                if case let .person(personID) = id { return personID }
                return nil
            })
            let firstStoredPersonID = projection.groups.compactMap { projected -> UUID? in
                guard groupIDs.contains(projected.id),
                      case let .person(personID) = projected.id
                else { return nil }
                return personID
            }.first
            let destinationID: UUID
            if let requested = destinationPersonID ?? firstStoredPersonID {
                _ = try store.mergePeople(
                    sourceIDs: storedPersonIDs.subtracting([requested]),
                    destinationID: requested,
                    additionalPrototypes: samples
                )
                destinationID = requested
            } else {
                let name = newPersonName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !name.isEmpty else { throw PeopleWorkspaceError.mergeNeedsName }
                destinationID = try store.createPerson(
                    displayName: name,
                    prototypes: samples
                ).id
            }
            setOverride(.person(destinationID), for: faceIDs)
            route = .group(.person(destinationID))
            return "人物を統合"
        }
    }

    private func prototypeSamples(
        for faceIDs: Set<FaceDescriptorID>
    ) throws -> [PersonEmbeddingSample] {
        let samples = faceIDs.sorted(by: Self.faceOrder).compactMap { faceID -> PersonEmbeddingSample? in
            guard let face = face(faceID),
                  face.eligibility == .prototypeEligible,
                  let embedding = face.embedding
            else { return nil }
            return PersonEmbeddingSample(
                embedding: embedding,
                captureQuality: face.captureQuality
            )
        }
        guard !samples.isEmpty else { throw PeopleWorkspaceError.noEligibleFaces }
        return samples
    }

    private func setOverride(
        _ override: PeopleAssignmentOverride,
        for faceIDs: Set<FaceDescriptorID>
    ) {
        for faceID in faceIDs { assignmentOverrides[faceID] = override }
    }

    private func makeProjection(
        result: OfflineFaceClassificationResult,
        people: [PersonProfileSnapshot]
    ) -> PeopleWorkspaceProjection {
        var assignments = result.classification.namedAssignments
            .mapValues(Set.init)
        var clusters = result.classification.unnamedClusters.map { Set($0.members) }
        var unconfirmed = Set(result.classification.unconfirmedFaceIDs)
        for (faceID, override) in assignmentOverrides {
            for personID in Array(assignments.keys) {
                assignments[personID]?.remove(faceID)
            }
            for index in clusters.indices { clusters[index].remove(faceID) }
            unconfirmed.remove(faceID)
            switch override {
            case let .person(personID):
                assignments[personID, default: []].insert(faceID)
            case .unconfirmed:
                unconfirmed.insert(faceID)
            }
        }
        let classification = PeopleClassificationResult(
            faceIDsByItemID: result.classification.faceIDsByItemID,
            namedAssignments: assignments.mapValues { Array($0).sorted(by: Self.faceOrder) },
            unnamedClusters: clusters
                .filter { $0.count >= 2 }
                .map { PeopleCandidateCluster(members: Array($0).sorted(by: Self.faceOrder)) },
            unconfirmedFaceIDs: Array(unconfirmed).sorted(by: Self.faceOrder)
        )
        return PeopleWorkspaceProjection.make(
            orderedItemIDs: latestItems.map(\.id),
            result: classification,
            people: people
        )
    }

    private func refreshProjection() {
        guard result.classification != .empty else { return }
        projection = makeProjection(result: result, people: currentPeople())
        normalizeRoute()
    }

    private func registerUndo(
        restoring state: EditState,
        reciprocal: EditState,
        actionName: String
    ) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            target.restoreForUndo(
                state,
                reciprocal: reciprocal,
                actionName: actionName
            )
        }
        undoManager.setActionName(actionName)
        publishUndoState()
    }

    private func restoreForUndo(
        _ state: EditState,
        reciprocal: EditState,
        actionName: String
    ) {
        guard let personStore else { return }
        do {
            try personStore.restore(state.store)
            assignmentOverrides = state.overrides
            refreshProjection()
            registerUndo(restoring: reciprocal, reciprocal: state, actionName: actionName)
            reclassifyUsingCachedEmbeddings()
        } catch {
            errorMessage = error.localizedDescription
        }
        publishUndoState()
    }

    private func publishUndoState() {
        undoStateRevision &+= 1
    }

    private static func faceOrder(_ lhs: FaceDescriptorID, _ rhs: FaceDescriptorID) -> Bool {
        if lhs.itemID != rhs.itemID { return lhs.itemID.uuidString < rhs.itemID.uuidString }
        return lhs.faceIndex < rhs.faceIndex
    }

    private func normalizeRoute() {
        switch route {
        case .overview:
            break
        case let .group(id) where !projection.groups.contains(where: { $0.id == id }):
            route = .overview
        case .unconfirmed where projection.unconfirmed.isEmpty:
            route = .overview
        default:
            break
        }
    }

    private static func candidates(from items: [RenameItem]) -> [FaceClassificationCandidate] {
        items.compactMap { item in
            let imageURLs = item.allURLs.filter(FileKinds.isImage)
            guard !imageURLs.isEmpty else { return nil }
            let analysisURL = imageURLs.first(where: { !FileKinds.isRAW($0) }) ?? imageURLs[0]
            return FaceClassificationCandidate(itemID: item.id, analysisURL: analysisURL)
        }
    }
}
