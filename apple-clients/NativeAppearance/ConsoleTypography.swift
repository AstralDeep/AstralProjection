// Registers the web console's licensed Open Sans font in the shared native app resources.
// Apple console views use this typography on phone, tablet, desktop and watch.

import CoreText
import Foundation
import SwiftUI

enum ConsoleTypography {
    static let sansName = "OpenSans-Regular"
    static let monoName = sansName

    private static let registration: Void = {
        if let url = Bundle.main.url(forResource: "open-sans-latin", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    static func registerFonts() { _ = registration }

    static func sans(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        registerFonts()
        return .custom(sansName, size: size, relativeTo: style)
    }

    static func mono(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        sans(size, relativeTo: style)
    }

    static var body: Font { sans(16) }
    static var callout: Font { sans(16, relativeTo: .callout) }
    static var subheadline: Font { sans(14, relativeTo: .subheadline) }
    static var footnote: Font { sans(13, relativeTo: .footnote) }
    static var caption: Font { sans(12, relativeTo: .caption) }
    static var caption2: Font { sans(12, relativeTo: .caption2) }
    static var headline: Font { sans(16, relativeTo: .headline).weight(.semibold) }
    static var title3: Font { sans(20, relativeTo: .title3) }
    static var title2: Font { sans(24, relativeTo: .title2) }
    static var title: Font { sans(28, relativeTo: .title) }
    static var largeTitle: Font { sans(34, relativeTo: .largeTitle) }
}
