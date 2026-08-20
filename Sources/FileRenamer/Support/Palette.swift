import SwiftUI

/// The app's colours.
///
/// Flat and saturated, taken from a single named swatch set so blocks, status marks
/// and accents all belong to the same family. Names are kept from the source set —
/// they are more memorable than hex, and they make it obvious when a colour is being
/// reused somewhere it does not belong.
enum Palette {
    static let tomatoRed = srgb(0.941, 0.196, 0.008)      // TOMATO RED
    static let mandarinRed = srgb(0.902, 0.298, 0.235)    // MANDARIN RED
    static let jalapenoRed = srgb(0.722, 0.059, 0.235)    // JALAPENO RED

    static let squashBlossom = srgb(0.949, 0.702, 0.200)  // SQUASH BLOSSOM
    static let icelandPoppy = srgb(0.969, 0.604, 0.271)   // ICELAND POPPY
    static let carrotOrange = srgb(0.878, 0.541, 0.133)   // CARROT ORANGE

    static let azraqBlue = srgb(0.275, 0.404, 0.722)      // AZRAQ BLUE
    static let livid = srgb(0.404, 0.518, 0.784)          // LIVID
    static let yueGuangLanBlue = srgb(0.102, 0.227, 0.588) // YUÈ GUĀNG LÁN BLUE
    static let darkSapphire = srgb(0.051, 0.129, 0.286)   // DARK SAPPHIRE
    static let goodSamaritan = srgb(0.180, 0.345, 0.463)  // GOOD SAMARITAN
    static let dupain = srgb(0.357, 0.608, 0.722)         // DUPAIN
    static let spray = srgb(0.510, 0.812, 0.890)          // SPRAY

    static let reefEncounter = srgb(0.000, 0.596, 0.596)  // REEF ENCOUNTER
    static let auroraGreen = srgb(0.373, 0.812, 0.553)    // AURORA GREEN
    static let paradiseGreen = srgb(0.678, 0.890, 0.541)  // PARADISE GREEN

    // MARK: Roles

    /// Duplicate review has two verdicts and they deserve distinct colours: an exact
    /// match is a fact about the bytes, a similar match is only a suggestion. Both are
    /// kept clear of the system alert colours so "identical file" never reads as
    /// "rename error", and "looks alike" never reads as "something is wrong".
    static let duplicateExact = jalapenoRed
    static let duplicateSimilar = dupain

    static let error = Color(nsColor: .systemRed)
    static let warning = Color(nsColor: .systemOrange)
    static let ok = Color(nsColor: .systemGreen)
    static let accent = Color(nsColor: .controlAccentColor)

    private static func srgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(nsColor: NSColor(srgbRed: red, green: green, blue: blue, alpha: 1))
    }
}
