import Foundation
import ImageIO

/// Reads filesystem attributes and, for images, EXIF via ImageIO.
///
/// ImageIO opens RAW files (RAF/CR2/CR3/NEF/ARW/DNG/…) for metadata without decoding
/// them, which is exactly what we need: no RAW development, just the header.
public struct MetadataLoader: Sendable {
    public init() {}

    /// - Parameter urls: primary first. Fields missing on the primary are filled in
    ///   from the companions, so a RAW without EXIF borrows its JPEG's capture date.
    public func load(for urls: [URL]) -> FileMetadata {
        guard let primary = urls.first else { return FileMetadata() }
        var metadata = loadOne(primary)
        for companion in urls.dropFirst() where !metadata.hasPhotoMetadata {
            metadata.fillMissing(from: loadOne(companion))
        }
        return metadata
    }

    public func loadOne(_ url: URL) -> FileMetadata {
        var metadata = FileMetadata()
        loadFileAttributes(url, into: &metadata)
        if FileKinds.isImage(url) {
            loadImageProperties(url, into: &metadata)
        }
        return metadata
    }

    private func loadFileAttributes(_ url: URL, into metadata: inout FileMetadata) {
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return }
        metadata.creationDate = values.creationDate
        metadata.modificationDate = values.contentModificationDate
        metadata.fileSize = values.fileSize.map(Int64.init)
    }

    private func loadImageProperties(_ url: URL, into metadata: inout FileMetadata) {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return }

        metadata.pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int
        metadata.pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int

        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            metadata.cameraMake = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmed
            metadata.cameraModel = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmed
        }

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String
                ?? exif[kCGImagePropertyExifDateTimeDigitized] as? String
            metadata.captureDate = raw.flatMap(Self.parseEXIFDate)
            metadata.iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first
            metadata.focalLength = exif[kCGImagePropertyExifFocalLength] as? Double
            metadata.apertureFNumber = exif[kCGImagePropertyExifFNumber] as? Double
            metadata.exposureTime = exif[kCGImagePropertyExifExposureTime] as? Double
            metadata.lensModel = (exif[kCGImagePropertyExifLensModel] as? String)?.trimmed
        }

        if metadata.lensModel == nil,
           let exifAux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] {
            metadata.lensModel = (exifAux[kCGImagePropertyExifAuxLensModel] as? String)?.trimmed
        }
    }

    /// EXIF dates are `yyyy:MM:dd HH:mm:ss` in the camera's local time with no zone,
    /// so they are parsed as local time — the same way Photos and Finder show them.
    private static let exifFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    static func parseEXIFDate(_ string: String) -> Date? {
        exifFormatter.date(from: string)
    }
}

private extension String {
    var trimmed: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
