import Foundation

public struct PeopleAccuracyPair: Equatable, Sendable {
    public let expectedSame: Bool
    public let distance: Float

    public init(expectedSame: Bool, distance: Float) {
        self.expectedSame = expectedSame
        self.distance = distance
    }
}

public struct PeopleAccuracyCounts: Equatable, Sendable {
    public let truePositive: Int
    public let falsePositive: Int
    public let trueNegative: Int
    public let falseNegative: Int

    public init(
        truePositive: Int,
        falsePositive: Int,
        trueNegative: Int,
        falseNegative: Int
    ) {
        self.truePositive = truePositive
        self.falsePositive = falsePositive
        self.trueNegative = trueNegative
        self.falseNegative = falseNegative
    }
}

public struct PeopleThresholdReport: Equatable, Sendable {
    public let threshold: Float
    public let counts: PeopleAccuracyCounts
    public let precision: Double?
    public let recall: Double?

    public init(
        threshold: Float,
        counts: PeopleAccuracyCounts,
        precision: Double?,
        recall: Double?
    ) {
        self.threshold = threshold
        self.counts = counts
        self.precision = precision
        self.recall = recall
    }
}

public enum PeopleAccuracyMetrics {
    public static func evaluate(
        pairs: [PeopleAccuracyPair],
        threshold: Float
    ) -> PeopleThresholdReport {
        var truePositive = 0
        var falsePositive = 0
        var trueNegative = 0
        var falseNegative = 0
        for pair in pairs {
            let predictedSame = threshold.isFinite
                && pair.distance.isFinite
                && pair.distance <= threshold
            switch (pair.expectedSame, predictedSame) {
            case (true, true): truePositive += 1
            case (false, true): falsePositive += 1
            case (false, false): trueNegative += 1
            case (true, false): falseNegative += 1
            }
        }
        let counts = PeopleAccuracyCounts(
            truePositive: truePositive,
            falsePositive: falsePositive,
            trueNegative: trueNegative,
            falseNegative: falseNegative
        )
        let precisionDenominator = truePositive + falsePositive
        let recallDenominator = truePositive + falseNegative
        return PeopleThresholdReport(
            threshold: threshold,
            counts: counts,
            precision: precisionDenominator == 0
                ? nil
                : Double(truePositive) / Double(precisionDenominator),
            recall: recallDenominator == 0
                ? nil
                : Double(truePositive) / Double(recallDenominator)
        )
    }

    public static func evaluate(
        pairs: [PeopleAccuracyPair],
        thresholds: [Float]
    ) -> [PeopleThresholdReport] {
        thresholds.sorted().map { evaluate(pairs: pairs, threshold: $0) }
    }

    public static func meetsAutomaticClassificationGate(
        report: PeopleThresholdReport,
        personCount: Int,
        samePersonPairCount: Int,
        differentPersonPairCount: Int,
        minimumPrecision: Double = 0.99
    ) -> Bool {
        guard personCount >= 2,
              samePersonPairCount > 0,
              differentPersonPairCount > 0,
              minimumPrecision.isFinite,
              let precision = report.precision,
              precision.isFinite
        else { return false }
        return precision >= minimumPrecision
    }
}
