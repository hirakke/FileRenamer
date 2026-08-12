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
    /// Supplied by the list so it can pin the moved row under the pointer. When nil
    /// the button just asks the model to step, and scrolling is left alone.
    var onStep: ((UUID, Int) -> Void)?

    var body: some View {
        if axis == .vertical {
            VStack(spacing: 0) {
                OrderStepButton(id: id, delta: -1, axis: axis, onStep: onStep)
                OrderStepButton(id: id, delta: 1, axis: axis, onStep: onStep)
            }
        } else {
            HStack(spacing: 0) {
                OrderStepButton(id: id, delta: -1, axis: axis, onStep: onStep)
                OrderStepButton(id: id, delta: 1, axis: axis, onStep: onStep)
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
    var onStep: ((UUID, Int) -> Void)?

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
            if let onStep {
                onStep(id, delta)
            } else {
                model.stepFromRow(id, by: delta)
            }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        // .borderless keeps the row's drag gesture from being swallowed by the button.
        .buttonStyle(.borderless)
        .foregroundStyle(tint(enabled: enabled))
        .disabled(!enabled)
        .help(delta < 0 ? "1つ前へ（続けてクリックできます）" : "1つ後ろへ（続けてクリックできます）")
        .accessibilityLabel(delta < 0 ? "1つ前へ移動" : "1つ後ろへ移動")
    }

    /// While a row is grabbed, every stepper in the list drives *that* row, so the
    /// arrows are tinted to say so rather than looking like ordinary per-row buttons.
    private func tint(enabled: Bool) -> Color {
        guard enabled else { return .secondary.opacity(0.25) }
        return model.grabbedStepIDs == nil ? .secondary : Palette.accent
    }
}
