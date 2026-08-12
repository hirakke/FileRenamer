import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Shared thumbnail cache.
///
/// QuickLook renders previews for photos (including RAW) *and* documents, so one
/// code path covers the whole "any file type" requirement. If it has nothing to
/// offer we fall back to the Finder icon.
actor ThumbnailProvider {
    static let shared = ThumbnailProvider()

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 600
        cache.totalCostLimit = 256 * 1024 * 1024
        return cache
    }()
    private var inFlight: [String: Task<NSImage, Never>] = [:]

    func thumbnail(for url: URL, size: CGFloat, scale: CGFloat) async -> NSImage? {
        let key = "\(url.standardizedFileURL.path)|\(Int(size))|\(Int(scale * 10))"
        if let cached = cache.object(forKey: key as NSString) { return cached }
        if let pending = inFlight[key] { return await pending.value }

        let task = Task<NSImage, Never> {
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: size, height: size),
                scale: scale,
                representationTypes: .all
            )
            if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                return NSImage(cgImage: representation.cgImage, size: representation.contentRect.size)
            }
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil

        let pixelCost = max(1, Int(size * scale)) * max(1, Int(size * scale)) * 4
        cache.setObject(image, forKey: key as NSString, cost: pixelCost)
        return image
    }
}

/// Async thumbnail with an immediate Finder-icon placeholder, so scrolling a large
/// import never shows empty boxes.
struct ThumbnailView: View {
    let url: URL
    var size: CGFloat

    @State private var image: NSImage?

    /// Two cache sizes cover the list and grid. Slider movement now scales an
    /// existing grid thumbnail instead of launching a new Quick Look job per tick.
    private var requestSize: CGFloat { size <= 64 ? 64 : 320 }
    private var requestID: String {
        "\(url.standardizedFileURL.path)|\(Int(requestSize))"
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                    .overlay(Image(systemName: "doc").foregroundStyle(.tertiary))
            }
        }
        .frame(width: size, height: size)
        // An opaque substrate keeps transparent PNGs and document previews from
        // visually dissolving into the window glass.
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.7)
        }
        .task(id: requestID) {
            image = nil
            image = await ThumbnailProvider.shared.thumbnail(for: url, size: requestSize, scale: 2)
        }
    }
}

/// Observes the trackpad's second pressure stage without taking mouse events away
/// from SwiftUI. Ordinary click selection and drag-to-reorder therefore keep working.
struct ForceClickReader: NSViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryDeepClick)
        context.coordinator.trackedView = view
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.action = action
        context.coordinator.trackedView = nsView
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    final class Coordinator {
        var action: () -> Void
        weak var trackedView: NSView?
        private var monitor: Any?
        private var didTrigger = false

        init(action: @escaping () -> Void) {
            self.action = action
        }

        func startMonitoring() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .pressure) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) {
            guard let view = trackedView,
                  event.window === view.window
            else { return }

            if event.stage == 0 {
                didTrigger = false
                return
            }

            let point = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(point), event.stage >= 2, !didTrigger else { return }
            didTrigger = true
            action()
        }
    }
}

extension View {
    func onForceClick(perform action: @escaping () -> Void) -> some View {
        background(ForceClickReader(action: action))
    }
}
