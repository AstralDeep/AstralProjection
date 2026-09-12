import CoreText
import Foundation
import SwiftUI

/// Shared approved web fonts, registered from the package resource bundle on
/// every Apple form factor. Relative styles preserve Dynamic Type scaling.
public enum AstralTypography {
    public static let sansName = "Inter-Regular"
    public static let monoName = "JetBrainsMono-Regular"

    private static let registration: Void = {
        for name in ["inter-latin", "jetbrains-mono-latin"] {
            if let url = Bundle.module.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }()

    public static func registerFonts() { _ = registration }

    public static func sans(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        registerFonts()
        return .custom(sansName, size: size, relativeTo: style)
    }

    public static func mono(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        registerFonts()
        return .custom(monoName, size: size, relativeTo: style)
    }

    public static var body: Font { sans(16) }
    public static var callout: Font { sans(16, relativeTo: .callout) }
    public static var subheadline: Font { sans(14, relativeTo: .subheadline) }
    public static var footnote: Font { sans(13, relativeTo: .footnote) }
    public static var caption: Font { sans(12, relativeTo: .caption) }
    public static var caption2: Font { sans(12, relativeTo: .caption2) }
    public static var headline: Font { sans(16, relativeTo: .headline).weight(.semibold) }
    public static var title3: Font { sans(20, relativeTo: .title3) }
    public static var title2: Font { sans(24, relativeTo: .title2) }
    public static var title: Font { sans(28, relativeTo: .title) }
    public static var largeTitle: Font { sans(34, relativeTo: .largeTitle) }
}
