import Foundation
import RenameKit

/// Resolves app-owned strings against the language selected in FileRenamer's
/// settings. File names and other user data must never be passed through here.
enum L10n {
    static func string(
        _ key: String,
        defaultValue: String,
        language: ResolvedAppLanguage
    ) -> String {
        localizedBundle(for: language).localizedString(
            forKey: key,
            value: defaultValue,
            table: "Localizable"
        )
    }

    static func format(
        _ key: String,
        defaultValue: String,
        arguments: [CVarArg],
        language: ResolvedAppLanguage
    ) -> String {
        let format = string(key, defaultValue: defaultValue, language: language)
        return String(
            format: format,
            locale: Locale(identifier: language.localeIdentifier),
            arguments: arguments
        )
    }

    private static func localizedBundle(for language: ResolvedAppLanguage) -> Bundle {
        guard let path = Bundle.main.path(forResource: language.localeIdentifier, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return Bundle.main
        }
        return bundle
    }
}

extension AppLanguage {
    func localizedDisplayName(in language: ResolvedAppLanguage) -> String {
        switch self {
        case .system:
            return L10n.string("settings.language.system", defaultValue: "Use System Setting", language: language)
        case .japanese:
            return L10n.string("settings.language.japanese", defaultValue: "Japanese", language: language)
        case .english:
            return "English"
        }
    }
}

extension ViewMode {
    func localizedDisplayName(in language: ResolvedAppLanguage) -> String {
        switch self {
        case .list:
            return L10n.string("view.list", defaultValue: "List", language: language)
        case .grid:
            return L10n.string("view.grid", defaultValue: "Grid", language: language)
        }
    }
}

extension SimilarImageSensitivity {
    func localizedDisplayName(in language: ResolvedAppLanguage) -> String {
        switch self {
        case .strict:
            return L10n.string("similarity.strict", defaultValue: "Strict", language: language)
        case .standard:
            return L10n.string("similarity.standard", defaultValue: "Standard", language: language)
        case .broad:
            return L10n.string("similarity.broad", defaultValue: "Broad", language: language)
        }
    }
}

extension SortField {
    func localizedDisplayName(in language: ResolvedAppLanguage) -> String {
        switch self {
        case .fileName:
            return L10n.string("sort.fileName", defaultValue: "Name", language: language)
        case .creationDate:
            return L10n.string("sort.creationDate", defaultValue: "Date Created", language: language)
        case .modificationDate:
            return L10n.string("sort.modificationDate", defaultValue: "Date Modified", language: language)
        case .fileSize:
            return L10n.string("sort.fileSize", defaultValue: "Size", language: language)
        case .captureDate:
            return L10n.string("sort.captureDate", defaultValue: "Date Taken", language: language)
        }
    }
}
