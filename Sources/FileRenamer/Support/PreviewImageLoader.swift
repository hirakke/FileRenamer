import AppKit
import ImageIO
import SwiftUI

/// Loads display-sized images for the duplicate comparison view.
///
/// `ThumbnailView` deliberately caps its requests at 320 px so a list of hundreds of
/// rows stays cheap. Comparing two near-identical frames needs the opposite: enough
/// resolution to see the difference that made them two photos instead of one.
///
/// ImageIO downsamples while decoding, so a 60 MP RAW never becomes a 60 MP bitmap in
/// memory, and the EXIF orientation is applied during the decode rather than being
/// lost.
actor PreviewImageLoader {
    static let shared = PreviewImageLoader()

    private struct Key: Hashable {
        let path: String
        let maxPixelSize: Int
    }

    private var cache: [Key: NSImage] = [:]
    private var order: [Key] = []
    /// A comparison session moves between a handful of pictures at a time.
    private let limit = 12

    func image(for url: URL, maxPixelSize: Int) async -> NSImage? {
        let key = Key(path: url.standardizedFileURL.path, maxPixelSize: maxPixelSize)
        if let cached = cache[key] { return cached }

        let loaded = await Task.detached(priority: .userInitiated) {
            Self.decode(url: url, maxPixelSize: maxPixelSize)
        }.value
        guard let loaded else { return nil }

        cache[key] = loaded
        order.append(key)
        if order.count > limit {
            let evicted = order.removeFirst()
            cache.removeValue(forKey: evicted)
        }
        return loaded
    }

    private static func decode(url: URL, maxPixelSize: Int) -> NSImage? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

/// A large, aspect-fitted image with a placeholder while it decodes.
struct LargeImageView: View {
    let url: URL
    var maxPixelSize: Int = 2048

    @State private var image: NSImage?
    @State private var loadedPath: String?
    @State private var loadFailed = false
    @State private var retryToken = UUID()

    var body: some View {
        Group {
            if let image, loadedPath == url.standardizedFileURL.path {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if loadFailed {
                ContentUnavailableView {
                    Label("画像を読み込めませんでした", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("アクセス権または対応形式を確認してください。")
                } actions: {
                    Button("再試行") { retryToken = UUID() }
                }
            } else {
                ZStack {
                    Color(nsColor: .controlBackgroundColor)
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .task(id: "\(url.standardizedFileURL.path)|\(retryToken.uuidString)") {
            let requestedPath = url.standardizedFileURL.path
            image = nil
            loadedPath = nil
            loadFailed = false
            let loaded = await PreviewImageLoader.shared.image(for: url, maxPixelSize: maxPixelSize)
            // The view may have been handed a different picture while decoding.
            guard requestedPath == url.standardizedFileURL.path else { return }
            image = loaded
            loadedPath = loaded == nil ? nil : requestedPath
            loadFailed = loaded == nil
        }
    }
}
