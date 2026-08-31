import Foundation

public struct FaceClusterResult: Equatable, Sendable {
    public let clusters: [[FaceDescriptorID]]
    public let outliers: [FaceDescriptorID]

    public init(clusters: [[FaceDescriptorID]], outliers: [FaceDescriptorID]) {
        self.clusters = clusters
        self.outliers = outliers
    }
}

/// Deterministic density clustering inspired by the MIT-licensed `mattt/DBSCAN`.
///
/// Distances are calculated before clustering because the concrete embedding may be
/// owned by a Vision/Core ML actor. Keeping only scalar distances here also makes the
/// safety-critical grouping behaviour independently testable.
public struct FaceDensityClusterer: Sendable {
    public init() {}

    public func cluster(
        ids: [FaceDescriptorID],
        epsilon: Float,
        minimumPoints: Int = 2,
        distances: [FaceDescriptorPair: Float],
        cannotLink: Set<FaceDescriptorPair> = []
    ) -> FaceClusterResult {
        let orderedIDs = unique(ids)
        guard !orderedIDs.isEmpty else {
            return FaceClusterResult(clusters: [], outliers: [])
        }

        let safeEpsilon = max(0, epsilon)
        let safeMinimumPoints = max(2, minimumPoints)
        var visited: Set<FaceDescriptorID> = []
        var clusterIndexByID: [FaceDescriptorID: Int] = [:]
        var nextClusterIndex = 0

        func neighbors(of id: FaceDescriptorID) -> [FaceDescriptorID] {
            orderedIDs.filter { candidate in
                if candidate == id { return true }
                guard let distance = distances[FaceDescriptorPair(id, candidate)],
                      distance.isFinite
                else { return false }
                return distance < safeEpsilon
            }
        }

        func conflictsWithCluster(_ id: FaceDescriptorID, clusterIndex: Int) -> Bool {
            orderedIDs.contains { member in
                clusterIndexByID[member] == clusterIndex
                    && cannotLink.contains(FaceDescriptorPair(id, member))
            }
        }

        for id in orderedIDs where !visited.contains(id) {
            visited.insert(id)
            let initialNeighbors = neighbors(of: id)
            guard initialNeighbors.count >= safeMinimumPoints else { continue }

            let clusterIndex = nextClusterIndex
            nextClusterIndex += 1
            clusterIndexByID[id] = clusterIndex

            var queue = initialNeighbors.filter { $0 != id }
            var queued = Set(queue)
            var cursor = 0

            while cursor < queue.count {
                let neighbor = queue[cursor]
                cursor += 1

                if clusterIndexByID[neighbor] != nil { continue }
                // A rejected point remains unvisited so it can seed or join a
                // later compatible cluster instead of disappearing silently.
                if conflictsWithCluster(neighbor, clusterIndex: clusterIndex) { continue }

                if !visited.contains(neighbor) {
                    visited.insert(neighbor)
                    let expandedNeighbors = neighbors(of: neighbor)
                    if expandedNeighbors.count >= safeMinimumPoints {
                        for expanded in expandedNeighbors where !queued.contains(expanded) {
                            queue.append(expanded)
                            queued.insert(expanded)
                        }
                    }
                }

                // A point previously marked as noise can become density-reachable.
                clusterIndexByID[neighbor] = clusterIndex
            }
        }

        let allClusters = (0..<nextClusterIndex).map { clusterIndex in
            orderedIDs.filter { clusterIndexByID[$0] == clusterIndex }
        }
        let validClusterIndexes = Set(allClusters.indices.filter {
            allClusters[$0].count >= safeMinimumPoints
        })
        let clusters = allClusters.enumerated().compactMap {
            clusterIndex, members -> [FaceDescriptorID]? in
            guard validClusterIndexes.contains(clusterIndex) else { return nil }
            return members
        }
        let outliers = orderedIDs.filter { id in
            guard let clusterIndex = clusterIndexByID[id] else { return true }
            return !validClusterIndexes.contains(clusterIndex)
        }
        return FaceClusterResult(clusters: clusters, outliers: outliers)
    }

    private func unique(_ ids: [FaceDescriptorID]) -> [FaceDescriptorID] {
        var seen: Set<FaceDescriptorID> = []
        return ids.filter { seen.insert($0).inserted }
    }
}
