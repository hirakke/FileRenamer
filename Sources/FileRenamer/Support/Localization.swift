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

extension CaseTransform {
    func localizedDisplayName(in language: ResolvedAppLanguage) -> String {
        switch self {
        case .none:
            return L10n.string("caseTransform.none", defaultValue: "Keep", language: language)
        case .lowercase:
            return L10n.string("caseTransform.lowercase", defaultValue: "Lowercase", language: language)
        case .uppercase:
            return L10n.string("caseTransform.uppercase", defaultValue: "Uppercase", language: language)
        }
    }
}

extension ImageOutputFormat {
    func localizedDisplayName(in language: ResolvedAppLanguage) -> String {
        switch self {
        case .preserve:
            return L10n.string("imageFormat.preserve", defaultValue: "Keep Original", language: language)
        case .jpeg:
            return "JPEG"
        case .png:
            return "PNG"
        }
    }
}

extension JPEGQualityPreset {
    func localizedDisplayName(in language: ResolvedAppLanguage) -> String {
        switch self {
        case .maximum:
            return L10n.string("jpegQuality.maximum", defaultValue: "Maximum — 100%", language: language)
        case .high:
            return L10n.string("jpegQuality.high", defaultValue: "High — 95% (Recommended)", language: language)
        case .standard:
            return L10n.string("jpegQuality.standard", defaultValue: "Standard — 90%", language: language)
        case .compact:
            return L10n.string("jpegQuality.compact", defaultValue: "Compact — 80%", language: language)
        case .custom:
            return L10n.string("jpegQuality.custom", defaultValue: "Custom", language: language)
        }
    }
}
