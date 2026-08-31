import Foundation

public enum FaceEligibilityTier: Int, Codable, Hashable, Sendable {
    case displayOnly
    case classificationEligible
    case prototypeEligible
}

public enum FaceIneligibilityReason: String, Codable, Hashable, Sendable {
    case tooSmall
    case lowCaptureQuality
    case incompleteLandmarks
    case alignmentFailed
    case embeddingFailed
}

public struct FaceEligibilityDecision: Equatable, Sendable {
    public let tier: FaceEligibilityTier
    public let reason: FaceIneligibilityReason?

    public init(tier: FaceEligibilityTier, reason: FaceIneligibilityReason?) {
        self.tier = tier
        self.reason = reason
    }
}

public struct FaceEligibilityPolicy: Hashable, Sendable {
    public let minimumFaceSide: CGFloat
    public let classificationMinimumCaptureQuality: Float
    public let prototypeMinimumFaceSide: CGFloat
    public let prototypeMinimumCaptureQuality: Float

    public init(
        minimumFaceSide: CGFloat = 40,
        classificationMinimumCaptureQuality: Float,
        prototypeMinimumFaceSide: CGFloat = 80,
        prototypeMinimumCaptureQuality: Float = 0.45
    ) {
        self.minimumFaceSide = minimumFaceSide
        self.classificationMinimumCaptureQuality = classificationMinimumCaptureQuality
        self.prototypeMinimumFaceSide = prototypeMinimumFaceSide
        self.prototypeMinimumCaptureQuality = prototypeMinimumCaptureQuality
    }

    public init(sensitivity: FaceGroupingSensitivity) {
        self.init(
            classificationMinimumCaptureQuality: sensitivity.policy.minimumCaptureQuality
        )
    }

    public func tier(
        faceSide: CGFloat,
        quality: Float?,
        hasFivePointAlignment: Bool
    ) -> FaceEligibilityTier {
        decision(
            faceSide: faceSide,
            quality: quality,
            hasFivePointAlignment: hasFivePointAlignment
        ).tier
    }

    public func decision(
        faceSide: CGFloat,
        quality: Float?,
        hasFivePointAlignment: Bool
    ) -> FaceEligibilityDecision {
        guard faceSide.isFinite, faceSide >= minimumFaceSide else {
            return FaceEligibilityDecision(tier: .displayOnly, reason: .tooSmall)
        }
        guard hasFivePointAlignment else {
            return FaceEligibilityDecision(tier: .displayOnly, reason: .incompleteLandmarks)
        }
        guard let quality,
              quality.isFinite,
              quality >= classificationMinimumCaptureQuality
        else {
            return FaceEligibilityDecision(tier: .displayOnly, reason: .lowCaptureQuality)
        }
        if faceSide >= prototypeMinimumFaceSide,
           quality >= prototypeMinimumCaptureQuality {
            return FaceEligibilityDecision(tier: .prototypeEligible, reason: nil)
        }
        return FaceEligibilityDecision(tier: .classificationEligible, reason: nil)
    }
}

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
                knownPersonAmbiguityMargin: 0.10,
                rejectionMaximumDistance: 0.24,
                clusterEpsilon: 0.32,
                clusterMinimumPoints: 2
            )
        case .standard:
            return FaceGroupingPolicy(
                minimumCaptureQuality: 0.20,
                knownPersonMaximumDistance: 0.36,
                knownPersonAmbiguityMargin: 0.08,
                rejectionMaximumDistance: 0.24,
                clusterEpsilon: 0.42,
                clusterMinimumPoints: 2
            )
        case .broad:
            return FaceGroupingPolicy(
                minimumCaptureQuality: 0.10,
                knownPersonMaximumDistance: 0.44,
                knownPersonAmbiguityMargin: 0.06,
                rejectionMaximumDistance: 0.24,
                clusterEpsilon: 0.52,
                clusterMinimumPoints: 2
            )
        }
    }
}

public struct FaceGroupingPolicy: Equatable, Sendable {
    public let minimumCaptureQuality: Float
    public let knownPersonMaximumDistance: Float
    public let knownPersonAmbiguityMargin: Float
    public let rejectionMaximumDistance: Float
    public let clusterEpsilon: Float
    public let clusterMinimumPoints: Int

    public init(
        minimumCaptureQuality: Float,
        knownPersonMaximumDistance: Float,
        knownPersonAmbiguityMargin: Float,
        rejectionMaximumDistance: Float,
        clusterEpsilon: Float,
        clusterMinimumPoints: Int
    ) {
        self.minimumCaptureQuality = minimumCaptureQuality
        self.knownPersonMaximumDistance = knownPersonMaximumDistance
        self.knownPersonAmbiguityMargin = knownPersonAmbiguityMargin
        self.rejectionMaximumDistance = rejectionMaximumDistance
        self.clusterEpsilon = clusterEpsilon
        self.clusterMinimumPoints = clusterMinimumPoints
    }
}

public enum FaceGroupingDefaults {
    public static let classifiesPeople = false
    public static let sensitivity = FaceGroupingSensitivity.standard
}
