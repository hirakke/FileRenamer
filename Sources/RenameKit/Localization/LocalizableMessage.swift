import Foundation

/// User-facing text produced by RenameKit.
///
/// RenameKit owns no string resources, so it hands the app a stable catalog key,
/// the English source text and the values to substitute. The app resolves the
/// message in the selected display language right before showing it. File names
/// and system-provided error text travel as `.text` arguments and are never
/// translated.
public struct LocalizableMessage: Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public enum Argument: Hashable, Sendable {
        case text(String)
        case number(Int)
        case message(LocalizableMessage)

        /// A failure as an argument: RenameKit errors stay translatable, anything
        /// else keeps the description macOS provided.
        public static func error(_ error: Error) -> Argument {
            .message(LocalizableMessage.describing(error))
        }
    }

    /// Empty for verbatim text that must not be looked up.
    public let key: String
    public let defaultValue: String
    public let arguments: [Argument]

    public init(_ key: String, defaultValue: String, arguments: [Argument] = []) {
        self.key = key
        self.defaultValue = defaultValue
        self.arguments = arguments
    }

    public init(stringLiteral value: String) {
        self.init(verbatim: value)
    }

    public init(verbatim text: String) {
        self.init("", defaultValue: text)
    }

    public static func describing(_ error: Error) -> LocalizableMessage {
        if let error = error as? LocalizableError { return error.localizableMessage }
        return LocalizableMessage(verbatim: error.localizedDescription)
    }

    /// - Parameter lookup: returns the translated format for a key, or the
    ///   supplied English default when the key is unknown.
    public func resolved(
        locale: Locale,
        lookup: (_ key: String, _ defaultValue: String) -> String
    ) -> String {
        guard !key.isEmpty else { return defaultValue }
        let format = lookup(key, defaultValue)
        guard !arguments.isEmpty else { return format }
        let values: [CVarArg] = arguments.map { argument in
            switch argument {
            case .text(let text): return text
            case .number(let number): return number
            case .message(let message): return message.resolved(locale: locale, lookup: lookup)
            }
        }
        return String(format: format, locale: locale, arguments: values)
    }

    /// The English source text, for logs and non-UI consumers.
    public var description: String {
        resolved(locale: Locale(identifier: "en_US_POSIX")) { _, defaultValue in defaultValue }
    }
}

/// An error whose description the app can show in the selected display language.
public protocol LocalizableError: LocalizedError {
    var localizableMessage: LocalizableMessage { get }
}

public extension LocalizableError {
    var errorDescription: String? { localizableMessage.description }
}
