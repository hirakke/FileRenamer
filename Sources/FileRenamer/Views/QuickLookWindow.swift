import SwiftUI
import AppKit
import QuickLookUI
import RenameKit

/// Owns one non-modal AppKit window, independent from the main SwiftUI window.
/// Repeated force-clicks replace its item instead of creating extra windows.
@MainActor
final class QuickLookWindowController: NSObject, ObservableObject, NSWindowDelegate {
    private var window: NSWindow?
    private var hostingController: NSHostingController<StandaloneQuickLookContent>?
    private var closeHandler: (() -> Void)?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    func update(url: URL?, onClose: @escaping () -> Void) {
        guard let url else {
            close(notify: false)
            return
        }

        closeHandler = onClose
        let content = StandaloneQuickLookContent(url: url) { [weak self] in
            self?.window?.performClose(nil)
        }

        if let window, let hostingController {
            hostingController.rootView = content
            window.title = url.lastPathComponent
            window.representedURL = url
            attachToPresentingWindowIfNeeded(window)
            startOutsideClickMonitoring(for: window)
            present(window)
            return
        }

        let hostingController = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = url.lastPathComponent
        window.representedURL = url
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 480)
        // A preview opened from a full-screen main window must join that Space as
        // an auxiliary window. Treating it as another full-screen primary window
        // leaves AppKit to manage two independent full-screen sessions, which can
        // make closing the preview destabilize the original window.
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.delegate = self

        // Keep a real, separate preview window, but attach it to the main window
        // while presented. This gives it the correct full-screen lifetime and keeps
        // it in front without relying on a floating window level.
        attachToPresentingWindowIfNeeded(window)

        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let width = min(max(visibleFrame.width * 0.72, 760), 1320)
        let height = min(max(visibleFrame.height * 0.78, 560), 980)
        window.setContentSize(NSSize(width: width, height: height))
        window.center()

        self.hostingController = hostingController
        self.window = window
        startOutsideClickMonitoring(for: window)
        present(window)
    }

    func close(notify: Bool) {
        guard let window else { return }
        stopOutsideClickMonitoring()
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)

        let handler = notify ? closeHandler : nil
        closeHandler = nil
        if let handler {
            DispatchQueue.main.async {
                handler()
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Keep the native QLPreviewView alive and reuse it. Destroying it on every
        // outside click terminates Quick Look's remote view service and produces
        // ViewBridge Code 18 / task-port diagnostics in Xcode.
        close(notify: true)
        return false
    }

    private func present(_ window: NSWindow) {
        // A force-click release can make the main window key again later in the
        // current event cycle. Presenting on the next cycle avoids that race, while
        // making the preview key on the next cycle avoids that race while its parent
        // relationship keeps it in the correct full-screen Space.
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// `close` intentionally keeps the Quick Look view alive, so reopening an
    /// existing preview must attach it again. At that point the main window is key;
    /// while an already-visible preview is updated it remains attached and is left
    /// alone.
    private func attachToPresentingWindowIfNeeded(_ previewWindow: NSWindow) {
        guard previewWindow.parent == nil,
              let presentingWindow = NSApp.keyWindow,
              presentingWindow !== previewWindow
        else { return }

        presentingWindow.addChildWindow(previewWindow, ordered: .above)
    }

    private func startOutsideClickMonitoring(for previewWindow: NSWindow) {
        stopOutsideClickMonitoring()

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self, weak previewWindow] event in
            if let previewWindow, event.window !== previewWindow {
                self?.close(notify: true)
            }
            return event
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            self?.close(notify: true)
        }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.close(notify: true)
            }
        }
    }

    private func stopOutsideClickMonitoring() {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        localMouseMonitor = nil
        globalMouseMonitor = nil
        resignObserver = nil
    }
}

private struct StandaloneQuickLookContent: View {
    let url: URL
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            EmbeddedQuickLookView(url: url)
                .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)

                Text(url.lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button("Finderで表示") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }

                Button("閉じる", action: dismiss)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(.bar)
        }
        .frame(minWidth: 640, minHeight: 480)
        .onExitCommand(perform: dismiss)
    }
}

private struct EmbeddedQuickLookView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.shouldCloseWithWindow = false
        view.setAccessibilityLabel(L10n.string(
            "クイックルックプレビュー",
            defaultValue: "Quick Look Preview",
            language: ResolvedAppLanguage(locale: context.environment.locale)
        ))
        context.coordinator.update(url: url, previewView: view)
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        context.coordinator.update(url: url, previewView: nsView)
    }

    static func dismantleNSView(_ nsView: QLPreviewView, coordinator: Coordinator) {
        nsView.previewItem = nil
        coordinator.stopAccessing()
        // Do not call QLPreviewView.close() here. AppKit owns the final teardown;
        // explicitly closing during SwiftUI dismantling races its RemoteViewService.
    }

    final class Coordinator {
        private var currentURL: URL?
        private var isAccessing = false

        func update(url: URL, previewView: QLPreviewView) {
            guard currentURL != url else { return }
            stopAccessing()
            currentURL = url
            isAccessing = url.startAccessingSecurityScopedResource()
            // QLPreviewView uses the system Quick Look generator, so PDF pages,
            // images, video, audio and supported documents share one native view.
            previewView.previewItem = nil
            previewView.previewItem = url as NSURL
            previewView.refreshPreviewItem()
        }

        func stopAccessing() {
            if isAccessing { currentURL?.stopAccessingSecurityScopedResource() }
            isAccessing = false
            currentURL = nil
        }
    }
}
