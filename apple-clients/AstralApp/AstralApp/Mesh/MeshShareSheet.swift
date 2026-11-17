// The Share Chat sheet: it lists verified contacts, then draws the share card from the Kernel's proposal with a PHI row that opens the destination card.
// Share asks for presence through the Kernel's consent prompt, and no button appears while the contact is unverified or the PHI destination is missing.

import SwiftUI

struct MeshShareSheet: View {
    let chatId: String
    var contact: String?
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ConsentCoordinator.self) private var consent
    @Environment(ThemeStore.self) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var model: MeshShareModel?
    @State private var phiRequest: MeshPhiDestinationRequest?
    private var p: AstralPalette { theme.palette }

    var body: some View {
        NavigationStack {
            Group {
                if let model { content(model) } else { ProgressView() }
            }
            .background(p.bg)
            .navigationTitle("Share Chat")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .task {
                let made = MeshShareModel(chatId: chatId, shares: mesh, contacts: mesh)
                model = made
                await made.load()
                if let contact, let found = made.candidates.first(where: { $0.mesh == contact }) {
                    await made.pick(found)
                }
            }
            .sheet(item: $phiRequest) { request in phiCard(request) }
        }
        #if os(macOS)
            .frame(minWidth: 460, minHeight: 520)
        #endif
        .consentSheet(consent)
        .accessibilityIdentifier(MeshShareID.sheet)
    }

    @ViewBuilder
    private func content(_ model: MeshShareModel) -> some View {
        switch model.phase {
        case .choosing: choosing(model)
        case .loading: ProgressView("Checking").accessibilityIdentifier("mesh.share.loading")
        case .reviewing(let facts): card(facts, model: model, busy: false)
        case .sharing(let facts): card(facts, model: model, busy: true)
        case .shared(let info): shared(info)
        case .failed(let message): failed(message, model: model)
        }
    }

    private func choosing(_ model: MeshShareModel) -> some View {
        List {
            Section("Share with") {
                ForEach(model.candidates) { candidate in
                    Button {
                        Task { await model.pick(candidate) }
                    } label: {
                        candidateRow(candidate)
                    }
                    .buttonStyle(.plain)
                    .disabled(!candidate.isVerified)
                    .accessibilityLabel(candidate.name + (candidate.isVerified ? "" : ", not verified"))
                    .accessibilityIdentifier(MeshShareID.candidate(candidate.mesh))
                }
            }
            if let notice = model.notice { Text(notice).foregroundStyle(p.warning) }
        }
        .overlay {
            if model.candidates.isEmpty {
                ContentUnavailableView {
                    Label("No contacts yet", systemImage: "person.2")
                } description: {
                    Text("Add and verify a contact first.")
                }
            }
        }
    }

    private func candidateRow(_ candidate: MeshShareCandidate) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: candidate.name).font(ConsoleTypography.headline)
            Text(candidate.fingerprint).font(.system(.footnote, design: .monospaced)).foregroundStyle(p.muted)
            if let hint = candidate.hint { Text(hint).font(ConsoleTypography.caption).foregroundStyle(p.warning) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func card(_ facts: MeshShareCardFacts, model: MeshShareModel, busy: Bool) -> some View {
        Form {
            Section {
                LabeledContent("Chat") { Text(verbatim: facts.title) }
                LabeledContent("With") { Text(verbatim: facts.contactName) }
                LabeledContent("Mesh") { Text(facts.fingerprint).font(.system(.footnote, design: .monospaced)) }
                Text(facts.summary).foregroundStyle(p.muted)
            }
            if let row = facts.phiRow { phiRow(row, facts: facts) }
            if let refusal = facts.refusal {
                Text(refusal).foregroundStyle(p.error).accessibilityIdentifier("mesh.share.refusal")
            }
            if facts.canShare {
                Button {
                    Task { await model.share() }
                } label: {
                    Text(facts.isUpgrade ? "Share PHI Too" : "Share").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(busy)
                .accessibilityHint("Asks for your approval")
                .accessibilityIdentifier(MeshShareID.confirm)
            }
            Button("Choose Someone Else") { model.back() }
                .buttonStyle(.borderless)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier(MeshShareID.card)
    }

    @ViewBuilder
    private func phiRow(_ row: MeshSharePhiRow, facts: MeshShareCardFacts) -> some View {
        Section("PHI") {
            switch row {
            case .included:
                Label("This chat holds PHI. It will be included.", systemImage: "cross.case")
                    .accessibilityIdentifier(MeshShareID.phiRow)
            case .needsDestination:
                Label("This chat holds PHI. Approve this contact for PHI first.", systemImage: "cross.case")
                    .accessibilityIdentifier(MeshShareID.phiRow)
                if facts.offersDestinationCard {
                    Button("Approve Where PHI May Go") {
                        phiRequest = .contact(mesh: facts.proposal.contact)
                    }
                    .meshBordered()
                    .accessibilityIdentifier(MeshShareID.destination)
                }
            }
        }
    }

    private func phiCard(_ request: MeshPhiDestinationRequest) -> some View {
        NavigationStack {
            MeshPhiDestinationCard(request: request) {
                phiRequest = nil
                Task { await model?.reload() }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { phiRequest = nil } }
            }
        }
        .environment(mesh)
        .consentSheet(consent)
    }

    private func shared(_ info: MeshShareInfo) -> some View {
        MeshShareNoticeView(share: info, onSharePhi: nil)
            .padding(24)
    }

    private func failed(_ message: String, model: MeshShareModel) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundStyle(p.warning)
                .accessibilityHidden(true)
            Text(message).multilineTextAlignment(.center).accessibilityIdentifier("mesh.share.error")
            Button("Try Again") { Task { await model.reload() } }
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }
}

extension MeshPhiDestinationRequest: Identifiable {
    var id: String { String(describing: self) }
}
