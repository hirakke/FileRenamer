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

extension CounterResetMode {
    func localizedDisplayName(in language: ResolvedAppLanguage) -> String {
        switch self {
        case .never:
            return L10n.string("counterReset.never", defaultValue: "Never", language: language)
        case .folder:
            return L10n.string("counterReset.folder", defaultValue: "Each Folder", language: language)
        case .day:
            return L10n.string("counterReset.day", defaultValue: "Each Date", language: language)
        }
    }
}

extension DateSource {
    func localizedDisplayName(in language: ResolvedAppLanguage) -> String {
        switch self {
        case .creation:
            return L10n.string("dateSource.creation", defaultValue: "Date Created", language: language)
        case .modification:
            return L10n.string("dateSource.modification", defaultValue: "Date Modified", language: language)
        case .capture:
            return L10n.string("dateSource.capture", defaultValue: "Date Taken", language: language)
        }
    }
}

extension MetadataField {
    func localizedDisplayName(in language: ResolvedAppLanguage) -> String {
        switch self {
        case .cameraModel:
            return L10n.string("metadata.cameraModel", defaultValue: "Camera Model", language: language)
        case .lensModel:
            return L10n.string("metadata.lensModel", defaultValue: "Lens", language: language)
        case .iso:
            return L10n.string("metadata.iso", defaultValue: "ISO", language: language)
        case .focalLength:
            return L10n.string("metadata.focalLength", defaultValue: "Focal Length", language: language)
        case .aperture:
            return L10n.string("metadata.aperture", defaultValue: "Aperture", language: language)
        case .dimensions:
            return L10n.string("metadata.dimensions", defaultValue: "Dimensions", language: language)
        }
    }
}

extension RenameToken {
    func localizedKindName(in language: ResolvedAppLanguage) -> String {
        switch self {
        case .text:
            return L10n.string("tokenKind.text", defaultValue: "Text", language: language)
        case .separator:
            return L10n.string("tokenKind.separator", defaultValue: "Separator", language: language)
        case .counter:
            return L10n.string("tokenKind.counter", defaultValue: "Counter", language: language)
        case .date:
            return L10n.string("tokenKind.date", defaultValue: "Date", language: language)
        case .originalName:
            return L10n.string("tokenKind.originalName", defaultValue: "Original Name", language: language)
        case .metadata:
            return L10n.string("tokenKind.metadata", defaultValue: "Photo Info", language: language)
        }
    }

    func localizedSummary(in language: ResolvedAppLanguage) -> String {
        switch self {
        case .text(let configuration):
            return configuration.value.isEmpty
                ? L10n.string("tokenSummary.empty", defaultValue: "(Empty)", language: language)
                : configuration.value
        case .separator(let configuration):
            return configuration.value == " " ? "space" : configuration.value
        case .counter(let configuration):
            return configuration.formatted(at: 0)
        case .date(let configuration):
            return "\(configuration.source.localizedDisplayName(in: language)) \(configuration.pattern.uppercased())"
        case .originalName(let configuration):
            let originalName = L10n.string("block.originalName", defaultValue: "Original Name", language: language)
            return configuration.transform == .none
                ? originalName
                : "\(originalName) (\(configuration.transform.localizedDisplayName(in: language)))"
        case .metadata(let configuration):
            return configuration.field.localizedDisplayName(in: language)
        }
    }
}

extension RenameRulePreset {
    func localizedDisplayName(in language: ResolvedAppLanguage) -> String {
        guard isBuiltIn else { return name }
        let keyAndDefault: (String, String)?
        switch name {
        case "01納品": keyAndDefault = ("preset.deliveryTwoDigits", "Delivery (01)")
        case "001納品": keyAndDefault = ("preset.deliveryThreeDigits", "Delivery (001)")
        case "日付 + イベント名 + 連番": keyAndDefault = ("preset.dateEventCounter", "Date + Event + Counter")
        case "イベント名 + 連番": keyAndDefault = ("preset.eventCounter", "Event + Counter")
        case "日付 + 連番": keyAndDefault = ("preset.dateCounter", "Date + Counter")
        case "連番のみ": keyAndDefault = ("preset.counterOnly", "Counter Only")
        case "元の名前 + 連番": keyAndDefault = ("preset.originalNameCounter", "Original Name + Counter")
        default: keyAndDefault = nil
        }
        guard let keyAndDefault else { return name }
        return L10n.string(keyAndDefault.0, defaultValue: keyAndDefault.1, language: language)
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
