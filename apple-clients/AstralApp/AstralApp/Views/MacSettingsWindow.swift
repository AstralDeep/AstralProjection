// The Mac Settings window opened with Command-comma: Updates and This Mac panes, restored to the last pane.
// AstralAppMain hosts it as a Settings scene; the panes show update controls and the kernel version.

#if os(macOS)
    import AppKit
    import AstralCore
    import AstralKernel
    import SwiftUI

    enum MacSettingsPane: String, CaseIterable {
        case updates, thisMac

        static let storageKey = "settings.pane"

        static func resolve(_ stored: String, updatesEnabled: Bool) -> MacSettingsPane {
            let pane = MacSettingsPane(rawValue: stored) ?? .thisMac
            return pane == .updates && !updatesEnabled ? .thisMac : pane
        }
    }

    struct MacSettingsView: View {
        @Environment(ThemeStore.self) private var theme
        @ObservedObject var updates: UpdateCoordinator
        @Environment(\.dismiss) private var dismiss
        @AppStorage(MacSettingsPane.storageKey) private var stored = MacSettingsPane.thisMac.rawValue

        private var selection: Binding<MacSettingsPane> {
            Binding(
                get: { MacSettingsPane.resolve(stored, updatesEnabled: updates.isEnabled) },
                set: { stored = $0.rawValue })
        }

        var body: some View {
            TabView(selection: selection) {
                if updates.isEnabled {
                    UpdateSettingsSheet(coordinator: updates) { dismiss() }
                        .frame(maxWidth: .infinity, minHeight: 340, idealHeight: 360).background(theme.palette.surface)
                        .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
                        .tag(MacSettingsPane.updates)
                }
                MacSettingsThisMac()
                    .tabItem { Label("This Mac", systemImage: "desktopcomputer") }
                    .tag(MacSettingsPane.thisMac)
            }
            .frame(width: 460)
            .foregroundStyle(theme.palette.text)
            .background(theme.palette.surface)
        }
    }

    struct MacSettingsThisMac: View {
        @Environment(ThemeStore.self) private var theme

        var body: some View {
            Form {
                LabeledContent("Kernel") {
                    Text(AstralKernelInfo.version).foregroundStyle(theme.palette.muted)
                        .accessibilityIdentifier("settings-kernel-version")
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
            .font(ConsoleTypography.subheadline)
            .background(theme.palette.surface)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    struct MacSettingsRouter: ViewModifier {
        @ObservedObject var updates: UpdateCoordinator
        @Environment(\.openSettings) private var openSettings
        @AppStorage(MacSettingsPane.storageKey) private var stored = MacSettingsPane.thisMac.rawValue

        func body(content: Content) -> some View {
            content.onChange(of: updates.settingsPresented) { _, presented in
                guard presented else { return }
                updates.settingsPresented = false
                stored = MacSettingsPane.updates.rawValue
                openSettings()
            }
        }
    }
#endif
