import Foundation

public enum FaceGroupingSensitivity: String, CaseIterable, Codable, Identifiable, Sendable {
    case strict
    case standard
    case broad

    public var id: String { rawValue }

    public var policy: FaceGroupingPolicy {
        switch self {
        case .strict:
            return FaceGroupingPolicy(
                minimumCaptureQuality: 0.30,
                knownPersonMaximumDistance: 0.28,
                clusterEpsilon: 0.32,
                clusterMinimumPoints: 2
            )
        case .standard:
            return FaceGroupingPolicy(
                minimumCaptureQuality: 0.20,
                knownPersonMaximumDistance: 0.36,
                clusterEpsilon: 0.42,
                clusterMinimumPoints: 2
            )
        case .broad:
            return FaceGroupingPolicy(
                minimumCaptureQuality: 0.10,
                knownPersonMaximumDistance: 0.44,
                clusterEpsilon: 0.52,
                clusterMinimumPoints: 2
            )
        }
    }
}

public struct FaceGroupingPolicy: Equatable, Sendable {
    public let minimumCaptureQuality: Float
    public let knownPersonMaximumDistance: Float
    public let clusterEpsilon: Float
    public let clusterMinimumPoints: Int

    public init(
        minimumCaptureQuality: Float,
        knownPersonMaximumDistance: Float,
        clusterEpsilon: Float,
        clusterMinimumPoints: Int
    ) {
        self.minimumCaptureQuality = minimumCaptureQuality
        self.knownPersonMaximumDistance = knownPersonMaximumDistance
        self.clusterEpsilon = clusterEpsilon
        self.clusterMinimumPoints = clusterMinimumPoints
    }
}

public enum FaceGroupingDefaults {
    public static let classifiesPeople = false
    public static let sensitivity = FaceGroupingSensitivity.standard
}
