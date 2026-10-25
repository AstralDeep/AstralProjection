// Presents explicit Mac permissions and workspace grants separately from server-owned product settings.
// The persistent session panel controls the same host authority as this local settings sheet.

#if os(macOS)
    import AppKit
    import SwiftUI

    struct MacComputerControls: View {
        @Bindable var host: MacComputerHost
        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Computer access on this Mac").font(.title2.bold())
                    Text(host.statusLabel).accessibilityIdentifier("mac-computer-status")
                    Text(
                        "Astral can observe this desktop, operate applications and browsers, and use the clipboard during an approved session. Commands use the visible Terminal and require server approval. You complete sign-in and system permission dialogs yourself."
                    )
                    if !host.available {
                        Text(
                            "Install the direct-download Mac build to host computer tasks. This distribution remains a controller."
                        )
                    }
                    permission("Accessibility", allowed: host.accessibilityAllowed, action: host.requestAccessibility)
                    permission("Screen Recording", allowed: host.screenAllowed, action: host.requestScreen)
                    permission("Input Monitoring", allowed: host.monitoringAllowed, action: host.requestMonitoring)
                    Button("Refresh permissions") { host.refreshPermissions() }
                    Toggle(
                        "Allow computer tasks on this Mac", isOn: Binding(get: { host.enabled }, set: host.setEnabled)
                    )
                    .disabled(!host.available).accessibilityIdentifier("mac-computer-consent")
                    Divider()
                    Text("Selected workspaces").font(.headline)
                    Text(
                        "File tools can access only these folders. Writes and deletes also require the server's action approval. An approved Terminal command has broader computer access."
                    )
                    ForEach(host.files.roots, id: \.self) { path in
                        HStack {
                            Text(path).textSelection(.enabled)
                            Spacer()
                            Button("Remove") {
                                host.stop()
                                host.files.remove(path)
                                host.workspacesChanged()
                            }
                        }
                    }
                    Button("Choose workspace folders…") {
                        host.stop()
                        host.files.choose()
                        host.workspacesChanged()
                    }.disabled(!host.available || !host.ownerBound)
                    if let error = host.files.errorMessage { Text(error).foregroundStyle(.red) }
                    if let error = host.lastError {
                        Text(error).foregroundStyle(.red).accessibilityIdentifier("mac-computer-error")
                    }
                    if host.session != nil { MacComputerSessionControls(host: host) }
                    HStack {
                        Spacer()
                        Button("Done") { host.controlsPresented = false }.keyboardShortcut(.cancelAction)
                    }
                }.padding(24)
            }.frame(minWidth: 480, idealWidth: 560, minHeight: 460, idealHeight: 620)
        }
        private func permission(_ label: String, allowed: Bool, action: @escaping () -> Void) -> some View {
            HStack {
                Label(label, systemImage: allowed ? "checkmark.circle" : "exclamationmark.circle")
                Spacer()
                Button(allowed ? "Review" : "Grant access", action: action).disabled(!host.available)
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
                        Button("Resume") { host.resume() }.disabled(!host.canResume)
                    } else {
                        Button("Pause") { host.pause() }
                    }
                    Button("Stop", role: .destructive) { host.stop() }.accessibilityIdentifier("mac-computer-stop")
                }
                if host.awaitingPause { Text("Waiting for the server to confirm this pause…").font(.caption) }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
#endif
