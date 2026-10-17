import SwiftUI

/// Cormorant Garamond — the serif display face used on the onboarding
/// screen and the splash screen, registered at launch by `FontRegistrar`.
extension Font {
    static func cormorant(_ size: CGFloat, weight: Weight, italic: Bool = false) -> Font {
        let name: String
        switch (weight, italic) {
        case (.light, true):
            name = "CormorantGaramondItalic-LightItalic"
        case (.light, false):
            name = "CormorantGaramond-Light"
        default:
            name = "CormorantGaramond-Regular"
        }
        return .custom(name, size: size)
    }
}
