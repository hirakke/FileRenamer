import AppKit
import SwiftUI

/// Direct control over a scroll offset for grid drag auto-scrolling.
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

/// Auto-scroll while a drag is in progress.
///
/// A grid drag can only reach what is on screen, so holding a cell near the top or
/// bottom edge has to scroll the view under it — otherwise moving a photo past the
/// visible page means dropping, scrolling, and picking it up again.
///
/// AppKit does this for `NSTableView` drags but not for a SwiftUI `LazyVGrid`, and
/// SwiftUI's drop callbacks only fire while the pointer is over a drop target, so the
/// edges are polled instead: the pointer position comes from `NSEvent`, and the loop
/// ends by itself when the mouse button comes back up.
@MainActor
final class DragAutoScroller {
    let controller = ListScrollController()
    /// Called once the mouse button is released, including when the drag was
    /// abandoned outside the window — SwiftUI reports nothing in that case.
    var onDragEnded: (() -> Void)?

    /// How close to an edge the pointer has to be, and how fast it then scrolls.
    private let edgeZone: CGFloat = 72
    private let maximumSpeed: CGFloat = 22
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self else { return }
                guard NSEvent.pressedMouseButtons != 0 else {
                    self.finish()
                    return
                }
                self.step()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func finish() {
        stop()
        onDragEnded?()
    }

    private func step() {
        guard let scrollView = controller.scrollView,
              let window = scrollView.window
        else { return }

        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let local = scrollView.convert(windowPoint, from: nil)
        let bounds = scrollView.bounds
        guard bounds.height > edgeZone * 2,
              local.x >= bounds.minX, local.x <= bounds.maxX,
              local.y >= bounds.minY, local.y <= bounds.maxY
        else { return }

        // An NSScrollView is not flipped by default, so "near the top" is the far end
        // of its own y axis; check the flag rather than assuming either way.
        let distanceFromTop = scrollView.isFlipped ? local.y - bounds.minY : bounds.maxY - local.y
        let distanceFromBottom = bounds.height - distanceFromTop

        if distanceFromTop < edgeZone {
            controller.scroll(by: -speed(forDistance: distanceFromTop))
        } else if distanceFromBottom < edgeZone {
            controller.scroll(by: speed(forDistance: distanceFromBottom))
        }
    }

    /// Accelerates as the pointer pushes further into the edge, so a small nudge
    /// creeps and pinning to the very edge moves quickly.
    private func speed(forDistance distance: CGFloat) -> CGFloat {
        let depth = min(max((edgeZone - distance) / edgeZone, 0), 1)
        return maximumSpeed * depth * depth
    }
}
