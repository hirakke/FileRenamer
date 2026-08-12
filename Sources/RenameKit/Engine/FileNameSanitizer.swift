import Foundation

/// File-name rules for macOS/HFS+/APFS.
///
/// `/` and NUL are the only bytes the kernel truly rejects, but `:` is the classic
/// HFS path separator and still shows up as `/` in Finder, so we treat it as illegal
/// too. Everything else is allowed — we only warn.
public enum FileNameSanitizer {
    public static let illegalCharacters = CharacterSet(charactersIn: "/:\0")
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
        name.isEmpty || name.allSatisfy { $0 == "." }
    }

    public static func byteLength(_ name: String) -> Int {
        name.utf8.count
    }
}
