// The watch's slice of the shared AstralDeep design system: brand indigo and warning colors kept numerically
// identical to web's astral.css custom properties, since the wrist has no live theming channel.

import SwiftUI

enum WatchBrand {
    static let primary = Color(red: 0x63 / 255, green: 0x66 / 255, blue: 0xF1 / 255)
    static let warning = Color(red: 0xEA / 255, green: 0xB3 / 255, blue: 0x08 / 255)
    static let error = Color(red: 0xEF / 255, green: 0x44 / 255, blue: 0x44 / 255)
}
