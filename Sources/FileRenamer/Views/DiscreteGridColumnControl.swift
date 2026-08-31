import SwiftUI

struct DiscreteGridColumnControl: View {
    @Binding var columnCount: Int
    let range: ClosedRange<Int>

    private var choices: [Int] { Array(range) }

    var body: some View {
        HStack(spacing: 10) {
            Spacer()
            Text("横の列数")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 1) {
                Slider(value: sliderValue, in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
                    .accessibilityLabel("横の列数")
                    .accessibilityValue("\(columnCount)列")

                HStack(spacing: 0) {
                    ForEach(choices, id: \.self) { count in
                        Text("\(count)")
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(count == columnCount ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(width: 210)

            Text("\(columnCount)列")
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .frame(width: 30, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .workSurface(opacity: 0.96)
    }

    private var sliderValue: Binding<Double> {
        Binding(
            get: { Double(columnCount) },
            set: { value in
                columnCount = min(max(Int(value.rounded()), range.lowerBound), range.upperBound)
            }
        )
    }
}
