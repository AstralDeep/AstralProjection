// The Mac Settings window opened with Command-comma: Updates, This Mac and Account panes, restored to the last pane.
// AstralAppMain hosts it as a Settings scene; the panes open the existing update, computer and server surfaces.

#if os(macOS)
    import AppKit
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
        @Environment(\.dismiss) private var dismiss
        @AppStorage(MacSettingsPane.storageKey) private var stored = MacSettingsPane.account.rawValue

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
        @Environment(AppModel.self) private var model
        @Environment(ThemeStore.self) private var theme
        @Environment(\.dismiss) private var dismiss
        @Bindable var host: MacComputerHost
        @State private var notificationAuthorization: MacWorkNotificationSystem.Authorization = .notDetermined

        var body: some View {
            Form {
                LabeledContent("Computer access") {
                    Text(host.statusLabel).foregroundStyle(theme.palette.muted).multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("settings-computer-status")
                }
                MacBypassToggle(host: host, origin: .settings).accessibilityIdentifier("settings-computer-bypass")
                HStack {
                    Spacer()
                    Button("Computer Controls…") {
                        host.showControls()
                        dismiss()
                    }
                    .disabled(!host.available)
                    .accessibilityIdentifier("settings-computer-controls")
                }
                Section("Notifications") {
                    LabeledContent("Status") {
                        Text(notificationStatus)
                            .foregroundStyle(theme.palette.muted)
                            .accessibilityIdentifier("settings-notification-status")
                    }
                    Picker("Alerts", selection: modeBinding) {
                        Text("Never").tag(MacWorkNotificationMode.never)
                        Text("Only in background").tag(MacWorkNotificationMode.onlyInBackground)
                        Text("Always").tag(MacWorkNotificationMode.always)
                    }
                    .pickerStyle(.radioGroup)
                    .accessibilityIdentifier("settings-notification-mode")
                    Toggle("Approval needed", isOn: kindBinding(.approval))
                        .accessibilityIdentifier("settings-notification-approval")
                    Toggle("Questions", isOn: kindBinding(.question))
                        .accessibilityIdentifier("settings-notification-question")
                    Toggle("Turn finished", isOn: kindBinding(.finished))
                        .accessibilityIdentifier("settings-notification-finished")
                    Toggle("Turn failed", isOn: kindBinding(.failed))
                        .accessibilityIdentifier("settings-notification-failed")
                    Toggle("Include the chat title", isOn: chatTitleBinding)
                        .accessibilityIdentifier("settings-notification-chat-title")
                    Text(
                        "Alerts name only the event kind and never include tool arguments or output. The chat title "
                            + "appears only when you turn it on above. Question alerts wait for the background so they "
                            + "never repeat the in-app banner."
                    )
                    .font(ConsoleTypography.caption).foregroundStyle(theme.palette.muted)
                    HStack {
                        Spacer()
                        Button(notificationAuthorization == .denied ? "Open System Settings…" : "Enable notifications")
                        {
                            if notificationAuthorization == .denied {
                                if let url = URL(
                                    string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
                                {
                                    NSWorkspace.shared.open(url)
                                }
                            } else {
                                Task {
                                    _ = await model.requestMacWorkNotificationPermission()
                                    await refreshNotificationAuthorization()
                                }
                            }
                        }
                        .disabled(notificationAuthorization == .authorized)
                        .accessibilityIdentifier("settings-notification-permission")
                    }
                }
                Section("Composer keys") {
                    Picker(
                        "While a task runs, Return",
                        selection: Binding(
                            get: { model.composerReturnBinding },
                            set: { model.composerReturnBinding = $0 }
                        )
                    ) {
                        Text("Sends a steer").tag(AppModel.ComposerReturnBinding.steer)
                        Text("Queues a follow-up").tag(AppModel.ComposerReturnBinding.queue)
                    }
                    .pickerStyle(.radioGroup)
                    .accessibilityIdentifier("settings-composer-binding")
                    Text("Option-Return does the other action while the server offers steering.")
                        .font(ConsoleTypography.caption).foregroundStyle(theme.palette.muted)
                }
                if model.signedIn && model.connected {
                    Section("Connections") {
                        HStack {
                            Spacer()
                            Button("Remote MCP…") {
                                model.openSurface("remote_mcp")
                                dismiss()
                            }
                            .accessibilityIdentifier("settings-remote-mcp")
                        }
                    }
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
            .font(ConsoleTypography.subheadline)
            .background(theme.palette.surface)
            .fixedSize(horizontal: false, vertical: true)
            .bypassConfirmation(host: host, origin: .settings)
            .task { await refreshNotificationAuthorization() }
        }

        private var notificationStatus: String {
            switch notificationAuthorization {
            case .authorized: return "On"
            case .denied: return "Off in System Settings"
            case .notDetermined: return "Off"
            }
        }

        private var modeBinding: Binding<MacWorkNotificationMode> {
            Binding(
                get: { model.macWorkNotificationSettings.mode },
                set: {
                    var settings = model.macWorkNotificationSettings
                    settings.mode = $0
                    model.macWorkNotificationSettings = settings
                })
        }

        private func kindBinding(_ kind: MacWorkNotificationKind) -> Binding<Bool> {
            Binding(
                get: { model.macWorkNotificationSettings.isEnabled(kind) },
                set: {
                    var settings = model.macWorkNotificationSettings
                    if $0 {
                        settings.enabledKinds.insert(kind)
                    } else {
                        settings.enabledKinds.remove(kind)
                    }
                    model.macWorkNotificationSettings = settings
                })
        }

        private var chatTitleBinding: Binding<Bool> {
            Binding(
                get: { model.macWorkNotificationSettings.includeChatTitle },
                set: {
                    var settings = model.macWorkNotificationSettings
                    settings.includeChatTitle = $0
                    model.macWorkNotificationSettings = settings
                })
        }

        private func refreshNotificationAuthorization() async {
            notificationAuthorization = await model.macWorkNotificationService.permissionState()
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
            .accessibilityLabel(item.label)
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
