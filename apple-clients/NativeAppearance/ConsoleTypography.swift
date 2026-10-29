// Supplies native system typography on Mac and the registered console family on other Apple clients.
// Console views share these size roles while code uses the platform's monospaced design on Mac.

import CoreText
import Foundation
import SwiftUI

enum ConsoleTypography {
    static let sansName = "OpenSans-Regular"

    private static let registration: Void = {
        if let url = Bundle.main.url(forResource: "open-sans-latin", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    static func registerFonts() { _ = registration }

    static func sans(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        #if os(macOS)
            return .system(size: size)
        #else
            registerFonts()
            return .custom(sansName, size: size, relativeTo: style)
        #endif
    }

    static func mono(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        #if os(macOS)
            return .system(size: size, design: .monospaced)
        #else
            return sans(size, relativeTo: style)
        #endif
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
