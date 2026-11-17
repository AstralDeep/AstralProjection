// The contact list: each person with a plain-text name, their fingerprint, whether they are verified and any notice about their devices.
// Adding and verifying open the invite, accept and code screens, and removal asks first.

import SwiftUI

struct MeshContactsView: View {
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    @State private var adding: MeshContactAddChoice?
    @State private var verifying: MeshContactExchange?
    @State private var removing: MeshContact?
    @State private var problem: String?
    private var p: AstralPalette { theme.palette }

    var body: some View {
        List {
            ForEach(mesh.contacts) { contact in
                MeshContactRow(contact: contact, onVerify: { verify(contact) }, onRemove: { removing = contact })
            }
            if let problem {
                Text(problem).foregroundStyle(p.error).accessibilityIdentifier("mesh.contacts.problem")
            }
        }
        .accessibilityIdentifier(MeshContactID.list)
        .overlay { if mesh.contacts.isEmpty { empty } }
        .background(p.bg)
        .navigationTitle("Contacts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Show My Invitation", systemImage: "qrcode") { adding = .invite }
                        .accessibilityIdentifier(MeshContactID.add + ".invite")
                    Button("Use Their Invitation", systemImage: "person.badge.plus") { adding = .accept }
                        .accessibilityIdentifier(MeshContactID.add + ".accept")
                } label: {
                    Label("Add Contact", systemImage: "person.badge.plus")
                }
                .accessibilityIdentifier(MeshContactID.add)
            }
        }
        .task { await mesh.refreshContacts() }
        .sheet(item: $adding) { choice in
            MeshContactFlowSheet(choice: choice)
        }
        .sheet(item: $verifying) { exchange in
            MeshContactCompareSheet(exchange: exchange)
        }
        .confirmationDialog(
            "Remove this contact?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove Contact", role: .destructive) { removeConfirmed() }
                .accessibilityIdentifier(MeshContactID.remove + ".confirm")
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("Chats you shared with them stop. What they already have stays with them.")
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("No contacts yet", systemImage: "person.2")
        } description: {
            Text("Add someone to share a chat with them.")
        }
        .accessibilityIdentifier(MeshContactID.empty)
    }

    private func verify(_ contact: MeshContact) {
        Task {
            do { verifying = try await mesh.startContactVerification(mesh: contact.mesh) } catch {
                problem = MeshRuntime.describe(error)
            }
        }
    }

    private func removeConfirmed() {
        guard let contact = removing else { return }
        removing = nil
        Task {
            do { try await mesh.removeContact(mesh: contact.mesh) } catch { problem = MeshRuntime.describe(error) }
        }
    }
}

enum MeshContactAddChoice: String, Identifiable {
    case invite, accept
    var id: String { rawValue }
}

struct MeshContactRow: View {
    let contact: MeshContact
    let onVerify: () -> Void
    let onRemove: () -> Void
    @Environment(ThemeStore.self) private var theme
    private var p: AstralPalette { theme.palette }

    var body: some View {
        let facts = MeshContactRowFacts(contact)
        VStack(alignment: .leading, spacing: 6) {
            header(facts)
            Text(facts.fingerprint).font(.system(.footnote, design: .monospaced)).foregroundStyle(p.muted)
            if let warning = facts.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(ConsoleTypography.footnote).foregroundStyle(p.warning)
                    .accessibilityIdentifier(MeshContactID.row(contact.mesh) + ".warning")
            }
            ForEach(Array(facts.notices.enumerated()), id: \.offset) { _, line in
                Label(line, systemImage: "info.circle").font(ConsoleTypography.footnote).foregroundStyle(p.muted)
            }
            actions(facts)
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier(MeshContactID.row(contact.mesh))
    }

    private func header(_ facts: MeshContactRowFacts) -> some View {
        HStack {
            Text(verbatim: facts.name).font(ConsoleTypography.headline).lineLimit(1)
            Spacer()
            Label(facts.stateLine, systemImage: facts.isVerified ? "checkmark.seal.fill" : "questionmark.circle")
                .font(ConsoleTypography.caption)
                .foregroundStyle(facts.isVerified ? p.success : p.warning)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(facts.name + ", " + facts.stateLine)
    }

    private func actions(_ facts: MeshContactRowFacts) -> some View {
        HStack {
            if !facts.isVerified {
                Button("Verify", action: onVerify)
                    .meshBordered()
                    .accessibilityLabel("Verify " + facts.name)
                    .accessibilityIdentifier(MeshContactID.verifyAgain + "." + contact.mesh)
            }
            Button("Remove", role: .destructive, action: onRemove)
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove " + facts.name)
                .accessibilityIdentifier(MeshContactID.remove + "." + contact.mesh)
        }
    }
}

struct MeshContactFlowSheet: View {
    let choice: MeshContactAddChoice
    var initialText = ""
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ConsentCoordinator.self) private var consent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch choice {
                case .invite: MeshContactInviteView(service: mesh)
                case .accept: MeshContactAcceptView(service: mesh, initialText: initialText)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        #if os(macOS)
            .frame(minWidth: 460, minHeight: 520)
        #endif
        .consentSheet(consent)
    }
}

struct MeshContactCompareSheet: View {
    let exchange: MeshContactExchange
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ConsentCoordinator.self) private var consent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            MeshContactCodeView(model: MeshContactCompareModel(service: mesh, exchange: exchange))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                }
        }
        #if os(macOS)
            .frame(minWidth: 460, minHeight: 520)
        #endif
        .consentSheet(consent)
    }
}
