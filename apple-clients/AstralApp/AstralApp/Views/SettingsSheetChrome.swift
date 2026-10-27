// Shared presentation for settings: the covered-background modifier that keeps a modal settings layer keyboard-safe
// and returns focus on close. ConsoleShell applies it under its server settings overlay.

import SwiftUI

#if os(macOS)
    import AppKit
#endif

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
