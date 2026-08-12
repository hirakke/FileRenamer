import AppKit
import SwiftUI

/// Direct control over the list's scroll offset.
///
/// `ScrollViewReader.scrollTo(_:anchor:)` is not usable for pinning a row under the
/// pointer: on a `List` it collapses to "scroll just enough to make the row visible"
/// and ignores a fractional anchor, so the row drifts away from the cursor and then
/// jumps when it reaches an edge. Moving the clip view by an exact number of points
/// is unambiguous, and it is what "the row stays still and the list slides" actually
/// means.
@MainActor
final class ListScrollController {
    weak var scrollView: NSScrollView?

    /// Positive `dy` scrolls the content up (the viewport moves down the document).
    func scroll(by dy: CGFloat) {
        guard let scrollView, dy != 0 else { return }
        let clipView = scrollView.contentView

        var origin = clipView.bounds.origin
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        let maximumY = max(documentHeight - clipView.bounds.height, 0)
        origin.y = min(max(origin.y + dy, 0), maximumY)

        guard origin != clipView.bounds.origin else { return }
        clipView.scroll(to: origin)
        scrollView.reflectScrolledClipView(clipView)
    }
}

/// Finds the `NSScrollView` a SwiftUI row lives in. Placed in a row background so it
/// is genuinely inside the scrolling hierarchy — a background on the `List` itself
/// would be a sibling of the scroll view, not a descendant.
struct EnclosingScrollViewProbe: NSViewRepresentable {
    let controller: ListScrollController

    func makeNSView(context: Context) -> NSView {
        ProbeView(controller: controller)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ProbeView: NSView {
        private let controller: ListScrollController

        init(controller: ListScrollController) {
            self.controller = controller
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let scrollView = enclosingScrollView else { return }
            MainActor.assumeIsolated { controller.scrollView = scrollView }
        }
    }
}

/// Last known on-screen frame of each row, in the list's coordinate space.
///
/// A plain class, deliberately not observable: it is written during layout and only
/// read at click time, so it must not invalidate any view.
@MainActor
final class RowGeometryStore {
    var frames: [UUID: CGRect] = [:]
}

/// Records one row's frame into the store as it scrolls.
struct RowFrameRecorder: View {
    let id: UUID
    let store: RowGeometryStore
    let coordinateSpace: String

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named(coordinateSpace))
            Color.clear
                .onChange(of: frame, initial: true) { _, newFrame in
                    store.frames[id] = newFrame
                }
        }
    }
}
