import Foundation

/// File-name rules for macOS/HFS+/APFS.
///
/// `/` and NUL are the only bytes the kernel truly rejects, but `:` is the classic
/// HFS path separator and still shows up as `/` in Finder, so we treat it as illegal
/// too. C0/C1 control characters (newline, tab, …) are accepted by the kernel but
/// produce names that cannot be typed, displayed or safely used in a shell, so they
/// are rejected as well. Everything else is allowed — we only warn.
public enum FileNameSanitizer {
    /// Only general category Cc. Format characters such as U+200D ZERO WIDTH JOINER
    /// are deliberately excluded: they are part of ordinary emoji sequences.
    public static let controlCharacters: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: Unicode.Scalar(0x00)!...Unicode.Scalar(0x1F)!)
        set.insert(charactersIn: Unicode.Scalar(0x7F)!...Unicode.Scalar(0x9F)!)
        return set
    }()
    public static let illegalCharacters = CharacterSet(charactersIn: "/:").union(controlCharacters)
    /// Not illegal, but they make the name painful in a shell or on another platform.
    public static let discouragedCharacters = CharacterSet(charactersIn: "\\?%*|\"<>")

    /// Max length of a single path component on APFS, in UTF-8 bytes.
    public static let maximumNameLength = 255

    public static func containsIllegalCharacters(_ name: String) -> Bool {
        name.rangeOfCharacter(from: illegalCharacters) != nil
    }

    public static func containsDiscouragedCharacters(_ name: String) -> Bool {
        name.rangeOfCharacter(from: discouragedCharacters) != nil
    }

    public static func sanitize(_ name: String, replacement: String = "-") -> String {
        guard containsIllegalCharacters(name) else { return name }
        return name.components(separatedBy: illegalCharacters).joined(separator: replacement)
    }

    /// A name that is empty, all dots, or starts with a dot is a problem: `.` and `..`
    /// are directory entries and a leading dot hides the file in Finder.
    public static func isReservedName(_ name: String) -> Bool {
        name.isEmpty || isDotsOnly(name)
    }

    public static func isDotsOnly(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0 == "." }
    }

    public static func byteLength(_ name: String) -> Int {
        name.utf8.count
    }
}
