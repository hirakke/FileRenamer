import Foundation

public enum ResolvedAppLanguage: String, CaseIterable, Equatable, Sendable {
    case japanese
    case english

    public var localeIdentifier: String {
        switch self {
        case .japanese: "ja"
        case .english: "en"
        }
    }
}

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case japanese
    case english

    public var id: String { rawValue }

    public func resolved(preferredLanguageIdentifier: String) -> ResolvedAppLanguage {
        switch self {
        case .japanese:
            return .japanese
        case .english:
            return .english
        case .system:
            let languageCode = Locale(identifier: preferredLanguageIdentifier)
                .language
                .languageCode?
                .identifier
                .lowercased()
            return languageCode == "ja" ? .japanese : .english
        }
    }
}
