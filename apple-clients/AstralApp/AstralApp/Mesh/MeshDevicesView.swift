// The devices screen: this device, the other devices on the mesh with a one-line plain status, requests waiting here, and the safety controls.
// Adding, removing and stopping are signed through the host consent sheet, so every roster change asks for biometrics.

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
    @State private var adding = false
    private var p: AstralPalette { theme.palette }

    private var thisDevice: [MeshMember] { mesh.members.filter(\.isThisDevice) }
    private var otherDevices: [MeshMember] { mesh.members.filter { !$0.isThisDevice } }

    var body: some View {
        Form {
            if !mesh.requestsForMe.isEmpty {
                Section("Requests for this device") {
                    ForEach(mesh.requestsForMe) { MeshRequestRow(request: $0) }
                }
                .accessibilityIdentifier("mesh.devices.requests")
            }
            Section("This device") {
                ForEach(thisDevice) { member in
                    NavigationLink(value: member.memberId) { MeshDeviceRow(member: member, sync: sync(of: member)) }
                        .accessibilityIdentifier("mesh.member.\(member.memberId.suffix(8))")
                    if !member.attested { MeshVerifyButton() }
                }
            }
            Section {
                ForEach(otherDevices) { member in
                    NavigationLink(value: member.memberId) { MeshDeviceRow(member: member, sync: sync(of: member)) }
                        .accessibilityIdentifier("mesh.member.\(member.memberId.suffix(8))")
                        .swipeActions {
                            Button("Remove", role: .destructive) { removing = member }
                        }
                        .contextMenu {
                            Button("Remove Device", role: .destructive) { removing = member }
                        }
                }
                if otherDevices.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No other devices yet").font(ConsoleTypography.headline)
                        Text("Add a phone or computer to keep your chats on every device.")
                            .font(ConsoleTypography.subheadline).foregroundStyle(p.muted)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("mesh.devices.empty")
                }
                Button {
                    adding = true
                } label: {
                    Label("Add Device", systemImage: "plus.circle.fill")
                }
                .accessibilityIdentifier("mesh.devices.add")
            } header: {
                Text("Other devices")
            } footer: {
                #if os(iOS)
                    Text(MeshPresentation.syncLine(mesh.syncSummary))
                #endif
            }
            MeshSafetySection()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .meshReadableWidth()
        .background(p.bg)
        .navigationTitle("Devices")
        .navigationDestination(for: String.self) { memberId in MeshDeviceDetailView(memberId: memberId) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    adding = true
                } label: {
                    Label("Add Device", systemImage: "plus")
                        #if os(macOS)
                            .labelStyle(.titleAndIcon)
                        #endif
                }
                .accessibilityIdentifier("mesh.devices.toolbar.add")
            }
        }
        .sheet(isPresented: $adding) {
            MeshAddDeviceSheet()
        }
        .meshRemoveConfirmation($removing)
    }

    private func sync(of member: MeshMember) -> MeshDeviceSync? {
        mesh.sync.devices.first { $0.memberId == member.memberId }
    }
}

extension View {
    @ViewBuilder
    func meshReadableWidth() -> some View {
        #if os(macOS)
            frame(maxWidth: 720).frame(maxWidth: .infinity)
        #else
            self
        #endif
    }

    func meshRemoveConfirmation(_ member: Binding<MeshMember?>) -> some View {
        modifier(MeshRemoveConfirmation(member: member))
    }
}

private struct MeshRemoveConfirmation: ViewModifier {
    @Binding var member: MeshMember?
    @Environment(MeshRuntime.self) private var mesh

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Remove \(member?.label ?? "this device")?",
            isPresented: Binding(get: { member != nil }, set: { if !$0 { member = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove Device", role: .destructive) {
                if let target = member { Task { await mesh.removeDevice(target) } }
                member = nil
            }
            Button("Cancel", role: .cancel) { member = nil }
        } message: {
            Text("It will no longer read or write your chats. You will be asked to approve.")
        }
    }
}

struct MeshDeviceRow: View {
    let member: MeshMember
    let sync: MeshDeviceSync?
    @Environment(ThemeStore.self) private var theme
    private var p: AstralPalette { theme.palette }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: MeshPresentation.icon(member.kind))
                .font(.title3)
                .foregroundStyle(p.accent)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.label).font(ConsoleTypography.headline)
                HStack(spacing: 4) {
                    if !member.attested {
                        Image(systemName: "exclamationmark.circle.fill").accessibilityHidden(true)
                    }
                    Text(MeshPresentation.deviceStatus(member, sync: sync))
                }
                .font(ConsoleTypography.subheadline)
                .foregroundStyle(member.attested ? p.muted : p.warning)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct MeshVerifyButton: View {
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    private var p: AstralPalette { theme.palette }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                Task { await mesh.verifyIdentity() }
            } label: {
                if mesh.verification == .signingIn {
                    Label {
                        Text("Signing in")
                    } icon: {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    Label("Verify", systemImage: "checkmark.shield")
                }
            }
            .disabled(mesh.verification == .signingIn)
            .accessibilityHint("Signs in to confirm this device belongs to you")
            .accessibilityIdentifier("mesh.devices.verify")
            if case .failed(let message) = mesh.verification {
                Text(message).font(ConsoleTypography.footnote).foregroundStyle(p.error)
                    .accessibilityIdentifier("mesh.devices.verify.error")
            }
        }
    }
}

struct MeshSafetySection: View {
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    @State private var confirmingStop = false
    private var p: AstralPalette { theme.palette }

    var body: some View {
        Section {
            if mesh.status.stopped {
                Label("Every device is stopped", systemImage: "hand.raised.fill")
                    .foregroundStyle(p.error)
                    .accessibilityIdentifier("mesh.devices.halted")
                Button {
                    Task { await mesh.resume() }
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .accessibilityHint("Asks for your approval")
                .accessibilityIdentifier("mesh.devices.resume")
            } else {
                Button(role: .destructive) {
                    confirmingStop = true
                } label: {
                    Label("Emergency Stop", systemImage: "hand.raised.fill")
                }
                .accessibilityIdentifier("mesh.devices.stop")
            }
        } header: {
            Text("Safety")
        } footer: {
            Text(
                mesh.status.stopped
                    ? "Resuming asks for your approval and lets every device act again."
                    : "Stops every device from taking any action until you resume.")
        }
        .confirmationDialog("Stop every device?", isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("Stop All Devices", role: .destructive) { Task { await mesh.raiseStop() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("No device will take any action until you resume. You can resume from Devices or Settings.")
        }
    }
}

enum MeshPasteboardReader {
    static func hasString() -> Bool {
        #if os(macOS)
            return NSPasteboard.general.canReadObject(forClasses: [NSString.self], options: nil)
        #else
            return UIPasteboard.general.hasStrings
        #endif
    }

    static func string() -> String {
        #if os(macOS)
            return NSPasteboard.general.string(forType: .string) ?? ""
        #else
            return UIPasteboard.general.string ?? ""
        #endif
    }
}

private struct MeshBorderedButton: ViewModifier {
    @Environment(ThemeStore.self) private var theme

    func body(content: Content) -> some View {
        content.buttonStyle(.bordered).tint(theme.palette.accent)
    }
}

extension View {
    func meshBordered() -> some View { modifier(MeshBorderedButton()) }
}
