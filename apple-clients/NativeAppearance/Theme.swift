// Shares the web palette, surface styling and live theme interpretation across Apple clients.
// AppModel and WatchModel apply authenticated theme updates through ThemeStore.

import AstralCore
import SwiftUI

struct AstralPalette: Equatable {
    var bg = Color(hex: 0x121214)
    var surface = Color(hex: 0x1B1B1F)
    var surface2 = Color(hex: 0x232328)
    var border = Color.white.opacity(0.08)
    var primary = Color(hex: 0x7C3AED)
    var secondary = Color(hex: 0x6E6E78)
    var accent = Color(hex: 0xA78BFA)
    var text = Color(hex: 0xECECEF)
    var muted = Color(hex: 0x93939B)
    var success = Color(hex: 0x5EC28F)
    var warning = Color(hex: 0xD4A94A)
    var error = Color(hex: 0xE17272)
    var info = Color(hex: 0x9A8CF2)
    var onError = Color(hex: 0x121214)
    var fieldBorder = Color(hex: 0x6E6E75)

    static let graphite = AstralPalette()
    static let midnight: AstralPalette = {
        let store = ThemeStore()
        store.apply(preset: "midnight")
        return store.palette
    }()
    static let daylight: AstralPalette = {
        let store = ThemeStore()
        store.apply(preset: "daylight")
        return store.palette
    }()

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
    var palette = AstralPalette.graphite

    var colorScheme: ColorScheme {
        let color = palette.bg.resolve(in: EnvironmentValues())
        return 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue > 0.5 ? .light : .dark
    }

    func applyPreferences(_ json: JSONValue?) {
        let theme = json?["preferences"]?["theme"] ?? json?["theme"] ?? json
        apply(spec: theme)
    }

    func apply(spec: JSONValue?) {
        guard let spec else { return }
        let preset = spec["preset"]?.stringValue
        if let preset { apply(preset: preset) }
        var colors = spec["colors"]?.objectValue ?? [:]
        if let key = spec["color_key"]?.stringValue, let value = spec["color_value"] { colors[key] = value }
        if spec["preset"] == nil, spec["colors"] == nil, spec["color_key"] == nil, let flat = spec.objectValue {
            colors = flat
        }
        let applied = apply(colors: colors)
        guard preset == nil, !applied.isEmpty else { return }
        deriveExtras(applied: applied)
    }

    private func deriveExtras(applied: [WritableKeyPath<AstralPalette, Color>]) {
        palette.border = palette.text.opacity(0.08)
        let reference = colorScheme == .dark ? AstralPalette.graphite : AstralPalette.daylight
        let statusRoles: [WritableKeyPath<AstralPalette, Color>] = [
            \.success, \.warning, \.error, \.info, \.onError, \.fieldBorder,
        ]
        for role in statusRoles where !applied.contains(role) { palette[keyPath: role] = reference[keyPath: role] }
        guard !applied.contains(\.surface2) else { return }
        let base = palette.surface.resolve(in: EnvironmentValues())
        let target: Float = colorScheme == .dark ? 1 : 0
        func shifted(_ channel: Float) -> Double { Double(channel + (target - channel) * 0.04) }
        palette.surface2 = Color(
            .sRGB, red: shifted(base.red), green: shifted(base.green), blue: shifted(base.blue), opacity: 1)
    }

    private func apply(colors: [String: JSONValue]) -> [WritableKeyPath<AstralPalette, Color>] {
        colors.compactMap { key, value in
            guard let role = Self.role(key), let hex = value.stringValue, let color = Color(cssHex: hex) else {
                return nil
            }
            palette[keyPath: role] = color
            return role
        }
    }

    private static func role(_ channel: String) -> WritableKeyPath<AstralPalette, Color>? {
        switch channel {
        case "bg", "background": \.bg
        case "surface": \.surface
        case "surface2", "surface_2": \.surface2
        case "primary": \.primary
        case "secondary": \.secondary
        case "accent": \.accent
        case "text": \.text
        case "muted": \.muted
        case "success": \.success
        case "warning": \.warning
        case "error": \.error
        case "info": \.info
        case "on_error", "onError": \.onError
        case "field_border", "fieldBorder": \.fieldBorder
        default: nil
        }
    }

    func apply(preset: String) {
        switch preset {
        case "midnight":
            palette = AstralPalette(
                bg: Color(hex: 0x0F1221), surface: Color(hex: 0x1A1E2E),
                surface2: Color(hex: 0x1E2338),
                primary: Color(hex: 0x6366F1), secondary: Color(hex: 0x8B5CF6),
                accent: Color(hex: 0x06B6D4), text: Color(hex: 0xF3F4F6),
                muted: Color(hex: 0x9CA3AF),
                error: Color(hex: 0xE27777), onError: Color(hex: 0x0F1221),
                fieldBorder: Color(hex: 0x686F7E))
        case "daylight":
            palette = AstralPalette(
                bg: Color(hex: 0xF8FAFC), surface: Color(hex: 0xFFFFFF),
                surface2: Color(hex: 0xEEF0F5), border: Color.black.opacity(0.08),
                primary: Color(hex: 0x4F46E5), secondary: Color(hex: 0x7C3AED),
                accent: Color(hex: 0x067590), text: Color(hex: 0x1E293B),
                muted: Color(hex: 0x58667B),
                success: Color(hex: 0x147739), warning: Color(hex: 0x955B06),
                error: Color(hex: 0xB91C1C), info: Color(hex: 0x4338CA),
                onError: Color(hex: 0xFFFFFF), fieldBorder: Color(hex: 0x7F8A9B))
        case "ocean":
            palette = AstralPalette(
                bg: Color(hex: 0x0C1222), surface: Color(hex: 0x132038),
                surface2: Color(hex: 0x1C2940),
                primary: Color(hex: 0x0EA5E9), secondary: Color(hex: 0x06B6D4),
                accent: Color(hex: 0x2DD4BF), text: Color(hex: 0xE2E8F0),
                muted: Color(hex: 0x94A3B8),
                error: Color(hex: 0xE27777), onError: Color(hex: 0x0C1222),
                fieldBorder: Color(hex: 0x66758A))
        case "sunset":
            palette = AstralPalette(
                bg: Color(hex: 0x1C1017), surface: Color(hex: 0x2D1B24),
                surface2: Color(hex: 0x35242D),
                primary: Color(hex: 0xF97316), secondary: Color(hex: 0xEF4444),
                accent: Color(hex: 0xFBBF24), text: Color(hex: 0xFEF2F2),
                muted: Color(hex: 0xA8A29E),
                error: Color(hex: 0xE37B7B), onError: Color(hex: 0x1C1017),
                fieldBorder: Color(hex: 0x7B7172))
        case "forest":
            palette = AstralPalette(
                bg: Color(hex: 0x0F1A14), surface: Color(hex: 0x1A2E22),
                surface2: Color(hex: 0x23362B),
                primary: Color(hex: 0x22C55E), secondary: Color(hex: 0x10B981),
                accent: Color(hex: 0xA3E635), text: Color(hex: 0xECFDF5),
                muted: Color(hex: 0x86EFAC),
                error: Color(hex: 0xE78C8C), info: Color(hex: 0xA69AF4),
                onError: Color(hex: 0x0F1A14), fieldBorder: Color(hex: 0x508965))
        default:
            palette = .graphite
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
