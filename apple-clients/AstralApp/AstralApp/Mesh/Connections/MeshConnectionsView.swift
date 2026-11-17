// The Connections list: each outside server this mesh uses, where it is signed in, and a way to add, review or remove one.
// Connections added before this screen existed stay under their own section and open the older manager unchanged.

import SwiftUI

struct MeshConnectionsView: View {
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    @State private var legacy = MeshLegacyServersModel()
    @State private var removing: MeshConnection?
    @State private var signIn: MeshConnectionSignIn?

    var body: some View {
        List {
            Section {
                ForEach(mesh.connections) { connection in
                    MeshConnectionRow(
                        connection: connection, signIn: signIn, remove: { removing = connection })
                }
                NavigationLink {
                    MeshConnectionAddView()
                } label: {
                    Label("Add a connection", systemImage: "plus")
                }
                .accessibilityIdentifier(MeshConnectionID.add)
            }
            MeshConnectionsLegacySection(model: legacy)
        }
        .scrollContentBackground(.hidden)
        .meshReadableWidth()
        .background(theme.palette.bg)
        .navigationTitle("Connections")
        .task {
            if signIn == nil {
                signIn = MeshConnectionSignIn(service: mesh, makeSession: MeshSystemWebAuth.factory)
            }
            await legacy.load(from: mesh)
        }
        .confirmationDialog(
            "Remove this connection?", isPresented: removalShown, titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                guard let target = removing else { return }
                Task { try? await mesh.removeConnection(id: target.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its sign-in is removed from this device and its tools stop working.")
        }
    }
}

private extension MeshConnectionsView {
    var removalShown: Binding<Bool> {
        Binding(get: { removing != nil }, set: { shown in if !shown { removing = nil } })
    }
}

struct MeshConnectionRow: View {
    let connection: MeshConnection
    let signIn: MeshConnectionSignIn?
    let remove: () -> Void

    var body: some View {
        let facts = MeshConnectionRowFacts(connection)
        VStack(alignment: .leading, spacing: 2) {
            Text(facts.name).font(ConsoleTypography.headline)
            Text(facts.host).font(ConsoleTypography.footnote).foregroundStyle(.secondary)
            Text(facts.hereLine).font(ConsoleTypography.caption)
                .accessibilityIdentifier(MeshConnectionID.here(facts.id))
            ForEach(facts.otherLines, id: \.self) { line in
                Text(line).font(ConsoleTypography.caption).foregroundStyle(.secondary)
            }
            if let line = facts.unavailableLine {
                Text(line).font(ConsoleTypography.caption).foregroundStyle(.secondary)
            }
            if let attention = MeshConnectionAttentionFacts(connection) {
                MeshConnectionAttentionBadge(facts: attention)
            }
            MeshConnectionSignInStatus(signIn: signIn, connectionId: facts.id)
            MeshConnectionRowActions(
                facts: facts, canSignIn: connection.supportedHere && connection.scheme == "oauth", signIn: signIn,
                remove: remove)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(MeshConnectionID.row(facts.id))
    }
}

struct MeshConnectionRowActions: View {
    let facts: MeshConnectionRowFacts
    let canSignIn: Bool
    let signIn: MeshConnectionSignIn?
    let remove: () -> Void

    var body: some View {
        HStack {
            if canSignIn, let signIn {
                Button(facts.hereLine == "Signed in here" ? "Sign in again" : "Sign in") {
                    Task { await signIn.signIn(connection: facts.id) }
                }
                .disabled(signIn.isBusy)
                .accessibilityIdentifier(MeshConnectionID.signIn(facts.id))
            }
            if facts.needsReview {
                NavigationLink("Review") { MeshConnectionReviewView(connectionId: facts.id) }
                    .accessibilityIdentifier(MeshConnectionID.review(facts.id))
            }
            Spacer()
            Button("Remove", role: .destructive, action: remove)
                .accessibilityIdentifier(MeshConnectionID.remove(facts.id))
        }
        .buttonStyle(.borderless)
        .font(ConsoleTypography.footnote)
    }
}

struct MeshConnectionsLegacySection: View {
    let model: MeshLegacyServersModel

    var body: some View {
        Section("Added before connections") {
            ForEach(model.rows) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name)
                    Text(row.endpoint).font(ConsoleTypography.footnote).foregroundStyle(.secondary)
                    Text(row.credentialLine).font(ConsoleTypography.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(MeshConnectionID.legacyRow(row.id))
            }
            NavigationLink {
                MeshRemoteMCPView()
            } label: {
                Label("Manage these servers", systemImage: "network")
            }
            .accessibilityIdentifier(MeshConnectionID.legacy)
        }
    }
}

struct MeshConnectionSignInStatus: View {
    let signIn: MeshConnectionSignIn?
    let connectionId: String

    var body: some View {
        if let signIn, signIn.connectionId == connectionId, let text = line(signIn.phase) {
            Text(text)
                .font(ConsoleTypography.caption)
                .accessibilityIdentifier(MeshConnectionID.signInStatus)
        }
    }

    private func line(_ phase: MeshConnectionSignIn.Phase) -> String? {
        switch phase {
        case .idle: return nil
        case .starting, .waiting: return "Signing in..."
        case .completing: return "Finishing..."
        case .signedIn(let pending): return pending ? "Signed in. Review its tools to use them." : "Signed in."
        case .cancelled: return "Sign-in cancelled."
        case .failed(let text): return text
        }
    }
}
