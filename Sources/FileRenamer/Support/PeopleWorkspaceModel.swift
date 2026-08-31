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

@MainActor
final class PeopleWorkspaceModel: ObservableObject {
    @Published private(set) var projection = PeopleWorkspaceProjection.empty
    @Published private(set) var isAnalyzing = false
    @Published private(set) var progress = PeopleAnalysisProgress.zero
    @Published private(set) var errorMessage: String?
    @Published var route: PeopleRoute = .overview

    private(set) var result = OfflineFaceClassificationResult.empty

    private let personStore: PersonStore?
    private var task: Task<Void, Never>?
    private var revision = 0
    private var latestItems: [RenameItem] = []
    private var latestSensitivity = FaceGroupingDefaults.sensitivity
    private var isEnabled = false

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
                projection = PeopleWorkspaceProjection.make(
                    orderedItemIDs: latestItems.map(\.id),
                    result: newResult.classification,
                    people: people
                )
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
        projection = PeopleWorkspaceProjection.make(
            orderedItemIDs: items.map(\.id),
            result: result.classification,
            people: (try? personStore?.people()) ?? []
        )
        normalizeRoute()
    }

    func clear(cancelTask: Bool = true) {
        revision &+= 1
        if cancelTask { task?.cancel() }
        task = nil
        latestItems = []
        clearPublishedState()
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

    private func clearPublishedState() {
        result = .empty
        projection = .empty
        isAnalyzing = false
        progress = .zero
        errorMessage = nil
        route = .overview
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
