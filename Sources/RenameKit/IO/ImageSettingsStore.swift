import Foundation

public struct ImageSettingsStore {
    private let userDefaults: UserDefaults
    private let keyPrefix: String

    public init(
        userDefaults: UserDefaults = .standard,
        keyPrefix: String = "imageSettings"
    ) {
        self.userDefaults = userDefaults
        self.keyPrefix = keyPrefix
    }

    public func loadJPEGQuality() -> JPEGQualitySetting {
        let preset = userDefaults.string(forKey: presetKey)
            .flatMap(JPEGQualityPreset.init(rawValue:)) ?? .high
        let storedCustom = userDefaults.object(forKey: customPercentKey) as? Int ?? 95
        return JPEGQualitySetting(preset: preset, customPercent: storedCustom)
    }

    public func saveJPEGQuality(_ setting: JPEGQualitySetting) {
        userDefaults.set(setting.preset.rawValue, forKey: presetKey)
        userDefaults.set(setting.normalizedCustomPercent, forKey: customPercentKey)
    }

    private var presetKey: String { "\(keyPrefix).jpegQualityPreset" }
    private var customPercentKey: String { "\(keyPrefix).jpegCustomQualityPercent" }
}
