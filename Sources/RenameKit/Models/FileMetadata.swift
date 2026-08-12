import Foundation

/// Metadata read from disk / EXIF. Every field is optional: a plain text file has
/// almost none of it, a RAW file has all of it. Naming tokens must degrade gracefully.
public struct FileMetadata: Hashable, Sendable, Codable {
    public var creationDate: Date?
    public var modificationDate: Date?
    public var fileSize: Int64?

    // Photo specific. Populated by `MetadataLoader` when the file is an image.
    public var captureDate: Date?
    public var cameraMake: String?
    public var cameraModel: String?
    public var lensModel: String?
    public var iso: Int?
    public var focalLength: Double?
    public var apertureFNumber: Double?
    public var exposureTime: Double?

    public var pixelWidth: Int?
    public var pixelHeight: Int?

    public init(
        creationDate: Date? = nil,
        modificationDate: Date? = nil,
        fileSize: Int64? = nil,
        captureDate: Date? = nil,
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        lensModel: String? = nil,
        iso: Int? = nil,
        focalLength: Double? = nil,
        apertureFNumber: Double? = nil,
        exposureTime: Double? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.fileSize = fileSize
        self.captureDate = captureDate
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.iso = iso
        self.focalLength = focalLength
        self.apertureFNumber = apertureFNumber
        self.exposureTime = exposureTime
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// True once anything beyond the basic filesystem attributes is known.
    public var hasPhotoMetadata: Bool { captureDate != nil || cameraModel != nil }

    /// Merges in fields that are still unknown. Used when a RAW file carries no EXIF
    /// but its JPEG sidecar does.
    public mutating func fillMissing(from other: FileMetadata) {
        captureDate = captureDate ?? other.captureDate
        cameraMake = cameraMake ?? other.cameraMake
        cameraModel = cameraModel ?? other.cameraModel
        lensModel = lensModel ?? other.lensModel
        iso = iso ?? other.iso
        focalLength = focalLength ?? other.focalLength
        apertureFNumber = apertureFNumber ?? other.apertureFNumber
        exposureTime = exposureTime ?? other.exposureTime
        pixelWidth = pixelWidth ?? other.pixelWidth
        pixelHeight = pixelHeight ?? other.pixelHeight
    }
}
