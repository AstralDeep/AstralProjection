// Shared settings chrome: header, scrolling body, pinned footer, Return for Done (or no Done for a confirmation),
// Esc to close, palette-drawn controls including a danger button.
// The Updates sheet and computer controls use the chrome; ConsoleShell uses the covered-background modifier, which
// keeps a modal settings layer keyboard-safe and returns focus on close.

import SwiftUI

#if os(macOS)
    import AppKit
#endif

enum SettingsControlMetrics {
    static let height: CGFloat = 28
    static let minimumWidth: CGFloat = 64
    static let formColumn: CGFloat = 220
    static let headerHeight: CGFloat = 56
}

struct SettingsSheetChrome<Content: View, Footer: View>: View {
    let title: String
    let identifier: String
    let close: () -> Void
    let done: String?
    let content: Content
    let footer: Footer
    @Environment(ThemeStore.self) private var theme: ThemeStore?

    init(
        _ title: String, identifier: String, close: @escaping () -> Void, done: String? = "Done",
        @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.identifier = identifier
        self.close = close
        self.done = done
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        let palette = theme?.palette ?? .graphite
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title).font(ConsoleTypography.headline).foregroundStyle(palette.text)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("\(identifier)-title")
                Spacer(minLength: 0)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                        .frame(width: SettingsControlMetrics.height, height: SettingsControlMetrics.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(palette.muted)
                .keyboardShortcut(.cancelAction)
                .help("Close").accessibilityLabel("Close").accessibilityIdentifier("\(identifier)-close")
            }
            .padding(.horizontal, 20).frame(minHeight: SettingsControlMetrics.headerHeight)
            Divider().overlay(palette.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content }
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(palette.border)
            HStack(spacing: 8) {
                if let done {
                    footer
                    Spacer(minLength: 0)
                    Button(done, action: close)
                        .buttonStyle(SettingsButtonStyle(palette: palette, prominent: true))
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("\(identifier)-done")
                } else {
                    Spacer(minLength: 0)
                    footer
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .font(ConsoleTypography.footnote)
        .foregroundStyle(palette.text)
        .tint(palette.primary)
        .toggleStyle(SettingsCheckboxStyle(palette: palette))
        .buttonStyle(SettingsButtonStyle(palette: palette))
        .controlSize(.small)
        .background(palette.surface)
        #if os(macOS)
            .onExitCommand(perform: close)
        #endif
    }
}

extension SettingsSheetChrome where Footer == EmptyView {
    init(_ title: String, identifier: String, close: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.init(title, identifier: identifier, close: close, content: content) { EmptyView() }
    }
}

struct SettingsSectionTitle: View {
    let text: String
    @Environment(ThemeStore.self) private var theme: ThemeStore?

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(ConsoleTypography.subheadline.weight(.semibold))
            .foregroundStyle((theme?.palette ?? .graphite).text)
            .accessibilityAddTraits(.isHeader)
    }
}

struct SettingsButtonStyle: ButtonStyle {
    let palette: AstralPalette
    var prominent = false
    var danger = false

    func makeBody(configuration: Configuration) -> some View {
        SettingsButtonBody(configuration: configuration, palette: palette, prominent: prominent, danger: danger)
    }
}

private struct SettingsButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let palette: AstralPalette
    let prominent: Bool
    let danger: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AstralRadius.sm)
        let destructive = configuration.role == .destructive
        let fill = danger ? palette.error : prominent ? palette.primary : palette.text.opacity(0.06)
        let ink = danger ? palette.onError : prominent ? Color.white : destructive ? palette.error : palette.text
        configuration.label
            .font(ConsoleTypography.footnote.weight(prominent || danger ? .semibold : .medium))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minWidth: SettingsControlMetrics.minimumWidth, minHeight: SettingsControlMetrics.height)
            .foregroundStyle(ink)
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(danger ? palette.error : prominent ? palette.primary : palette.border))
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}

struct SettingsCheckboxStyle: ToggleStyle {
    let palette: AstralPalette

    func makeBody(configuration: Configuration) -> some View {
        SettingsCheckbox(configuration: configuration, palette: palette)
    }
}

private struct SettingsCheckbox: View {
    let configuration: ToggleStyleConfiguration
    let palette: AstralPalette
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let on = configuration.isOn
        let shape = RoundedRectangle(cornerRadius: 4)
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                shape.fill(on ? palette.primary : palette.text.opacity(0.04))
                    .overlay(shape.strokeBorder(on ? palette.primary : palette.fieldBorder))
                    .overlay {
                        if on {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 16, height: 16)
                configuration.label.foregroundStyle(palette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

extension View {
    func settingsOverlayBackground(_ covered: Bool, blur: CGFloat) -> some View {
        self.blur(radius: covered ? blur : 0)
            .allowsHitTesting(!covered)
            .accessibilityHidden(covered)
            .disabled(covered)
            .background(SettingsFocusReturn(covered: covered))
    }
}

#if os(macOS)
    private struct SettingsFocusReturn: NSViewRepresentable {
        let covered: Bool

        func makeNSView(context: Context) -> SettingsFocusReturnView { SettingsFocusReturnView() }

        func updateNSView(_ view: SettingsFocusReturnView, context: Context) { view.setCovered(covered) }
    }

    final class SettingsFocusReturnView: NSView {
        private var observation: NSKeyValueObservation?
        private var covered = false
        private weak var remembered: NSView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = window?.observe(\.firstResponder, options: [.initial, .new]) { [weak self] window, _ in
                MainActor.assumeIsolated { self?.note(window.firstResponder) }
            }
        }

        func setCovered(_ value: Bool) {
            guard value != covered else { return }
            covered = value
            if !value, let target = remembered { restore(target, attempts: 20) }
        }

        private func note(_ responder: NSResponder?) {
            guard !covered, let view = Self.owner(of: responder), view !== window?.contentView else { return }
            remembered = view
        }

        // A disabled-then-enabled SwiftUI field refuses first responder until its update lands, so retry briefly
        private func restore(_ target: NSView, attempts: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self, weak target] in
                MainActor.assumeIsolated {
                    guard let self, let target, !self.covered, let window = self.window, target.window === window
                    else { return }
                    let current = window.firstResponder
                    guard Self.owner(of: current) !== target else { return }
                    guard current == nil || current === window || current === window.contentView else { return }
                    window.makeFirstResponder(target)
                    if attempts > 0 { self.restore(target, attempts: attempts - 1) }
                }
            }
        }

        static func owner(of responder: NSResponder?) -> NSView? {
            guard let view = responder as? NSView else { return nil }
            guard let editor = view as? NSTextView, editor.isFieldEditor else { return view }
            var candidate = editor.superview
            while let current = candidate, !(current is NSTextField) { candidate = current.superview }
            return candidate
        }
    }
#else
    private struct SettingsFocusReturn: View {
        let covered: Bool

        var body: some View { Color.clear.allowsHitTesting(false).accessibilityHidden(true) }
    }
#endif
