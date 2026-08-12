import Foundation
import UniformTypeIdentifiers

/// Extension classification. The app deliberately accepts *any* file type — this is
/// only used to pick a group's primary file, to decide whether EXIF is worth reading,
/// and to show the right placeholder.
public enum FileKinds {
    public static let rawExtensions: Set<String> = [
        "raf", "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2",
        "dng", "orf", "rw2", "pef", "raw", "3fr", "fff", "iiq",
        "erf", "mos", "mrw", "x3f", "gpr"
    ]

    public static let jpegExtensions: Set<String> = ["jpg", "jpeg", "jpe"]

    public static let otherImageExtensions: Set<String> = [
        "heic", "heif", "png", "tif", "tiff", "gif", "bmp", "webp", "avif", "psd"
    ]

    public static let sidecarExtensions: Set<String> = ["xmp", "aae", "thm", "pp3", "on1", "dop"]

    public static func isRAW(_ url: URL) -> Bool {
        rawExtensions.contains(url.pathExtension.lowercased())
    }

    public static func isSidecar(_ url: URL) -> Bool {
        sidecarExtensions.contains(url.pathExtension.lowercased())
    }

    /// File types that can legitimately be part of a photo companion set. Keep this
    /// extension-based so an unrelated document sharing the same base name is never
    /// swept into a RAW/JPEG group through a broad UTType conformance.
    public static func isCompanionImage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return rawExtensions.contains(ext)
            || jpegExtensions.contains(ext)
            || otherImageExtensions.contains(ext)
    }

    /// Worth handing to ImageIO. Extension-based first, UTType as a fallback.
    public static func isImage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if rawExtensions.contains(ext) || jpegExtensions.contains(ext) || otherImageExtensions.contains(ext) {
            return true
        }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }

    /// Lower sorts first when choosing which file in a RAW+JPEG group is the primary.
    /// RAW wins: it is the negative, the JPEG is the derivative.
    public static func groupPriority(_ url: URL) -> Int {
        let ext = url.pathExtension.lowercased()
        if rawExtensions.contains(ext) { return 0 }
        if otherImageExtensions.contains(ext) { return 1 }
        if jpegExtensions.contains(ext) { return 2 }
        if sidecarExtensions.contains(ext) { return 4 }
        return 3
    }

    /// Files that should never end up in the list.
    public static func isSystemNoise(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name == ".DS_Store" || name == "Icon\r" || name == ".localized"
    }
}
