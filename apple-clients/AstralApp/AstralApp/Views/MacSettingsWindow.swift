// The Mac Settings window opened with Command-comma: Updates, This Mac and Account panes, restored to the last pane.
// AstralAppMain hosts it as a Settings scene; the panes open the existing update, computer and server surfaces.

#if os(macOS)
    import AstralCore
    import SwiftUI

    enum MacSettingsPane: String, CaseIterable {
        case updates, thisMac, account

        static let storageKey = "settings.pane"

        static func resolve(_ stored: String, updatesEnabled: Bool) -> MacSettingsPane {
            let pane = MacSettingsPane(rawValue: stored) ?? .account
            return pane == .updates && !updatesEnabled ? .account : pane
        }
    }

    struct MacSettingsView: View {
        @Environment(AppModel.self) private var model
        @Environment(ThemeStore.self) private var theme
        @ObservedObject var updates: UpdateCoordinator
        @AppStorage(MacSettingsPane.storageKey) private var stored = MacSettingsPane.account.rawValue

        private var selection: Binding<MacSettingsPane> {
            Binding(
                get: { MacSettingsPane.resolve(stored, updatesEnabled: updates.isEnabled) },
                set: { stored = $0.rawValue })
        }

        var body: some View {
            TabView(selection: selection) {
                if updates.isEnabled {
                    UpdateSettingsSheet(coordinator: updates)
                        .frame(maxWidth: .infinity).background(theme.palette.surface)
                        .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
                        .tag(MacSettingsPane.updates)
                }
                MacSettingsThisMac(host: model.macComputerHost)
                    .tabItem { Label("This Mac", systemImage: "desktopcomputer") }
                    .tag(MacSettingsPane.thisMac)
                MacSettingsAccount()
                    .tabItem { Label("Account", systemImage: "person.crop.circle") }
                    .tag(MacSettingsPane.account)
            }
            .frame(width: 460)
            .foregroundStyle(theme.palette.text)
            .background(theme.palette.surface)
        }
    }

    struct MacSettingsThisMac: View {
        @Environment(ThemeStore.self) private var theme
        @Environment(\.dismiss) private var dismiss
        @Bindable var host: MacComputerHost

        var body: some View {
            Form {
                LabeledContent("Computer access") {
                    Text(host.statusLabel).foregroundStyle(theme.palette.muted).multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("settings-computer-status")
                }
                HStack {
                    Spacer()
                    Button("Computer Controls…") {
                        host.showControls()
                        dismiss()
                    }
                    .disabled(!host.available)
                    .accessibilityIdentifier("settings-computer-controls")
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
            .font(ConsoleTypography.subheadline)
            .background(theme.palette.surface)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    struct MacSettingsAccount: View {
        @Environment(AppModel.self) private var model
        @Environment(ThemeStore.self) private var theme
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            Form {
                if !model.signedIn {
                    Text("Not signed in").foregroundStyle(theme.palette.muted)
                        .accessibilityIdentifier("settings-account-signed-out")
                } else if let menu = model.chromeMenu {
                    if let identity = menu.console?.identity {
                        LabeledContent(identity.name) {
                            Text(identity.role).foregroundStyle(theme.palette.muted)
                        }
                        .accessibilityIdentifier("settings-account-identity")
                    }
                    ForEach(menu.menu) { group in
                        Section(group.label) {
                            ForEach(group.items) { item in row(item) }
                        }
                    }
                    HStack {
                        Spacer()
                        Button(menu.signout.label) {
                            dismiss()
                            Task { await model.signOut() }
                        }
                        .accessibilityIdentifier("settings-account-sign-out")
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading settings").foregroundStyle(theme.palette.muted)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settings-account-loading")
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
            .font(ConsoleTypography.subheadline)
            .background(theme.palette.surface)
            .frame(minHeight: 200, idealHeight: 420, maxHeight: 640)
        }

        private func row(_ item: ChromeMenuItem) -> some View {
            let handoff = item.availability?.mode == .handoff
            return Button {
                guard !model.mandatorySurface, model.chromeMenu?.allItems.contains(item) == true else { return }
                model.openMenuItem(item)
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.label).foregroundStyle(handoff ? theme.palette.muted : theme.palette.text)
                        if handoff, let message = item.availability?.message {
                            Text(message).font(ConsoleTypography.caption).foregroundStyle(theme.palette.muted)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(theme.palette.muted).accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(handoff || model.mandatorySurface)
            .accessibilityValue(handoff ? item.availability?.message ?? "" : "")
            .accessibilityIdentifier("settings-account-\(item.key)")
        }
    }

    struct MacSettingsRouter: ViewModifier {
        @ObservedObject var updates: UpdateCoordinator
        @Environment(\.openSettings) private var openSettings
        @AppStorage(MacSettingsPane.storageKey) private var stored = MacSettingsPane.account.rawValue

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
