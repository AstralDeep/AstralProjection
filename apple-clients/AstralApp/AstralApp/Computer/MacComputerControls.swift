// Presents explicit Mac permissions and workspace grants separately from server-owned product settings.
// The persistent session panel controls the same host authority as this local settings sheet.

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
        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Computer access on this Mac").font(.title2.bold())
                    Text(host.statusLabel).accessibilityIdentifier("mac-computer-status")
                    if let error = host.lastError {
                        Text(error).foregroundStyle(.red).accessibilityIdentifier("mac-computer-error")
                    }
                    Text(host.permissionDiagnostic).font(.caption).textSelection(.enabled)
                        .accessibilityIdentifier("mac-computer-permission-facts")
                    Text(
                        "Astral can observe this desktop, operate applications and browsers, and use the clipboard during an approved session. Commands use the visible Terminal and require server approval. You complete sign-in and system permission dialogs yourself."
                    )
                    if !host.available {
                        Text(
                            "Install the direct-download Mac build to host computer tasks. This distribution remains a controller."
                        )
                    }
                    permission(
                        "Accessibility", allowed: host.accessibilityAllowed, command: .permission(.accessibility))
                    permission("Screen Recording", allowed: host.screenAllowed, command: .permission(.screen))
                    permission("Input Monitoring", allowed: host.monitoringAllowed, command: .permission(.monitoring))
                    Button("Refresh permissions", action: MacComputerControlCommand.refreshPermissions.action(on: host))
                    Toggle(
                        "Allow computer tasks on this Mac", isOn: MacComputerControlCommand.enabledBinding(on: host)
                    )
                    .disabled(!host.available).accessibilityIdentifier("mac-computer-consent")
                    Text("Saved for this account and server. Locking pauses access and ends active tasks.")
                        .font(.caption)
                    if host.consentEnabled && !host.enabled {
                        Button(
                            "Resume computer access",
                            action: MacComputerControlCommand.setEnabled(true).action(on: host)
                        )
                        .accessibilityIdentifier("mac-computer-resume-access")
                    }
                    Divider()
                    Text("Selected workspaces").font(.headline)
                    Text(
                        "File tools can access only these folders. Writes and deletes also require the server's action approval. An approved Terminal command has broader computer access."
                    )
                    ForEach(host.files.roots, id: \.self) { path in
                        HStack {
                            Text(path).textSelection(.enabled)
                            Spacer()
                            Button("Remove", action: MacComputerControlCommand.removeWorkspace(path).action(on: host))
                        }
                    }
                    Button(
                        "Choose workspace folders…", action: MacComputerControlCommand.chooseWorkspaces.action(on: host)
                    )
                    .disabled(!host.available || !host.ownerBound)
                    if let error = host.files.errorMessage { Text(error).foregroundStyle(.red) }
                    if host.session != nil { MacComputerSessionControls(host: host) }
                    HStack {
                        Spacer()
                        Button("Done", action: MacComputerControlCommand.done.action(on: host)).keyboardShortcut(
                            .cancelAction)
                    }
                }.padding(24)
            }.frame(minWidth: 480, idealWidth: 560, minHeight: 460, idealHeight: 620)
        }
        private func permission(_ label: String, allowed: Bool, command: MacComputerControlCommand) -> some View {
            HStack {
                Label(label, systemImage: allowed ? "checkmark.circle" : "exclamationmark.circle")
                Spacer()
                Button(allowed ? "Review" : "Grant access", action: command.action(on: host)).disabled(!host.available)
            }
        }
    }

    struct MacComputerSessionControls: View {
        @Bindable var host: MacComputerHost
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(host.statusLabel).font(.headline)
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
