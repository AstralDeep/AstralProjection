// The caller tickets screen: every ticket this mesh issued with its node, tools and expiry, plus copy, revoke and a way to make a new one.
// Revoking asks first and the presence prompt that follows belongs to the Kernel; MeshSettingsView links here.

import SwiftUI

struct MeshCallersView: View {
    @Environment(MeshRuntime.self) private var mesh

    var body: some View { MeshCallersScreen(runtime: mesh) }
}

private struct MeshCallersScreen: View {
    let runtime: MeshRuntime
    @State private var model: MeshCallersModel
    @State private var creating = false
    @Environment(ThemeStore.self) private var theme
    private var p: AstralPalette { theme.palette }

    init(runtime: MeshRuntime) {
        self.runtime = runtime
        _model = State(initialValue: MeshCallersModel(runtime: runtime))
    }

    var body: some View {
        Form {
            MeshCallerList(model: model)
            Section {
                Button {
                    creating = true
                } label: {
                    Label("New Caller Ticket", systemImage: "plus.circle.fill")
                }
                .accessibilityIdentifier("mesh.callers.new")
            } footer: {
                Text("A caller ticket lets a script or another app use chosen tools on your node.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(p.bg)
        .navigationTitle("Caller Tickets")
        .task { await runtime.refreshCallerTickets() }
        .sheet(isPresented: $creating) { MeshCallerTicketEditor(runtime: runtime) }
        .confirmationDialog(
            "Revoke this ticket?",
            isPresented: Binding(get: { model.pendingRevoke != nil }, set: { if !$0 { model.cancelRevoke() } }),
            titleVisibility: .visible
        ) {
            Button("Revoke", role: .destructive) { Task { await model.confirmRevoke() } }
            Button("Cancel", role: .cancel) { model.cancelRevoke() }
        } message: {
            Text("The caller can no longer use \(model.pendingRevoke?.label ?? "it"). This cannot be undone.")
        }
    }
}

private struct MeshCallerList: View {
    let model: MeshCallersModel
    @Environment(ThemeStore.self) private var theme
    private var p: AstralPalette { theme.palette }

    var body: some View {
        Section {
            if model.tickets.isEmpty {
                Text("No caller tickets yet.").foregroundStyle(p.muted).accessibilityIdentifier("mesh.callers.empty")
            }
            ForEach(model.tickets) { MeshCallerRow(ticket: $0, model: model) }
            if let failure = model.failure {
                Text(failure).foregroundStyle(p.error).accessibilityIdentifier("mesh.callers.failure")
            }
        }
    }
}

private struct MeshCallerRow: View {
    let ticket: MeshCallerTicket
    let model: MeshCallersModel
    @Environment(ThemeStore.self) private var theme
    @State private var copied = false
    private var p: AstralPalette { theme.palette }

    private var status: String {
        if ticket.revoked { return "Revoked" }
        if ticket.expired { return "Expired" }
        return "Expires " + ticket.expiresAt.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ticket.label).font(ConsoleTypography.headline)
            Text("On \(model.nodeLabel(ticket)). \(status)").font(ConsoleTypography.caption).foregroundStyle(p.muted)
            Text(ticket.tools.joined(separator: ", ")).font(.system(.caption, design: .monospaced))
                .foregroundStyle(p.muted)
            HStack {
                Button(copied ? "Copied" : "Copy") { copied = ComponentPasteboard.copy(ticket.text) }
                    .accessibilityIdentifier("mesh.callers.copy.\(ticket.id)")
                if !ticket.revoked {
                    Button("Revoke", role: .destructive) { model.askRevoke(ticket) }
                        .accessibilityIdentifier("mesh.callers.revoke.\(ticket.id)")
                }
            }
            .buttonStyle(.borderless)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mesh.callers.row.\(ticket.id)")
    }
}
