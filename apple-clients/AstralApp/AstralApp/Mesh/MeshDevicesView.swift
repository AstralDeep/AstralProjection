// The devices screen: members with attestation, last seen and path, requests for this device, a request to another member, removal, the emergency stop, and the add-a-device flow.
// Removing or adding a device is signed through the host consent sheet, so every roster change asks for biometrics.

import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

struct MeshDevicesView: View {
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    @State private var removing: MeshMember?
    @State private var confirmingStop = false
    private var p: AstralPalette { theme.palette }

    var body: some View {
        List {
            if !mesh.requestsForMe.isEmpty {
                Section("Requests for this device") {
                    ForEach(mesh.requestsForMe) { MeshRequestRow(request: $0) }
                }
                .accessibilityIdentifier("mesh.devices.requests")
            }
            Section("Members") {
                ForEach(mesh.members) { member in
                    memberRow(member)
                        .swipeActions {
                            if !member.isThisDevice {
                                Button("Remove", role: .destructive) { removing = member }
                            }
                        }
                        .contextMenu {
                            if !member.isThisDevice {
                                Button("Remove", role: .destructive) { removing = member }
                            }
                        }
                }
                NavigationLink {
                    MeshAddDeviceView()
                } label: {
                    Label("Add a device", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("mesh.devices.add")
            }
            Section {
                if mesh.status.stopped {
                    Label("The mesh is stopped. No device runs actions.", systemImage: "hand.raised.fill")
                        .foregroundStyle(p.error)
                        .accessibilityIdentifier("mesh.devices.halted")
                    Button {
                        Task { await mesh.resume() }
                    } label: {
                        Label("Resume the mesh with biometrics", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("mesh.devices.resume")
                } else {
                    Button(role: .destructive) {
                        confirmingStop = true
                    } label: {
                        Label("Emergency stop", systemImage: "hand.raised.fill")
                    }
                    .accessibilityIdentifier("mesh.devices.stop")
                }
            } footer: {
                Text(
                    mesh.status.stopped
                        ? "Resuming asks for your approval and lets every device run actions again."
                        : mesh.status.stopLevel == 0
                        ? "Every device refuses actions that were already in progress."
                        : "Stopped \(mesh.status.stopLevel) times. Every device refuses actions that were already in progress.")
            }
        }
        .navigationTitle("Devices")
        .confirmationDialog(
            "Remove \(removing?.label ?? "this device")?", isPresented: Binding(
                get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible
        ) {
            Button("Remove with biometrics", role: .destructive) {
                if let member = removing { Task { await mesh.removeDevice(member) } }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("It will no longer read or write your chats.")
        }
        .confirmationDialog("Stop the whole mesh?", isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("Emergency stop", role: .destructive) { Task { await mesh.raiseStop() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every device refuses actions that were already in progress. New requests start fresh.")
        }
    }
}

extension MeshDevicesView {
    @ViewBuilder
    fileprivate func memberRow(_ member: MeshMember) -> some View {
        let row = MeshMemberRow(member: member, sync: mesh.sync.devices.first { $0.memberId == member.memberId })
        if member.isThisDevice {
            row
        } else {
            NavigationLink {
                MeshSendRequestView(member: member)
            } label: {
                row
            }
            .accessibilityHint("Send a request to this device")
        }
    }
}

struct MeshMemberRow: View {
    let member: MeshMember
    let sync: MeshDeviceSync?
    @Environment(ThemeStore.self) private var theme
    private var p: AstralPalette { theme.palette }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon).foregroundStyle(p.accent).accessibilityHidden(true)
                Text(member.label).font(ConsoleTypography.headline)
                if member.isThisDevice { Text("This device").font(ConsoleTypography.caption).foregroundStyle(p.muted) }
                Spacer()
                Text(member.attested ? "Attested" : "Not attested")
                    .font(ConsoleTypography.caption)
                    .foregroundStyle(member.attested ? p.success : p.warning)
            }
            if !member.isThisDevice {
                Text(
                    MeshPresentation.lastSeen(member.lastSeen) + ". " + MeshPresentation.path(member.path)
                        + (sync.map { ". " + MeshPresentation.syncState($0.state) } ?? "")
                )
                .font(ConsoleTypography.footnote)
                .foregroundStyle(p.muted)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mesh.member.\(member.memberId.suffix(8))")
    }

    private var icon: String {
        switch member.kind {
        case .desktop: return "desktopcomputer"
        case .pocket: return "iphone"
        case .satellite: return "applewatch"
        case .node: return "server.rack"
        }
    }
}

struct MeshAddDeviceView: View {
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    @State private var payload = ""
    private var p: AstralPalette { theme.palette }

    var body: some View {
        Form {
            switch mesh.addDevice {
            case .idle, .failed:
                entry
            case .previewing(let preview, _):
                comparison(preview)
            case .approving:
                Section { ProgressView("Waiting for your approval") }
            case .added(let label):
                Section {
                    Label("\(label) was added.", systemImage: "checkmark.circle.fill").foregroundStyle(p.success)
                        .accessibilityIdentifier("mesh.add.done")
                    Button("Done") { mesh.resetAddDevice() }
                }
            }
            if case .failed(let message) = mesh.addDevice {
                Section { Text(message).foregroundStyle(p.error).accessibilityIdentifier("mesh.add.error") }
            }
        }
        .navigationTitle("Add a device")
        .onDisappear { mesh.resetAddDevice() }
    }

    private var entry: some View {
        Section {
            TextField("Pairing code from the new device", text: $payload, axis: .vertical)
                .lineLimit(2...5)
                .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
                .accessibilityIdentifier("mesh.add.payload")
            Button("Paste") { payload = MeshPasteboardReader.string() }
                .accessibilityIdentifier("mesh.add.paste")
            #if os(iOS)
                if MeshScanner.isAvailable {
                    NavigationLink("Scan a QR code") {
                        MeshScannerScreen { scanned in
                            payload = scanned
                            Task { await mesh.previewAddDevice(payload: scanned) }
                        }
                    }
                    .accessibilityIdentifier("mesh.add.scan")
                }
            #endif
            Button("Continue") { Task { await mesh.previewAddDevice(payload: payload) } }
                .disabled(payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("mesh.add.continue")
        } footer: {
            Text("On the new device choose Join my mesh, then scan its QR code or paste its code here.")
        }
    }

    private func comparison(_ preview: MeshPairingPreview) -> some View {
        Group {
            Section("Compare this code with the new device") {
                Text(preview.comparisonCode)
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .accessibilityIdentifier("mesh.add.code")
                LabeledContent("Device", value: preview.deviceLabel)
                LabeledContent("Type", value: MeshPresentation.kind(preview.deviceKind))
                LabeledContent("Fingerprint", value: preview.fingerprint)
                    .font(.system(.footnote, design: .monospaced))
            }
            Section {
                Button("Approve with biometrics") { Task { await mesh.approveAddDevice() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("mesh.add.approve")
                Button("Cancel", role: .cancel) { mesh.resetAddDevice() }
                    .accessibilityIdentifier("mesh.add.cancel")
            }
        }
    }
}

enum MeshPasteboardReader {
    static func string() -> String {
        #if os(macOS)
            return NSPasteboard.general.string(forType: .string) ?? ""
        #else
            return UIPasteboard.general.string ?? ""
        #endif
    }
}
