// The detail screen for one mesh device: its kind, connection and last contact, a verify prompt when sign-in is missing, a request to that device and its removal.
// It reads the live roster so it follows changes and leaves the screen when the device is removed.

import SwiftUI

struct MeshDeviceDetailView: View {
    let memberId: String
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var removing: MeshMember?
    @State private var renaming = false
    @State private var draft = ""
    private var p: AstralPalette { theme.palette }

    private var member: MeshMember? { mesh.members.first { $0.memberId == memberId } }

    var body: some View {
        Group {
            if let member {
                content(member)
            } else {
                ContentUnavailableView("Device not found", systemImage: "questionmark.circle")
            }
        }
        .navigationTitle(member?.label ?? "Device")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .onChange(of: member == nil) { _, gone in if gone { dismiss() } }
    }

    private func content(_ member: MeshMember) -> some View {
        let sync = mesh.sync.devices.first { $0.memberId == member.memberId }
        return Form {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: MeshPresentation.icon(member.kind))
                        .font(.system(size: 44))
                        .foregroundStyle(p.accent)
                        .accessibilityHidden(true)
                    Text(member.label).font(ConsoleTypography.title3)
                    Text(MeshPresentation.deviceStatus(member, sync: sync))
                        .font(ConsoleTypography.subheadline)
                        .foregroundStyle(member.attested ? p.muted : p.warning)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("mesh.device.header")
            }
            if !member.attested { verification(member) }
            Section("Details") {
                LabeledContent("Name") {
                    HStack {
                        Text(member.label)
                        Button("Rename") {
                            draft = member.label
                            renaming = true
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("mesh.device.rename")
                    }
                }
                LabeledContent("Added", value: MeshPresentation.added(member.addedAt))
                    .accessibilityIdentifier("mesh.device.added")
                LabeledContent("Verification", value: MeshPresentation.verificationAge(member.attested ? member.attestedAt ?? member.addedAt : nil))
                    .accessibilityIdentifier("mesh.device.verified")
                LabeledContent("Kind", value: member.isThisDevice ? "This " + MeshPresentation.kind(member.kind).lowercased() : MeshPresentation.kind(member.kind))
                if !member.isThisDevice {
                    LabeledContent("Last seen", value: lastSeen(sync?.lastSeen ?? member.lastSeen))
                    LabeledContent("Connection", value: MeshPresentation.connection(sync?.path ?? member.path).capitalizedFirst)
                    if let sync { LabeledContent("Sync", value: MeshPresentation.syncState(sync.state)) }
                }
                LabeledContent("History access", value: "All chats")
                LabeledContent("Identity") {
                    Text(member.memberId.suffix(12)).font(.system(.footnote, design: .monospaced))
                }
            }
            if !member.isThisDevice {
                Section {
                    NavigationLink {
                        MeshSendRequestView(member: member)
                    } label: {
                        Label("Send a Request", systemImage: "paperplane")
                    }
                    .accessibilityIdentifier("mesh.device.request")
                } footer: {
                    Text("Ask this device to do something. It answers in a chat when it is online.")
                }
                Section {
                    Button("Remove Device", role: .destructive) { removing = member }
                        .accessibilityIdentifier("mesh.device.remove")
                } footer: {
                    Text("It will no longer read or write your chats.")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .meshReadableWidth()
        .background(p.bg)
        .meshRemoveConfirmation($removing)
        .alert("Rename Device", isPresented: $renaming) {
            TextField("Name", text: $draft)
            Button("Save") { Task { _ = await mesh.renameDevice(member, to: draft) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This name shows on every device.")
        }
    }

    @ViewBuilder
    private func verification(_ member: MeshMember) -> some View {
        Section {
            if member.isThisDevice {
                MeshVerifyButton()
            } else {
                Text("Open AstralDeep on \(member.label) and choose Verify under Devices.")
                    .font(ConsoleTypography.subheadline)
            }
        } header: {
            Text("Needs sign-in")
        } footer: {
            Text("Signing in proves this device belongs to you. Until then it cannot be fully trusted.")
        }
        .accessibilityIdentifier("mesh.device.verification")
    }

    private func lastSeen(_ date: Date?) -> String {
        guard let date else { return "Not yet" }
        return MeshPresentation.clock(date, now: Date())
    }
}

extension String {
    fileprivate var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
