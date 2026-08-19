import SwiftUI
import AppKit

/// Window-wide native blur. It keeps text fully opaque while letting the desktop
/// subtly show through the empty surfaces and title bar.
struct TranslucentWindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = WindowEffectView()
        // Popover material has a brighter, more refractive character than the
        // neutral-grey sidebar material while retaining native desktop blur.
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        (nsView as? WindowEffectView)?.configureWindowIfNeeded()
        nsView.needsDisplay = true
    }

    private final class WindowEffectView: NSVisualEffectView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindowIfNeeded()
        }

        func configureWindowIfNeeded() {
            guard let window else { return }
            window.isOpaque = false
            // Never fade the whole NSWindow: that would also wash out text,
            // thumbnails and controls. Only the backdrop is translucent.
            window.alphaValue = 1
            window.backgroundColor = .clear
            // The dynamic directory title is owned by `PlainWindowTitle`. A
            // principal ToolbarItem would make macOS 26 wrap even plain text in an
            // automatic Liquid Glass capsule.
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.toolbarStyle = .unified
            window.toolbar?.showsBaselineSeparator = false
            window.styleMask.insert(.fullSizeContentView)

            // SwiftUI's hosting view otherwise retains the standard opaque
            // window fill even when NSWindow itself has a clear background.
            window.contentView?.wantsLayer = true
            window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

/// Writes to NSWindow's standard title field, which remains ordinary text instead
/// of becoming a Liquid Glass toolbar control on macOS 26.
struct PlainWindowTitle: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> TitleBridgeView {
        let view = TitleBridgeView()
        view.title = title
        return view
    }

    func updateNSView(_ nsView: TitleBridgeView, context: Context) {
        nsView.title = title
        nsView.applyTitle()
    }

    final class TitleBridgeView: NSView {
        var title = ""

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyTitle()
        }

        func applyTitle() {
            guard let window else { return }
            window.title = title
            window.titleVisibility = title.isEmpty ? .hidden : .visible
            // A represented URL adds a proxy icon; keep this title text-only.
            window.representedURL = nil
        }
    }
}

/// Cool highlights over the native blur keep the backdrop reading as glass rather
/// than a flat grey sheet. Foreground panels remain independently opaque.
struct GlassWindowBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            TranslucentWindowBackground()

            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.10 : 0.24),
                    Color.cyan.opacity(colorScheme == .dark ? 0.08 : 0.10),
                    Color.blue.opacity(colorScheme == .dark ? 0.06 : 0.045),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [Color.white.opacity(colorScheme == .dark ? 0.08 : 0.18), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 520
            )
        }
    }
}

/// Liquid Glass surfaces, with a material fallback on older systems.
///
/// The app targets macOS 14, so `glassEffect` is applied only where it exists; below
/// that the same shapes get a translucent material and a hairline edge, which reads
/// the same way without the refraction.
extension View {
    func liquidGlass(
        tint: Color? = nil,
        cornerRadius: CGFloat = 10,
        interactive: Bool = false
    ) -> some View {
        modifier(LiquidGlassBackground(tint: tint, cornerRadius: cornerRadius, interactive: interactive))
    }

    /// High-opacity work surface placed above the glass window backdrop.
    func workSurface(opacity: Double = 0.94) -> some View {
        background {
            Color(nsColor: .controlBackgroundColor)
                .opacity(opacity)
        }
    }

    /// A borderless raised panel: a soft top highlight and lower ambient shadow
    /// describe its depth without drawing a flat rectangular outline.
    func raisedWorkSurface(opacity: Double = 0.97) -> some View {
        background {
            ZStack {
                Color(nsColor: .controlBackgroundColor).opacity(opacity)
                LinearGradient(
                    colors: [Color.white.opacity(0.16), Color.clear],
                    startPoint: .top,
                    endPoint: .center
                )
            }
        }
        .shadow(color: Color.white.opacity(0.50), radius: 1.2, y: -1)
    }
}

struct LiquidGlassBackground: ViewModifier {
    let tint: Color?
    let cornerRadius: CGFloat
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(glass, in: .rect(cornerRadius: cornerRadius, style: .continuous))
        } else {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            content
                .background {
                    shape.fill(.regularMaterial)
                    if let tint {
                        shape.fill(tint.opacity(0.18))
                    }
                }
                .overlay {
                    shape.strokeBorder((tint ?? .primary).opacity(0.18), lineWidth: 0.8)
                }
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}
