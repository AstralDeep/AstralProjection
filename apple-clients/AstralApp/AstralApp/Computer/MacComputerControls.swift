// Presents explicit Mac permissions, workspace grants with their excluded patterns, and the persisted
// bypass-approvals switch separately from server-owned product settings. The session panel and the bypass
// confirmation sheet act on the same host authority.

#if os(macOS)
    import AppKit
    import SwiftUI

    @MainActor
    enum MacComputerControlCommand {
        case permission(MacComputerPermission)
        case refreshPermissions
        case setEnabled(Bool)
        case chooseWorkspaces
        case removeWorkspace(String)
        case pause, resume, stop, done

        func perform(on host: MacComputerHost) {
            switch self {
            case .permission(.accessibility): host.requestAccessibility()
            case .permission(.screen): host.requestScreen()
            case .permission(.monitoring): host.requestMonitoring()
            case .refreshPermissions: host.refreshPermissions()
            case .setEnabled(let value): host.setEnabled(value)
            case .chooseWorkspaces:
                host.stop()
                host.files.choose()
                host.workspacesChanged()
            case .removeWorkspace(let path):
                host.stop()
                host.files.remove(path)
                host.workspacesChanged()
            case .pause: host.pause()
            case .resume: host.resume()
            case .stop: host.stop()
            case .done: host.controlsPresented = false
            }
        }
        func action(on host: MacComputerHost) -> () -> Void { { perform(on: host) } }
        static func enabledBinding(on host: MacComputerHost) -> Binding<Bool> {
            Binding(get: { host.consentEnabled }, set: { setEnabled($0).perform(on: host) })
        }
    }

    struct MacComputerControls: View {
        @Bindable var host: MacComputerHost
        @Environment(ThemeStore.self) private var theme: ThemeStore?
        private var palette: AstralPalette { theme?.palette ?? .graphite }
        var body: some View {
            SettingsSheetChrome(
                "Computer access on this Mac", identifier: "mac-computer-controls",
                close: MacComputerControlCommand.done.action(on: host)
            ) {
                Text(host.statusLabel).accessibilityIdentifier("mac-computer-status")
                if let error = host.lastError {
                    Text(error.leadSentence).foregroundStyle(palette.error)
                        .accessibilityIdentifier("mac-computer-error")
                }
                VStack(alignment: .leading, spacing: 10) {
                    SettingsSectionTitle("Permissions")
                    Text("AstralDeep sees and operates this Mac only during sessions you approve.")
                        .font(ConsoleTypography.caption).foregroundStyle(palette.muted)
                    permission(
                        "Accessibility", allowed: host.accessibilityAllowed, command: .permission(.accessibility))
                    permission("Screen Recording", allowed: host.screenAllowed, command: .permission(.screen))
                    permission(
                        "Input Monitoring", allowed: host.monitoringAllowed, command: .permission(.monitoring))
                    Button(
                        "Refresh permissions", action: MacComputerControlCommand.refreshPermissions.action(on: host)
                    )
                    .disabled(!host.available)
                    Toggle(
                        "Allow computer tasks on this Mac",
                        isOn: MacComputerControlCommand.enabledBinding(on: host)
                    )
                    .disabled(!host.available).accessibilityIdentifier("mac-computer-consent")
                    MacBypassToggle(host: host, origin: .controls)
                        .accessibilityIdentifier("mac-computer-bypass")
                    if host.bypass && host.bypassSaved {
                        Label("Approvals bypassed on this Mac (persisted)", systemImage: "exclamationmark.shield.fill")
                            .font(ConsoleTypography.caption).foregroundStyle(palette.warning)
                            .accessibilityIdentifier("mac-computer-bypass-persisted")
                    }
                    if host.consentEnabled {
                        Toggle(
                            "Restore access and bypass automatically after relaunch",
                            isOn: Binding(get: { host.automatedRestore }, set: host.setAutomatedRestore)
                        )
                        .disabled(!host.available).accessibilityIdentifier("mac-computer-automated-restore")
                    }
                    if let browser = host.browser as? MacBrowserDriver {
                        Toggle(
                            "Browser pane", isOn: Binding(get: { browser.paneEnabled }, set: browser.setPaneEnabled)
                        )
                        .disabled(!host.available || !browser.accountBound)
                        .accessibilityIdentifier("mac-computer-browser-pane")
                    }
                    if host.consentEnabled && !host.enabled {
                        Button(
                            "Resume computer access",
                            action: MacComputerControlCommand.setEnabled(true).action(on: host)
                        )
                        .accessibilityIdentifier("mac-computer-resume-access")
                    }
                }
                if !host.projectMode {
                    Divider().overlay(palette.border)
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsSectionTitle("Workspaces")
                        Text("File tools reach only these folders.")
                            .font(ConsoleTypography.caption).foregroundStyle(palette.muted)
                        ForEach(host.files.roots, id: \.self) { path in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(path).textSelection(.enabled)
                                    Spacer()
                                    Button(
                                        "Remove",
                                        action: MacComputerControlCommand.removeWorkspace(path).action(on: host))
                                }
                                if !host.files.exclusions.patterns.isEmpty {
                                    Text("Hidden: " + host.files.exclusions.patterns.joined(separator: ", "))
                                        .font(ConsoleTypography.caption).foregroundStyle(palette.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .accessibilityIdentifier("mac-computer-workspace-excluded")
                                }
                            }
                        }
                        Button(
                            "Choose workspace folders…",
                            action: MacComputerControlCommand.chooseWorkspaces.action(on: host)
                        )
                        .disabled(!host.available || !host.ownerBound)
                        if let error = host.files.errorMessage {
                            Text(error.leadSentence).foregroundStyle(palette.error)
                                .accessibilityIdentifier("mac-computer-workspace-error")
                        }
                    }
                }
                if !host.checkpointRoots.isEmpty {
                    Divider().overlay(palette.border)
                    MacCheckpointFilesSection(host: host)
                }
                if host.session != nil { MacComputerSessionControls(host: host) }
                if !host.activityTimeline.entries.isEmpty {
                    Divider().overlay(palette.border)
                    MacComputerActivitySection(timeline: host.activityTimeline)
                }
                if host.available {
                    Divider().overlay(palette.border)
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsSectionTitle("Command sandbox")
                        Text(
                            "Approved commands run inside a generated macOS sandbox profile and reach the network "
                                + "only through a local egress proxy for this Mac's allowed domains. Shadow mode "
                                + "records violations without blocking; enforce mode blocks them."
                        )
                        .font(ConsoleTypography.caption).foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        Toggle(
                            "Block sandbox violations",
                            isOn: Binding(get: { host.sandboxEnforce }, set: host.setSandboxEnforce)
                        )
                        .disabled(!host.available).accessibilityIdentifier("mac-computer-sandbox-enforce")
                        Text(host.sandboxSummary)
                            .font(ConsoleTypography.caption).foregroundStyle(palette.muted)
                            .accessibilityIdentifier("mac-computer-sandbox-summary")
                    }
                }
            }
            .frame(minWidth: 480, idealWidth: 560, minHeight: 460, idealHeight: 620)
            .bypassConfirmation(host: host, origin: .controls)
        }
        private func permission(_ label: String, allowed: Bool, command: MacComputerControlCommand) -> some View {
            HStack {
                Label(label, systemImage: allowed ? "checkmark.circle" : "exclamationmark.circle")
                Spacer()
                Button(allowed ? "Review" : "Grant access", action: command.action(on: host)).disabled(!host.available)
            }
        }
    }

    private struct MacComputerActivitySection: View {
        @Bindable var timeline: MacComputerActivityTimeline
        @Environment(ThemeStore.self) private var theme: ThemeStore?

        var body: some View {
            let palette = theme?.palette ?? .graphite
            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionTitle("Recent computer activity")
                ForEach(timeline.entries.suffix(12).reversed()) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.title)
                        if let verb = entry.safeVerb {
                            Text(verb).foregroundStyle(palette.muted)
                        }
                        Spacer(minLength: 4)
                        Text(entry.occurredAt, style: .time)
                            .foregroundStyle(palette.muted)
                    }
                    .font(ConsoleTypography.caption)
                    .accessibilityElement(children: .combine)
                }
            }
            .accessibilityIdentifier("mac-computer-activity")
        }
    }

    struct MacBypassToggle: View {
        @Bindable var host: MacComputerHost
        let origin: MacBypassOrigin
        var body: some View {
            Toggle(
                "Bypass approvals",
                isOn: Binding(get: { host.bypass }, set: { host.requestBypass($0, from: origin) })
            )
            .disabled(!host.available || !host.enabled)
        }
    }

    struct MacBypassConfirmation: View {
        @Bindable var host: MacComputerHost
        @Environment(ThemeStore.self) private var theme: ThemeStore?
        var body: some View {
            let palette = theme?.palette ?? .graphite
            SettingsSheetChrome(
                "Bypass approvals on this Mac?", identifier: "mac-bypass", close: host.cancelBypass, done: nil
            ) {
                Text(
                    "AstralDeep will click, type, run commands and browse on this Mac without asking until you turn this off. Stop or Esc still halts a task."
                )
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("mac-bypass-message")
            } footer: {
                Button("Cancel", action: host.cancelBypass).accessibilityIdentifier("mac-bypass-cancel")
                Button("Bypass approvals", action: host.confirmBypass)
                    .buttonStyle(SettingsButtonStyle(palette: palette, danger: true))
                    .accessibilityIdentifier("mac-bypass-confirm")
            }
            .frame(minWidth: 400, idealWidth: 440, minHeight: 200)
        }
    }

    extension View {
        func bypassConfirmation(host: MacComputerHost, origin: MacBypassOrigin) -> some View {
            modifier(MacBypassConfirmationPresenter(host: host, origin: origin))
        }
    }

    private struct MacBypassConfirmationPresenter: ViewModifier {
        @Bindable var host: MacComputerHost
        let origin: MacBypassOrigin
        @Environment(ThemeStore.self) private var theme: ThemeStore?
        func body(content: Content) -> some View {
            content.sheet(
                isPresented: Binding(
                    get: { host.bypassConfirmation == origin },
                    set: { if !$0, host.bypassConfirmation == origin { host.cancelBypass() } })
            ) {
                MacBypassConfirmation(host: host).environment(theme)
            }
        }
    }

    struct MacComputerSessionControls: View {
        @Bindable var host: MacComputerHost
        @Environment(ThemeStore.self) private var theme: ThemeStore?
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(host.statusLabel).font(.headline)
                if host.bypass {
                    Label("Bypass on", systemImage: "exclamationmark.shield.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle((theme?.palette ?? .graphite).warning)
                        .accessibilityIdentifier("mac-computer-bypass-on")
                }
                if let session = host.session { Text("Controlled by \(session.controller)").font(.caption) }
                HStack {
                    if host.session?.state == "paused" {
                        Button("Resume", action: MacComputerControlCommand.resume.action(on: host)).disabled(
                            !host.canResume)
                    } else {
                        Button("Pause", action: MacComputerControlCommand.pause.action(on: host))
                    }
                    Button("Stop", role: .destructive, action: MacComputerControlCommand.stop.action(on: host))
                        .accessibilityIdentifier("mac-computer-stop")
                }
                if host.awaitingPause { Text("Waiting for the server to confirm this pause…").font(.caption) }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
#endif
