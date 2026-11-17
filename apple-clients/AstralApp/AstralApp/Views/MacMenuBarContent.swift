// Gives macOS a small menu bar control surface for opening the main window and Settings.
// MacMainWindow reuses an existing main window instead of adding another.

#if os(macOS)
    import AstralCore
    import AppKit
    import SwiftUI

    // openWindow(id:) on a WindowGroup always adds a window, and a hidden app reports its windows as not visible.
    enum MacMainWindow {
        static func reusable(in windows: [NSWindow], appHidden: Bool = false) -> NSWindow? {
            windows.first {
                $0.title == "AstralDeep" && $0.styleMask.contains(.titled)
                    && ($0.isVisible || $0.isMiniaturized || appHidden)
            }
        }

        @MainActor static func show(using openWindow: OpenWindowAction) {
            if let window = reusable(in: NSApp.windows, appHidden: NSApp.isHidden) {
                window.makeKeyAndOrderFront(nil)
            } else {
                openWindow(id: "main")
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    struct MacMenuBarPresentation {
        let updateRequired: Bool

        var status: String { updateRequired ? "Update required" : "Ready" }
    }

    struct MacMenuBarContent: View {
        let updateRequired: Bool
        @Environment(\.openWindow) private var openWindow
        @Environment(\.openSettings) private var openSettings

        var body: some View {
            Text(MacMenuBarPresentation(updateRequired: updateRequired).status)
                .accessibilityIdentifier("mac-menu-status")
            Divider()
            Button("Open AstralDeep") { showMainWindow() }
                .accessibilityIdentifier("mac-menu-open")
            Divider()
            Button("Settings…") { openSettings() }
                .accessibilityIdentifier("mac-menu-settings")
        }

        private func showMainWindow() { MacMainWindow.show(using: openWindow) }
    }
#endif
