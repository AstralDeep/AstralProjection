// The owner's list of shares: each shared chat with its contact, its state, a withheld PHI notice and a Revoke action.
// The note about what a revoked contact keeps sits above the button, and Revoke asks for confirmation.

import SwiftUI

struct MeshSharesView: View {
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    @State private var model: MeshSharesModel?
    @State private var sharingPhi: MeshShareInfo?
    private var p: AstralPalette { theme.palette }

    var body: some View {
        Group {
            if let model { list(model) } else { ProgressView() }
        }
        .background(p.bg)
        .navigationTitle("Shared Chats")
        .task {
            let made = MeshSharesModel(shares: mesh)
            model = made
            await made.load()
        }
        .sheet(item: $sharingPhi) { share in MeshShareSheet(chatId: share.chat, contact: share.contact) }
    }

    private func list(_ model: MeshSharesModel) -> some View {
        List {
            ForEach(model.rows) { row in rowView(row, model: model) }
            if let problem = model.problem { Text(problem).foregroundStyle(p.error) }
        }
        .accessibilityIdentifier(MeshShareID.list)
        .overlay {
            if model.rows.isEmpty {
                ContentUnavailableView {
                    Label("Nothing shared", systemImage: "square.and.arrow.up")
                } description: {
                    Text("Share a chat from its menu.")
                }
            }
        }
        .confirmationDialog(
            "Revoke this share?",
            isPresented: Binding(get: { model.confirming != nil }, set: { if !$0 { model.cancelRevoke() } }),
            titleVisibility: .visible
        ) {
            Button("Revoke", role: .destructive) { Task { await model.confirmRevoke() } }
                .accessibilityIdentifier(MeshShareID.confirm + ".revoke")
            Button("Cancel", role: .cancel) { model.cancelRevoke() }
        } message: {
            Text(MeshShareRowFacts.revokeNote(for: model.confirming?.contactName ?? ""))
        }
    }

    private func rowView(_ row: MeshShareRowFacts, model: MeshSharesModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: row.title).font(ConsoleTypography.headline).lineLimit(1)
                Spacer()
                Text(row.stateLine).font(ConsoleTypography.caption)
                    .foregroundStyle(row.isRevoked ? p.muted : p.success)
            }
            Text(verbatim: "With " + row.contactName).font(ConsoleTypography.footnote).foregroundStyle(p.muted)
            if let phi = row.phiLine { Label(phi, systemImage: "cross.case").font(ConsoleTypography.footnote) }
            if row.canSharePhi {
                Button("Share PHI Too") { sharingPhi = mesh.shares.first { $0.id == row.id } }
                    .meshBordered()
                    .accessibilityIdentifier(MeshShareID.sharePhi + "." + row.id)
            }
            if row.canRevoke {
                Text(row.revokeNote).font(ConsoleTypography.caption).foregroundStyle(p.muted)
                    .accessibilityIdentifier(MeshShareID.revokeNote + "." + row.id)
                Button("Revoke", role: .destructive) { model.askToRevoke(row.id) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Revoke " + row.title + " for " + row.contactName)
                    .accessibilityIdentifier(MeshShareID.revoke(row.id))
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier(MeshShareID.row(row.id))
    }
}
