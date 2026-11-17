// Shows this person's contact invitation: a QR code to scan and a link to send through the share sheet.
// When the other person accepts, the screen moves on to the code comparison.

import SwiftUI

struct MeshContactInviteView: View {
    @State private var model: MeshContactInviteModel
    @State private var copied = false
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    private var p: AstralPalette { theme.palette }
    private let service: any MeshContactService

    init(service: any MeshContactService) {
        self.service = service
        _model = State(initialValue: MeshContactInviteModel(service: service))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                content
            }
            .frame(maxWidth: 520)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(p.bg)
        .navigationTitle("Invite a Contact")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: mesh.contacts) { await model.checkPending() }
        .onDisappear { Task { await model.cancel() } }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .form: form(problem: nil)
        case .creating: ProgressView("Making an invitation").accessibilityIdentifier("mesh.contacts.invite.creating")
        case .shown(let invitation, let expiresAt): shown(invitation, expiresAt: expiresAt)
        case .comparing(let exchange):
            MeshContactCodeView(model: MeshContactCompareModel(service: service, exchange: exchange))
        case .failed(let message): form(problem: message)
        }
    }

    private func form(problem: String?) -> some View {
        VStack(spacing: 16) {
            Text("What name should they see?").font(ConsoleTypography.title3).accessibilityAddTraits(.isHeader)
            TextField("Your name", text: $model.name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Your name")
                .accessibilityIdentifier(MeshContactID.inviteName)
            if let problem {
                Text(problem).font(ConsoleTypography.footnote).foregroundStyle(p.error)
                    .accessibilityIdentifier("mesh.contacts.invite.error")
            }
            Button {
                Task { await model.create() }
            } label: {
                Text("Make Invitation").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .accessibilityIdentifier(MeshContactID.inviteCreate)
        }
    }

    private func shown(_ invitation: MeshContactInvitation, expiresAt: Date) -> some View {
        VStack(spacing: 16) {
            Text("Let them scan this").font(ConsoleTypography.title3).accessibilityAddTraits(.isHeader)
            MeshQRCodeView(
                text: invitation.text, label: "Contact invitation QR code", identifier: MeshContactID.inviteQR
            )
            .frame(maxWidth: 240)
            MeshCountdownLabel(expiresAt: expiresAt)
            HStack(spacing: 12) {
                ShareLink(item: invitation.link) { Label("Share Link", systemImage: "square.and.arrow.up") }
                    .meshBordered()
                    .accessibilityIdentifier(MeshContactID.inviteShare)
                Button {
                    copied = ComponentPasteboard.copy(invitation.text)
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .meshBordered()
                .accessibilityIdentifier(MeshContactID.inviteCopy)
            }
            .controlSize(.large)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for them").font(ConsoleTypography.footnote).foregroundStyle(p.muted)
            }
            .accessibilityElement(children: .combine)
            Button("Cancel Invitation") { Task { await model.cancel() } }
                .buttonStyle(.borderless)
                .accessibilityIdentifier(MeshContactID.inviteCancel)
        }
    }
}
