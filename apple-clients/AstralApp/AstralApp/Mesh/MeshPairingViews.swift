// Invitation pairing screens: the existing device shows a QR code and code with a live countdown, and the new device scans or pastes it and compares codes.
// They read MeshRuntime's invite and join state, so the old direction where the new device shows the code stays available as a fallback.

import SwiftUI

struct MeshExpiring<Content: View>: View {
    let expiresAt: Date?
    @ViewBuilder let content: (_ expired: Bool) -> Content

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(expiresAt.map { context.date >= $0 } ?? false)
        }
    }
}

struct MeshCountdownLabel: View {
    let expiresAt: Date
    @Environment(ThemeStore.self) private var theme
    private var p: AstralPalette { theme.palette }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let text = MeshPresentation.countdown(until: expiresAt, now: context.date) {
                Label("Expires in " + text, systemImage: "timer")
                    .monospacedDigit()
                    .foregroundStyle(p.muted)
                    .accessibilityLabel("Expires in " + text)
            } else {
                Label("Expired", systemImage: "exclamationmark.circle").foregroundStyle(p.warning)
            }
        }
        .font(ConsoleTypography.subheadline)
        .accessibilityIdentifier("mesh.countdown")
    }
}

struct MeshComparisonCode: View {
    let code: String
    let identifier: String
    @Environment(ThemeStore.self) private var theme
    private var p: AstralPalette { theme.palette }

    var body: some View {
        let groups = MeshPresentation.codeGroups(code)
        HStack(spacing: 12) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                Text(group)
                    .font(.system(size: 40, weight: .semibold, design: .monospaced))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(p.surface2, in: RoundedRectangle(cornerRadius: AstralRadius.lg))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Comparison code " + groups.joined(separator: " "))
        .accessibilityIdentifier(identifier)
    }
}

struct MeshInviteView: View {
    let onUseCode: () -> Void
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    private var p: AstralPalette { theme.palette }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                switch mesh.invite {
                case .idle, .creating:
                    ProgressView("Making an invitation").padding(.top, 60)
                        .accessibilityIdentifier("mesh.invite.creating")
                case .waiting(let invitation):
                    MeshExpiring(expiresAt: invitation.expiresAt) { expired in
                        if expired { expiredView } else { waiting(invitation) }
                    }
                case .requested(let request):
                    MeshExpiring(expiresAt: request.expiresAt) { expired in
                        if expired { expiredView } else { comparison(request) }
                    }
                case .approving:
                    ProgressView("Waiting for your approval").padding(.top, 60)
                        .accessibilityIdentifier("mesh.invite.approving")
                case .added(let label):
                    added(label)
                case .failed(let message):
                    failed(message)
                }
            }
            .frame(maxWidth: 520)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(p.bg)
        .navigationTitle("Add Device")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { if mesh.invite == .idle { await mesh.startInvitation() } }
        .onDisappear { Task { await mesh.cancelInvitation() } }
    }

    private func waiting(_ invitation: MeshInvitation) -> some View {
        VStack(spacing: 18) {
            Text("Scan this on the new device").font(ConsoleTypography.title2).accessibilityAddTraits(.isHeader)
            Text("Open AstralDeep there and choose Join my mesh.")
                .font(ConsoleTypography.body).foregroundStyle(p.muted).multilineTextAlignment(.center)
            MeshQRCodeView(text: invitation.payload).frame(maxWidth: 240)
            Text(MeshPresentation.invitationCode(invitation.code))
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .accessibilityLabel("Invitation code " + invitation.code.filter { $0 != "-" }.map(String.init).joined(separator: " "))
                .accessibilityIdentifier("mesh.invite.code")
            MeshCountdownLabel(expiresAt: invitation.expiresAt)
            HStack(spacing: 12) {
                ShareLink(item: invitation.payload) { Label("Share", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("mesh.invite.share")
                Button {
                    copied = ComponentPasteboard.copy(invitation.payload)
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("mesh.invite.copy")
            }
            .controlSize(.large)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for the new device").font(ConsoleTypography.footnote).foregroundStyle(p.muted)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("mesh.invite.waiting")
            Button("The new device shows a code instead", action: onUseCode)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("mesh.invite.fallback")
        }
    }

    private func comparison(_ request: MeshJoinRequest) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.shield").font(.system(size: 44)).foregroundStyle(p.accent).accessibilityHidden(true)
            Text("Check the codes match").font(ConsoleTypography.title2).accessibilityAddTraits(.isHeader)
            Text("\(request.deviceLabel) should show the same code.")
                .font(ConsoleTypography.body).foregroundStyle(p.muted).multilineTextAlignment(.center)
            MeshComparisonCode(code: request.comparisonCode, identifier: "mesh.invite.compare")
            Text(MeshPresentation.kind(request.deviceKind))
                .font(ConsoleTypography.caption).foregroundStyle(p.muted)
            MeshCountdownLabel(expiresAt: request.expiresAt)
            Text("If the codes differ, cancel. Someone else may be trying to join.")
                .font(ConsoleTypography.footnote).foregroundStyle(p.muted).multilineTextAlignment(.center)
            Button {
                Task { await mesh.approveInvitation() }
            } label: {
                Label("Approve", systemImage: "checkmark").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityHint("Asks for your approval")
            .accessibilityIdentifier("mesh.invite.approve")
            Button {
                Task {
                    await mesh.cancelInvitation()
                    dismiss()
                }
            } label: {
                Text("Cancel").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.large)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("mesh.invite.cancel")
        }
    }

    private var expiredView: some View {
        failureBody("The code ran out of time.", icon: "timer")
    }

    private func failed(_ message: String) -> some View {
        failureBody(message, icon: "exclamationmark.triangle.fill")
    }

    private func failureBody(_ message: String, icon: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(p.warning).accessibilityHidden(true)
            Text(message).font(ConsoleTypography.title3).multilineTextAlignment(.center)
                .accessibilityIdentifier("mesh.invite.error")
            Button {
                Task {
                    await mesh.cancelInvitation()
                    await mesh.startInvitation()
                }
            } label: {
                Text("Start again").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("mesh.invite.restart")
        }
        .padding(.top, 40)
    }

    private func added(_ label: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(p.success)
                .accessibilityHidden(true)
            Text("\(label) was added").font(ConsoleTypography.title2).multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text("Your chats will sync to it once it connects.")
                .font(ConsoleTypography.body).foregroundStyle(p.muted).multilineTextAlignment(.center)
            Button {
                dismiss()
            } label: {
                Text("Done").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("mesh.invite.done")
        }
        .padding(.top, 40)
        .accessibilityElement(children: .contain)
    }
}

struct MeshJoinStartView: View {
    let onShowCode: () -> Void
    let onBack: () -> Void
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    @State private var payload = ""
    @State private var scanning = false
    @State private var dropTargeted = false
    private var p: AstralPalette { theme.palette }

    var body: some View {
        VStack(spacing: 18) {
            Text("Join my mesh").font(ConsoleTypography.title2).accessibilityAddTraits(.isHeader)
            Text("On a device that is already on your mesh, open Devices and choose Add Device. Then bring its invitation here.")
                .font(ConsoleTypography.body).foregroundStyle(p.muted).multilineTextAlignment(.center)
            #if os(iOS)
                if MeshScanner.isAvailable {
                    Button {
                        scanning = true
                    } label: {
                        Label("Scan the Invitation", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("mesh.join.scan")
                }
            #endif
            pasteArea
            if case .failed(let message) = mesh.join {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(ConsoleTypography.subheadline).foregroundStyle(p.error)
                    .accessibilityIdentifier("mesh.join.error")
            }
            Button {
                Task { await mesh.acceptInvitation(payload: payload) }
            } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || mesh.join == .starting)
            .accessibilityIdentifier("mesh.join.continue")
            Button("Show a code on this device instead", action: onShowCode)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("mesh.join.fallback")
            Button("Back", action: onBack)
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("mesh.join.back")
        }
        #if os(iOS)
            .sheet(isPresented: $scanning) {
                NavigationStack {
                    MeshScannerScreen { scanned in
                        payload = scanned
                        Task { await mesh.acceptInvitation(payload: scanned) }
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanning = false } }
                    }
                }
            }
        #endif
    }

    private var pasteArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AstralRadius.lg).fill(dropTargeted ? p.accent.opacity(0.12) : p.surface)
            RoundedRectangle(cornerRadius: AstralRadius.lg)
                .strokeBorder(dropTargeted ? p.accent : p.fieldBorder, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            if payload.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc").font(.title2).accessibilityHidden(true)
                    Text("Paste or drop the invitation here").font(ConsoleTypography.headline)
                }
                .foregroundStyle(p.muted)
                .allowsHitTesting(false)
            }
            #if os(iOS)
                TextField("", text: $payload, axis: .vertical)
                    .lineLimit(3...5)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(10)
                    .accessibilityLabel("Invitation")
                    .accessibilityIdentifier("mesh.join.payload")
            #else
                TextEditor(text: $payload)
                    .font(.system(.footnote, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .opacity(payload.isEmpty ? 0.02 : 1)
                    .accessibilityLabel("Invitation")
                    .accessibilityIdentifier("mesh.join.payload")
            #endif
        }
        .frame(minHeight: 110)
        .dropDestination(for: String.self) { items, _ in
            guard let text = items.first, !text.isEmpty else { return false }
            payload = text
            Task { await mesh.acceptInvitation(payload: text) }
            return true
        } isTargeted: {
            dropTargeted = $0
        }
    }
}

struct MeshJoinAcceptedView: View {
    let accepted: MeshInvitationAccepted
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    private var p: AstralPalette { theme.palette }

    var body: some View {
        MeshExpiring(expiresAt: accepted.expiresAt) { expired in
            VStack(spacing: 18) {
                if expired {
                    Image(systemName: "timer").font(.system(size: 44)).foregroundStyle(p.warning).accessibilityHidden(true)
                    Text("The code ran out of time.").font(ConsoleTypography.title3)
                        .accessibilityIdentifier("mesh.join.error")
                    Button {
                        mesh.cancelJoin()
                    } label: {
                        Text("Start again").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("mesh.join.restart")
                } else {
                    Text("Check the codes match").font(ConsoleTypography.title2).accessibilityAddTraits(.isHeader)
                    Text("Your other device should show the same code. Approve it there.")
                        .font(ConsoleTypography.body).foregroundStyle(p.muted).multilineTextAlignment(.center)
                    MeshComparisonCode(code: accepted.comparisonCode, identifier: "mesh.join.code")
                    MeshCountdownLabel(expiresAt: accepted.expiresAt)
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for approval").font(ConsoleTypography.footnote).foregroundStyle(p.muted)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("mesh.join.waiting")
                    Button("Cancel") { mesh.cancelJoin() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("mesh.join.cancel")
                }
            }
        }
    }
}
