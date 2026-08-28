import CoreGraphics
import Foundation
import ImageIO

enum FaceImageLoaderError: LocalizedError {
    case cannotOpen(URL)
    case cannotDecode(URL)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let url), .cannotDecode(let url):
            return "「\(url.lastPathComponent)」の顔解析用画像を読み取れませんでした。"
        }
    }
}

/// Loads an orientation-applied image while balancing security-scoped access.
enum FaceImageLoader {
    static func loadOrientedImage(
        at url: URL,
        maximumPixelSize: Int = 4_096
    ) throws -> CGImage {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw FaceImageLoaderError.cannotOpen(url)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(112, maximumPixelSize),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            throw FaceImageLoaderError.cannotDecode(url)
        }
        return image
    }
}
