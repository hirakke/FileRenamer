import SwiftUI
import RenameKit

/// Per-row buttons that move an item one position earlier or later.
///
/// Dragging is the headline interaction, but it is imprecise for a single-step
/// correction and awkward in a long scrolling list. These do the same thing to the
/// same ordering model — the number and the preview update identically.
///
/// The arrows follow the layout: ▲▼ in the list, ◀▶ in the grid, both meaning
/// "one position earlier / later".
struct OrderStepper: View {
    enum Axis {
        case vertical
        case horizontal
    }

    let id: UUID
    var axis: Axis = .vertical

    var body: some View {
        if axis == .vertical {
            VStack(spacing: 0) {
                OrderStepButton(id: id, delta: -1, axis: axis)
                OrderStepButton(id: id, delta: 1, axis: axis)
            }
        } else {
            HStack(spacing: 0) {
                OrderStepButton(id: id, delta: -1, axis: axis)
                OrderStepButton(id: id, delta: 1, axis: axis)
            }
        }
    }
}

/// One arrow. Also usable on its own, which the grid does so the number can sit
/// between the two arrows.
struct OrderStepButton: View {
    @EnvironmentObject private var model: AppModel
    let id: UUID
    let delta: Int
    var axis: OrderStepper.Axis = .vertical

    private var systemImage: String {
        switch (axis, delta < 0) {
        case (.vertical, true): return "chevron.up"
        case (.vertical, false): return "chevron.down"
        case (.horizontal, true): return "chevron.left"
        case (.horizontal, false): return "chevron.right"
        }
    }

    var body: some View {
        let enabled = model.canStepFromRow(id, by: delta)
        Button {
            model.stepFromRow(id, by: delta)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        // .borderless keeps the row's drag gesture from being swallowed by the button.
        .buttonStyle(.borderless)
        .foregroundStyle(tint(enabled: enabled))
        .disabled(!enabled)
        .help(delta < 0 ? "1つ前へ" : "1つ後ろへ")
        .accessibilityLabel(delta < 0 ? "1つ前へ移動" : "1つ後ろへ移動")
    }

    private func tint(enabled: Bool) -> Color {
        let isSelected = model.selection.contains(id)
        guard enabled else {
            return isSelected ? Color.white.opacity(0.45) : Color.secondary.opacity(0.35)
        }
        return isSelected ? .white : .secondary
    }
}
