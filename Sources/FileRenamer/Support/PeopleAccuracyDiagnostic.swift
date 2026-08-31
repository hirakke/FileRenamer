#if DEBUG
import AppKit
import Foundation
import RenameKit

struct PeopleAccuracyPresetResult: Identifiable, Sendable {
    let sensitivity: FaceGroupingSensitivity
    let report: PeopleThresholdReport
    let ambiguousCount: Int
    let meetsAutomaticClassificationGate: Bool

    var id: String { sensitivity.rawValue }
}

struct PeopleAccuracyReport: Sendable {
    let labels: [String]
    let inputImageCount: Int
    let eligibleImageCount: Int
    let unreadableImageCount: Int
    let noEligibleFaceCount: Int
    let samePersonPairCount: Int
    let differentPersonPairCount: Int
    let presets: [PeopleAccuracyPresetResult]
    let thresholdTable: [PeopleThresholdReport]

    var exportText: String {
        var lines = [
            "FileRenamer 人物分類ローカル診断",
            "作成日時: \(ISO8601DateFormatter().string(from: Date()))",
            "人物ラベル: \(labels.joined(separator: ", "))",
            "入力画像: \(inputImageCount)",
            "評価対象画像: \(eligibleImageCount)",
            "読み取れない画像: \(unreadableImageCount)",
            "評価可能な顔がない画像: \(noEligibleFaceCount)",
            "同一人物ペア: \(samePersonPairCount)",
            "別人物ペア: \(differentPersonPairCount)",
            "",
            "プリセット"
        ]
        for preset in presets {
            lines.append(
                "\(preset.sensitivity.rawValue): threshold=\(format(preset.report.threshold)), "
                    + "precision=\(format(preset.report.precision)), recall=\(format(preset.report.recall)), "
                    + "FP=\(preset.report.counts.falsePositive), FN=\(preset.report.counts.falseNegative), "
                    + "ambiguous=\(preset.ambiguousCount), gate=\(preset.meetsAutomaticClassificationGate ? "pass" : "fail")"
            )
        }
        lines.append("")
        lines.append("閾値表")
        for row in thresholdTable {
            lines.append(
                "threshold=\(format(row.threshold)), precision=\(format(row.precision)), "
                    + "recall=\(format(row.recall)), TP=\(row.counts.truePositive), "
                    + "FP=\(row.counts.falsePositive), TN=\(row.counts.trueNegative), "
                    + "FN=\(row.counts.falseNegative)"
            )
        }
        lines.append("")
        lines.append("画像の場所、顔画像、顔特徴量はこのレポートに含まれません。")
        return lines.joined(separator: "\n")
    }

    private func format(_ value: Float) -> String {
        String(format: "%.3f", value)
    }

    private func format(_ value: Double?) -> String {
        value.map { String(format: "%.3f", $0) } ?? "—"
    }
}

@MainActor
final class PeopleAccuracyDiagnostic: ObservableObject {
    enum Phase: Equatable {
        case idle
        case collecting
        case analyzing
        case evaluating
        case finished
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var report: PeopleAccuracyReport?
    private let runner = DiagnosticRunner()
    private var task: Task<Void, Never>?
    private var activeRunID = UUID()

    var isRunning: Bool {
        switch phase {
        case .collecting, .analyzing, .evaluating: true
        default: false
        }
    }

    func chooseFolderAndRun() {
        let panel = NSOpenPanel()
        panel.title = "人物ごとに分けた診断用フォルダを選択"
        panel.message = "直下の各フォルダ名を人物ラベルとして、画像をこのMac内で診断します。"
        panel.prompt = "診断を開始"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let rootURL = panel.url else { return }
        run(rootURL: rootURL)
    }

    func cancel() {
        task?.cancel()
        task = nil
        activeRunID = UUID()
        phase = .idle
    }

    func exportReport() {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.title = "診断レポートを書き出す"
        panel.prompt = "書き出す"
        panel.nameFieldStringValue = "FileRenamer-People-Accuracy.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try report.exportText.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            phase = .failed("レポートを書き出せませんでした：\(error.localizedDescription)")
        }
    }

    private func run(rootURL: URL) {
        task?.cancel()
        let runID = UUID()
        activeRunID = runID
        report = nil
        phase = .collecting
        task = Task { [weak self] in
            guard let self else { return }
            let accessed = rootURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { rootURL.stopAccessingSecurityScopedResource() }
            }
            do {
                let samples = try await runner.collectSamples(rootURL: rootURL)
                try Task.checkCancellation()
                guard activeRunID == runID else { return }
                phase = .analyzing
                let batch = try await FaceAnalyzer.shared.analyze(
                    candidates: samples.map {
                        FaceAnalysisCandidate(itemID: $0.id, analysisURL: $0.url)
                    },
                    eligibilityPolicy: FaceEligibilityPolicy(sensitivity: .broad)
                )
                try Task.checkCancellation()
                guard activeRunID == runID else { return }
                phase = .evaluating
                let completedReport = try await runner.makeReport(samples: samples, batch: batch)
                guard activeRunID == runID else { return }
                report = completedReport
                phase = .finished
                task = nil
            } catch is CancellationError {
                guard activeRunID == runID else { return }
                phase = .idle
                task = nil
            } catch {
                guard activeRunID == runID else { return }
                phase = .failed(error.localizedDescription)
                task = nil
            }
        }
    }
}

private enum PeopleAccuracyDiagnosticError: LocalizedError {
    case notEnoughLabelFolders
    case noSupportedImages

    var errorDescription: String? {
        switch self {
        case .notEnoughLabelFolders:
            "診断には、人物ごとのフォルダが2つ以上必要です。"
        case .noSupportedImages:
            "診断できる画像が見つかりませんでした。"
        }
    }
}

private struct DiagnosticSample: Sendable {
    let id: UUID
    let label: String
    let url: URL
}

private struct LabelledEmbedding: Sendable {
    let label: String
    let embedding: FaceEmbedding
}

private actor DiagnosticRunner {
    private static let maximumImagesPerLabel = 50
    private static let maximumPairCountPerClass = 10_000

    func collectSamples(rootURL: URL) throws -> [DiagnosticSample] {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        let labelURLs = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard labelURLs.count >= 2 else {
            throw PeopleAccuracyDiagnosticError.notEnoughLabelFolders
        }

        var samples: [DiagnosticSample] = []
        for labelURL in labelURLs {
            try Task.checkCancellation()
            guard let enumerator = fileManager.enumerator(
                at: labelURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            var imageURLs: [URL] = []
            for case let url as URL in enumerator {
                if imageURLs.count.isMultiple(of: 64) { try Task.checkCancellation() }
                let isRegularFile = try? url.resourceValues(
                    forKeys: [.isRegularFileKey]
                ).isRegularFile
                if isRegularFile == true, FileKinds.isImage(url) {
                    imageURLs.append(url)
                }
            }
            let images = imageURLs
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                .prefix(Self.maximumImagesPerLabel)
            samples.append(contentsOf: images.map {
                DiagnosticSample(id: UUID(), label: labelURL.lastPathComponent, url: $0)
            })
        }
        guard !samples.isEmpty else { throw PeopleAccuracyDiagnosticError.noSupportedImages }
        return samples
    }

    func makeReport(
        samples: [DiagnosticSample],
        batch: FaceAnalysisBatch
    ) throws -> PeopleAccuracyReport {
        try Task.checkCancellation()
        var labelled: [LabelledEmbedding] = []
        for sample in samples {
            guard !batch.unreadableItemIDs.contains(sample.id),
                  let faces = batch.facesByItemID[sample.id]
            else { continue }
            let bestFace = faces
                .filter { $0.embedding != nil && $0.eligibility != .displayOnly }
                .sorted(by: Self.bestFaceOrder)
                .first
            if let embedding = bestFace?.embedding {
                labelled.append(LabelledEmbedding(label: sample.label, embedding: embedding))
            }
        }
        try Task.checkCancellation()

        let pairs = try Self.makePairs(labelled)
        let sameCount = pairs.lazy.filter(\.expectedSame).count
        let differentCount = pairs.count - sameCount
        let labels = Array(Set(samples.map(\.label))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        let presets = FaceGroupingSensitivity.allCases.map { sensitivity in
            let policy = sensitivity.policy
            let report = PeopleAccuracyMetrics.evaluate(
                pairs: pairs,
                threshold: policy.knownPersonMaximumDistance
            )
            let ambiguous = pairs.filter {
                abs($0.distance - policy.knownPersonMaximumDistance)
                    < policy.knownPersonAmbiguityMargin
            }.count
            return PeopleAccuracyPresetResult(
                sensitivity: sensitivity,
                report: report,
                ambiguousCount: ambiguous,
                meetsAutomaticClassificationGate: PeopleAccuracyMetrics
                    .meetsAutomaticClassificationGate(
                        report: report,
                        personCount: labels.count,
                        samePersonPairCount: sameCount,
                        differentPersonPairCount: differentCount
                    )
            )
        }
        let thresholds = stride(from: Float(0.20), through: Float(0.60), by: Float(0.02))
            .map { Float((Double($0) * 100).rounded() / 100) }
        return PeopleAccuracyReport(
            labels: labels,
            inputImageCount: samples.count,
            eligibleImageCount: labelled.count,
            unreadableImageCount: batch.unreadableItemIDs.count,
            noEligibleFaceCount: max(
                0,
                samples.count - batch.unreadableItemIDs.count - labelled.count
            ),
            samePersonPairCount: sameCount,
            differentPersonPairCount: differentCount,
            presets: presets,
            thresholdTable: PeopleAccuracyMetrics.evaluate(pairs: pairs, thresholds: thresholds)
        )
    }

    private static func bestFaceOrder(_ lhs: AnalyzedFace, _ rhs: AnalyzedFace) -> Bool {
        if lhs.eligibility != rhs.eligibility {
            return lhs.eligibility.rawValue > rhs.eligibility.rawValue
        }
        let leftArea = lhs.normalizedBoundingBox.width * lhs.normalizedBoundingBox.height
        let rightArea = rhs.normalizedBoundingBox.width * rhs.normalizedBoundingBox.height
        if leftArea != rightArea { return leftArea > rightArea }
        if lhs.captureQuality != rhs.captureQuality {
            return (lhs.captureQuality ?? 0) > (rhs.captureQuality ?? 0)
        }
        return lhs.id.faceIndex < rhs.id.faceIndex
    }

    private static func makePairs(_ embeddings: [LabelledEmbedding]) throws -> [PeopleAccuracyPair] {
        let grouped = Dictionary(grouping: embeddings, by: \.label)
        let labels = grouped.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var samePairs: [PeopleAccuracyPair] = []
        var differentPairs: [PeopleAccuracyPair] = []

        for label in labels {
            let values = grouped[label] ?? []
            guard values.count > 1 else { continue }
            for firstIndex in 0..<(values.count - 1) {
                for secondIndex in (firstIndex + 1)..<values.count {
                    try Task.checkCancellation()
                    let distance = try values[firstIndex].embedding.cosineDistance(
                        to: values[secondIndex].embedding
                    )
                    samePairs.append(.init(expectedSame: true, distance: distance))
                    if samePairs.count == maximumPairCountPerClass { break }
                }
                if samePairs.count == maximumPairCountPerClass { break }
            }
            if samePairs.count == maximumPairCountPerClass { break }
        }

        guard labels.count > 1 else { return samePairs }
        for firstLabelIndex in 0..<(labels.count - 1) {
            let first = grouped[labels[firstLabelIndex]] ?? []
            for secondLabelIndex in (firstLabelIndex + 1)..<labels.count {
                let second = grouped[labels[secondLabelIndex]] ?? []
                for left in first {
                    for right in second {
                        try Task.checkCancellation()
                        differentPairs.append(.init(
                            expectedSame: false,
                            distance: try left.embedding.cosineDistance(to: right.embedding)
                        ))
                        if differentPairs.count == maximumPairCountPerClass { break }
                    }
                    if differentPairs.count == maximumPairCountPerClass { break }
                }
                if differentPairs.count == maximumPairCountPerClass { break }
            }
            if differentPairs.count == maximumPairCountPerClass { break }
        }
        return samePairs + differentPairs
    }
}
#endif
