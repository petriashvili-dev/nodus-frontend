import CoreText
import Foundation

/// Registers the bundled Cormorant Garamond faces used by the onboarding
/// screen. Done via `CTFontManagerRegisterFontsForURL` at launch rather
/// than `UIAppFonts` in Info.plist, since this target's Info.plist is
/// synthesized by Xcode and doesn't support hand-adding array entries.
enum FontRegistrar {
    private static var didRegister = false

    static func registerCustomFontsIfNeeded() {
        guard !didRegister else { return }
        didRegister = true

        let filenames = [
            "CormorantGaramond-Light",
            "CormorantGaramond-Regular",
            "CormorantGaramond-LightItalic"
        ]

        for filename in filenames {
            guard let url = Bundle.main.url(forResource: filename, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
