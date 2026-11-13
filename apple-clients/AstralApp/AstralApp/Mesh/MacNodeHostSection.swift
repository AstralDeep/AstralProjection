// The "Run a node on this Mac" settings section: it offers the downloadable node pack with its size, shows install and run state, and starts the pairing into the owner's mesh.
// MeshSettingsView embeds it on macOS only, and the pairing approval reuses MeshAddDeviceView so the node joins like any other device.

#if os(macOS)
    import AppKit
    import AstralCore
    import SwiftUI

    struct MacNodeHostSection: View {
        @Environment(MacNodeHostStore.self) private var store
        @Environment(MeshRuntime.self) private var mesh
        @Environment(ThemeStore.self) private var theme
        @State private var pairing = false
        @State private var showingApproval = false
        @State private var confirmingRemoval = false
        @State private var notice: String?
        private var p: AstralPalette { theme.palette }
        private var controller: NodeHostController { store.controller }

        var body: some View {
            if controller.isAvailable {
                Section {
                    state
                    if let message = notice ?? controller.message {
                        Text(message).font(ConsoleTypography.footnote).foregroundStyle(p.muted)
                            .accessibilityIdentifier("mesh.node.message")
                    }
                } header: {
                    Text("Node on this Mac")
                } footer: {
                    Text(
                        "Runs your own node here as a background process. Its data stays on this Mac. It is downloaded only when you ask."
                    )
                }
                .sheet(isPresented: $showingApproval) {
                    NavigationStack { MeshAddDeviceView() }.frame(minWidth: 420, minHeight: 360)
                }
                .confirmationDialog("Remove the node pack?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
                    Button("Remove", role: .destructive) { Task { await controller.remove() } }
                } message: {
                    Text("The node stops and its program files are deleted. Its data and identity stay in the node folder.")
                }
            }
        }

        @ViewBuilder private var state: some View {
            switch controller.phase {
            case .unavailable:
                EmptyView()
            case .notInstalled, .offered:
                addressRow
                if case .offered(let offer) = controller.phase {
                    LabeledContent("Download", value: offer.sizeDescription)
                        .accessibilityIdentifier("mesh.node.size")
                    Button("Download and install") { Task { await controller.install() } }
                        .accessibilityIdentifier("mesh.node.install")
                }
            case .downloading(let fraction):
                ProgressView(value: fraction) { Text("Downloading the node") }
                    .accessibilityIdentifier("mesh.node.progress")
            case .verifying:
                ProgressView { Text("Checking and unpacking") }.accessibilityIdentifier("mesh.node.verifying")
            case .installed(let version):
                LabeledContent("Installed", value: version).accessibilityIdentifier("mesh.node.version")
                Button("Start node") { Task { await controller.start() } }
                    .accessibilityIdentifier("mesh.node.start")
                removeButton
            case .starting:
                ProgressView { Text("Starting the node") }.accessibilityIdentifier("mesh.node.starting")
            case .backingOff(let text):
                Label(text, systemImage: "arrow.clockwise").foregroundStyle(p.warning)
                    .accessibilityIdentifier("mesh.node.backoff")
                Button("Stop") { Task { await controller.stop() } }
            case .running(let port):
                LabeledContent("Status") {
                    Label("Running on 127.0.0.1:\(port)", systemImage: "checkmark.circle.fill").foregroundStyle(p.success)
                }
                .accessibilityIdentifier("mesh.node.running")
                if let mesh = controller.descriptor?.mesh {
                    LabeledContent("Mesh", value: mesh.state == "enrolled" ? "Joined" : "Not joined")
                        .accessibilityIdentifier("mesh.node.mesh-state")
                }
                joinButton
                Toggle("Keep running after quit", isOn: Bindable(controller).keepRunning)
                    .accessibilityIdentifier("mesh.node.keep")
                HStack {
                    Button("Show log") { NSWorkspace.shared.open(controller.logDirectory) }
                        .accessibilityIdentifier("mesh.node.log")
                    Spacer()
                    Button("Stop") { Task { await controller.stop() } }.accessibilityIdentifier("mesh.node.stop")
                }
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(p.error)
                    .accessibilityIdentifier("mesh.node.failed")
                HStack {
                    Button("Try again") { Task { await controller.stop(); await controller.start() } }
                        .accessibilityIdentifier("mesh.node.retry")
                    Button("Show log") { NSWorkspace.shared.open(controller.logDirectory) }
                }
                removeButton
            }
        }

        private var addressRow: some View {
            HStack {
                TextField("Node pack address", text: Bindable(controller).packURLText)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("mesh.node.address")
                Button("Check") { Task { await controller.lookUpOffer() } }
                    .disabled(controller.packURLText.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("mesh.node.check")
            }
        }

        private var removeButton: some View {
            Button("Remove node pack…", role: .destructive) { confirmingRemoval = true }
                .accessibilityIdentifier("mesh.node.remove")
        }

        private var joinButton: some View {
            Button(pairing ? "Waiting for sign-in" : "Add this node to my mesh") {
                Task { await join() }
            }
            .disabled(pairing || mesh.status.meshId == nil || controller.descriptor?.mesh?.state == "enrolled")
            .accessibilityIdentifier("mesh.node.join")
        }

        private func join() async {
            pairing = true
            notice = nil
            defer { pairing = false }
            do {
                switch try await controller.requestPairing(ownerToken: MacNodeHostStore.ownerToken) {
                case .offer(let offer):
                    await mesh.previewAddDevice(payload: offer.payload)
                    showingApproval = true
                case .alreadyJoined:
                    notice = "This node is already in a mesh."
                }
            } catch NodePairingError.unauthorized {
                notice = "The node did not accept this sign-in."
            } catch NodePairingError.refused(_, let detail) {
                notice = detail == "node_owner_mismatch" ? "This node belongs to a different account." : "The node refused the request."
            } catch NodePairingError.meshUnavailable(let code) {
                notice = "The node cannot join a mesh yet (\(code))."
            } catch EnrollmentSignInError.cancelled {
                notice = nil
            } catch {
                notice = "Pairing did not start."
            }
        }
    }
#endif
