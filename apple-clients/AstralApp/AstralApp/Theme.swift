// Apple's design-system tokens and live ThemeStore, ported 1:1 from the web renderer (radii, spacing,
// palette) so Android, Windows, web, and Apple stay visually identical; ThemeStore applies theme_apply pushes
// live via AppModel.

import AstralCore
import SwiftUI

struct AstralPalette: Equatable {
    var bg = Color(hex: 0x0F1221)
    var surface = Color(hex: 0x1A1E2E)
    var surface2 = Color(hex: 0x1E2338)
    var border = Color.white.opacity(0.08)
    var primary = Color(hex: 0x6366F1)
    var secondary = Color(hex: 0x8B5CF6)
    var accent = Color(hex: 0x06B6D4)
    var text = Color(hex: 0xF3F4F6)
    var muted = Color(hex: 0x9CA3AF)
    var success = Color(hex: 0x22C55E)
    var warning = Color(hex: 0xEAB308)
    var error = Color(hex: 0xEF4444)
    var info = Color(hex: 0x3B82F6)

    static let midnight = AstralPalette()

    var gradient: LinearGradient {
        LinearGradient(
            colors: [primary, secondary],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    func variant(_ v: String?) -> Color {
        switch v {
        case "error", "danger": return error
        case "warning": return warning
        case "success": return success
        case "info": return info
        case "accent": return accent
        default: return primary
        }
    }
}

enum AstralRadius {
    static let sm: CGFloat = 6
    static let md: CGFloat = 10
    static let lg: CGFloat = 14
}

enum AstralWebStyle {
    static func canvasInset(_ width: CGFloat) -> CGFloat { width < 700 ? 12 : 16 }
    static func chartInset(_ width: CGFloat) -> CGFloat { width < 700 ? 8 : 12 }

    static func metricAccent(_ variant: String?, palette: AstralPalette) -> Color {
        switch variant {
        case "success": return palette.success
        case "warning": return palette.warning
        case "error": return palette.error
        default: return palette.primary
        }
    }
}

#if os(macOS)
    // WKWebView can't paint transparent on macOS; this tracks the backdrop
    struct AstralChartBackdrop: Equatable {
        let red: Double
        let green: Double
        let blue: Double

        init(_ color: Color) {
            let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .black
            red = rgb.redComponent
            green = rgb.greenComponent
            blue = rgb.blueComponent
        }

        private init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        func overlay(_ color: Color, opacity: Double) -> Self {
            let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .black
            let alpha = min(1, max(0, opacity * rgb.alphaComponent))
            return Self(
                red: rgb.redComponent * alpha + red * (1 - alpha),
                green: rgb.greenComponent * alpha + green * (1 - alpha),
                blue: rgb.blueComponent * alpha + blue * (1 - alpha))
        }

        var hex: UInt32 {
            func byte(_ value: Double) -> UInt32 { UInt32((min(1, max(0, value)) * 255).rounded()) }
            return byte(red) << 16 | byte(green) << 8 | byte(blue)
        }
    }

    private struct AstralChartBackdropKey: EnvironmentKey {
        static let defaultValue: AstralChartBackdrop? = nil
    }

    extension EnvironmentValues {
        var astralChartBackdrop: AstralChartBackdrop? {
            get { self[AstralChartBackdropKey.self] }
            set { self[AstralChartBackdropKey.self] = newValue }
        }
    }

    private struct AstralChartBackdropModifier: ViewModifier {
        let palette: AstralPalette
        let color: Color
        let opacity: Double
        @Environment(\.astralChartBackdrop) private var inherited

        func body(content: Content) -> some View {
            content.environment(
                \.astralChartBackdrop,
                (inherited ?? AstralChartBackdrop(palette.bg)).overlay(color, opacity: opacity))
        }
    }
#endif

extension View {
    @ViewBuilder
    func astralChartBackdrop(_ palette: AstralPalette, color: Color, opacity: Double) -> some View {
        #if os(macOS)
            modifier(AstralChartBackdropModifier(palette: palette, color: color, opacity: opacity))
        #else
            self
        #endif
    }

    func astralWebSurface(_ palette: AstralPalette) -> some View {
        background(palette.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.07)))
            .astralWebShadow(radius: 10)
            .astralChartBackdrop(palette, color: palette.surface, opacity: 0.45)
    }

    func astralWebShadow(radius: CGFloat) -> some View {
        background {
            Canvas { context, size in
                let outline = Path(
                    roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4),
                    cornerRadius: radius)
                context.clip(to: outline, options: .inverse)
                context.addFilter(.shadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 1))
                context.fill(outline, with: .color(.black))
            }
            .padding(-4)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

@MainActor
@Observable
final class ThemeStore {
    var palette = AstralPalette.midnight

    func applyPreferences(_ json: JSONValue?) {
        let theme = json?["preferences"]?["theme"] ?? json?["theme"] ?? json
        apply(spec: theme)
    }

    func apply(spec: JSONValue?) {
        guard let spec else { return }
        if let preset = spec["preset"]?.stringValue { apply(preset: preset) }
        if let colors = spec["colors"]?.objectValue { apply(colors: colors) }
        if let key = spec["color_key"]?.stringValue,
            let val = spec["color_value"]?.stringValue,
            let color = Color(cssHex: val)
        {
            set(channel: key, color)
        }
        if spec["preset"] == nil, spec["colors"] == nil, spec["color_key"] == nil,
            let flat = spec.objectValue
        {
            apply(colors: flat)
        }
    }

    private func apply(colors: [String: JSONValue]) {
        for (key, value) in colors {
            if let hex = value.stringValue, let color = Color(cssHex: hex) {
                set(channel: key, color)
            }
        }
    }

    private func set(channel: String, _ color: Color) {
        switch channel {
        case "bg", "background": palette.bg = color
        case "surface": palette.surface = color
        case "surface2", "surface_2": palette.surface2 = color
        case "primary": palette.primary = color
        case "secondary": palette.secondary = color
        case "accent": palette.accent = color
        case "text": palette.text = color
        case "muted": palette.muted = color
        default: break
        }
    }

    func apply(preset: String) {
        switch preset {
        case "daylight":
            palette = AstralPalette(
                bg: Color(hex: 0xF8FAFC), surface: Color(hex: 0xFFFFFF),
                surface2: Color(hex: 0xEEF0F5), border: Color.black.opacity(0.08),
                primary: Color(hex: 0x4F46E5), secondary: Color(hex: 0x7C3AED),
                accent: Color(hex: 0x0891B2), text: Color(hex: 0x1E293B),
                muted: Color(hex: 0x64748B))
        case "ocean":
            palette = AstralPalette(
                bg: Color(hex: 0x0C1222), surface: Color(hex: 0x132038),
                primary: Color(hex: 0x0EA5E9), secondary: Color(hex: 0x06B6D4),
                accent: Color(hex: 0x2DD4BF), text: Color(hex: 0xE2E8F0),
                muted: Color(hex: 0x94A3B8))
        case "sunset":
            palette = AstralPalette(
                bg: Color(hex: 0x1C1017), surface: Color(hex: 0x2D1B24),
                primary: Color(hex: 0xF97316), secondary: Color(hex: 0xEF4444),
                accent: Color(hex: 0xFBBF24), text: Color(hex: 0xFEF2F2),
                muted: Color(hex: 0xA8A29E))
        case "forest":
            palette = AstralPalette(
                bg: Color(hex: 0x0F1A14), surface: Color(hex: 0x1A2E22),
                primary: Color(hex: 0x22C55E), secondary: Color(hex: 0x10B981),
                accent: Color(hex: 0xA3E635), text: Color(hex: 0xECFDF5),
                muted: Color(hex: 0x86EFAC))
        default:
            palette = .midnight
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }

    init?(cssHex raw: String) {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(hex: value)
    }
}
