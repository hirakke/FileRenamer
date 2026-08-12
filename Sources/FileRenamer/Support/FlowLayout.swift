import SwiftUI

/// Left-to-right flow that wraps onto new lines.
///
/// The rule field behaves like a text field: blocks fill the width and spill onto the
/// next line rather than scrolling sideways, so a long rule is readable at a glance.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        arrange(subviews: subviews, maxWidth: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let result = arrange(subviews: subviews, maxWidth: bounds.width)
        for (index, subview) in subviews.enumerated() {
            let origin = result.positions[index]
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                anchor: .topLeading,
                proposal: .unspecified
            )
        }
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> (positions: [CGPoint], size: CGSize) {
        var positions: [CGPoint] = []
        var lineRanges: [(start: Int, height: CGFloat, top: CGFloat)] = []

        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var lineStart = 0
        var widest: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            // Never wrap the first item on a line: a block wider than the field still
            // has to go somewhere.
            if x > 0, x + size.width > maxWidth {
                lineRanges.append((lineStart, lineHeight, y))
                lineStart = index
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: x, y: size.height))  // height parked here for now
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        lineRanges.append((lineStart, lineHeight, y))

        // Items on a line are centred against the tallest one, so a typed run sits on
        // the same optical line as a block twice its height.
        for line in lineRanges {
            let end = lineRanges.first { $0.start > line.start }?.start ?? positions.count
            for index in line.start..<end {
                let ownHeight = positions[index].y
                positions[index].y = line.top + (line.height - ownHeight) / 2
            }
        }

        return (positions, CGSize(width: widest, height: y + lineHeight))
    }
}
