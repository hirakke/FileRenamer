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
        distances: [FaceDescriptorPair: Float]
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
                if clusterIndexByID[neighbor] == nil {
                    clusterIndexByID[neighbor] = clusterIndex
                }
            }
        }

        let clusters = (0..<nextClusterIndex).compactMap { clusterIndex -> [FaceDescriptorID]? in
            let members = orderedIDs.filter { clusterIndexByID[$0] == clusterIndex }
            return members.isEmpty ? nil : members
        }
        let outliers = orderedIDs.filter { clusterIndexByID[$0] == nil }
        return FaceClusterResult(clusters: clusters, outliers: outliers)
    }

    private func unique(_ ids: [FaceDescriptorID]) -> [FaceDescriptorID] {
        var seen: Set<FaceDescriptorID> = []
        return ids.filter { seen.insert($0).inserted }
    }
}
