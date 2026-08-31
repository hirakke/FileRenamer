#if DEBUG
import RenameKit
import SwiftUI

struct PeopleAccuracyDiagnosticView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var diagnostic = PeopleAccuracyDiagnostic()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("人物分類のローカル診断")
                        .font(.title2.weight(.semibold))
                    Text("人物ごとのフォルダを使い、現在の認識処理をこのMac内だけで評価します。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("閉じる") { dismiss() }
            }

            Divider()

            content

            Spacer(minLength: 0)

            HStack {
                if diagnostic.isRunning {
                    Button("中止", role: .cancel) { diagnostic.cancel() }
                }
                Spacer()
                if diagnostic.report != nil {
                    Button("レポートを書き出す…") { diagnostic.exportReport() }
                }
                Button(diagnostic.report == nil ? "診断用フォルダを選択…" : "別のフォルダで診断…") {
                    diagnostic.chooseFolderAndRun()
                }
                .disabled(diagnostic.isRunning)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 720, height: 620)
    }

    @ViewBuilder
    private var content: some View {
        switch diagnostic.phase {
        case .idle:
            instructions
        case .collecting:
            running("画像を確認しています…")
        case .analyzing:
            running("顔を検出し、特徴を比較しています…")
        case .evaluating:
            running("精度を集計しています…")
        case .finished:
            if let report = diagnostic.report {
                reportView(report)
            }
        case let .failed(message):
            VStack(alignment: .leading, spacing: 10) {
                Label("診断を完了できませんでした", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(message)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("フォルダの準備")
                .font(.headline)
            Text("診断用フォルダの直下に人物ごとのフォルダを2つ以上作り、それぞれへ本人の画像を入れてください。各人物につき最大50枚をファイル名順に使用します。")
            Text("選択した場所、画像、顔特徴量、診断結果は保存しません。自動分類の基準に届かなくても設定は変更されません。")
                .foregroundStyle(.secondary)
            Label("同意を得た画像だけを使用してください。", systemImage: "hand.raised")
                .foregroundStyle(.secondary)
        }
    }

    private func running(_ message: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(message)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reportView(_ report: PeopleAccuracyReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 24) {
                    metric("人物", "\(report.labels.count)人")
                    metric("評価画像", "\(report.eligibleImageCount) / \(report.inputImageCount)")
                    metric("同一ペア", "\(report.samePersonPairCount)")
                    metric("別人物ペア", "\(report.differentPersonPairCount)")
                }

                if report.unreadableImageCount > 0 || report.noEligibleFaceCount > 0 {
                    Text("読み取れない画像 \(report.unreadableImageCount)件・評価できる顔がない画像 \(report.noEligibleFaceCount)件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("プリセット別の結果")
                    .font(.headline)
                ForEach(report.presets) { preset in
                    HStack(spacing: 14) {
                        Text(displayName(preset.sensitivity))
                            .frame(width: 54, alignment: .leading)
                        Text("精度 \(percent(preset.report.precision))")
                        Text("再現率 \(percent(preset.report.recall))")
                        Text("誤一致 \(preset.report.counts.falsePositive)件")
                        Text("境界付近 \(preset.ambiguousCount)件")
                        Spacer()
                        Label(
                            preset.meetsAutomaticClassificationGate ? "基準を満たす" : "実験的のまま",
                            systemImage: preset.meetsAutomaticClassificationGate
                                ? "checkmark.circle.fill" : "exclamationmark.circle"
                        )
                        .foregroundStyle(preset.meetsAutomaticClassificationGate ? .green : .secondary)
                    }
                    .font(.callout)
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }

                Text("判定基準は、2人以上・同一人物と別人物の両方のペアがあり、誤一致を含む精度が99%以上であることです。診断結果だけで自動分類を有効にはしません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                DisclosureGroup("閾値ごとの詳細") {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                        GridRow {
                            Text("閾値"); Text("精度"); Text("再現率"); Text("誤一致"); Text("見逃し")
                        }
                        .font(.caption.weight(.semibold))
                        ForEach(Array(report.thresholdTable.enumerated()), id: \.offset) { _, row in
                            GridRow {
                                Text(String(format: "%.2f", row.threshold))
                                Text(percent(row.precision))
                                Text(percent(row.recall))
                                Text("\(row.counts.falsePositive)")
                                Text("\(row.counts.falseNegative)")
                            }
                            .monospacedDigit()
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
    }

    private func percent(_ value: Double?) -> String {
        value.map { String(format: "%.1f%%", $0 * 100) } ?? "—"
    }

    private func displayName(_ sensitivity: FaceGroupingSensitivity) -> String {
        switch sensitivity {
        case .strict: "厳密"
        case .standard: "標準"
        case .broad: "広め"
        }
    }
}
#endif
