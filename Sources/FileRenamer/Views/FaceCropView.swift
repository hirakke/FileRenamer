import AppKit
import RenameKit
import SwiftUI

private actor FaceCropProvider {
    static let shared = FaceCropProvider()

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    func crop(
        at url: URL,
        normalizedBoundingBox: CGRect,
        size: CGFloat
    ) -> NSImage? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let values = try? url.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        )
        let key = [
            url.standardizedFileURL.path,
            String(values?.fileSize ?? 0),
            String(Int((values?.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1_000)),
            NSStringFromRect(normalizedBoundingBox),
            String(Int(size))
        ].joined(separator: "|")
        if let cached = cache.object(forKey: key as NSString) { return cached }

        guard let image = try? FaceImageLoader.loadOrientedImage(at: url),
              let cropped = makeCrop(image, normalizedBoundingBox: normalizedBoundingBox)
        else { return nil }
        let result = NSImage(cgImage: cropped, size: CGSize(width: size, height: size))
        cache.setObject(
            result,
            forKey: key as NSString,
            cost: max(1, Int(size * size * 4))
        )
        return result
    }

    private func makeCrop(
        _ image: CGImage,
        normalizedBoundingBox: CGRect
    ) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let faceRect = FaceGeometry.imageRect(
            normalizedVisionRect: normalizedBoundingBox,
            imageSize: bounds.size
        )
        let crop = FaceGeometry.fallbackCrop(
            faceRect: faceRect,
            imageBounds: bounds,
            scale: 1.5
        )
        guard !crop.isNull else { return nil }
        return image.cropping(to: crop)
    }
}

struct FaceCropView: View {
    let url: URL
    let normalizedBoundingBox: CGRect
    var size: CGFloat = 128

    @State private var image: NSImage?

    private var requestID: String {
        "\(url.standardizedFileURL.path)|\(NSStringFromRect(normalizedBoundingBox))|\(Int(size))"
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.10))
                    .overlay(Image(systemName: "person.crop.rectangle").foregroundStyle(.tertiary))
            }
        }
        .frame(width: size, height: size)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.7)
        }
        .task(id: requestID) {
            image = nil
            let requestedID = requestID
            let result = await FaceCropProvider.shared.crop(
                at: url,
                normalizedBoundingBox: normalizedBoundingBox,
                size: size
            )
            guard !Task.isCancelled, requestedID == requestID else { return }
            image = result
        }
    }
}
