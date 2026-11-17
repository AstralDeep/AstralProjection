// The add screen for an A2A agent: its card address, a key when the card asks for one, then the agent card and any change card for review.
// MeshConnectionsView opens it, MeshConnectionCard shows the proposal, and signing in afterwards goes through MeshConnectionSignIn or the key screen.

import Observation
import SwiftUI

@MainActor
protocol MeshConnectionA2AService: MeshConnectionService {
    func proposeA2AConnection(cardURL: String, name: String, key: String?, recipients: [String]?) async throws
        -> MeshConnectionProposal
}

extension MeshRuntime: MeshConnectionA2AService {}

@MainActor
@Observable
final class MeshConnectionA2AModel {
    enum Phase: Equatable {
        case entering
        case proposing
        case needsKey
        case reviewing
    }

    private let service: any MeshConnectionA2AService
    let review: MeshConnectionAddModel
    private(set) var phase: Phase = .entering
    private(set) var problem: String?
    var cardURL = ""
    var name = ""
    var key = ""
    var recipients: [String]?

    init(service: any MeshConnectionA2AService) {
        self.service = service
        review = MeshConnectionAddModel(service: service)
    }

    var canContinue: Bool {
        guard phase == .entering || phase == .needsKey, recipients?.isEmpty != true else { return false }
        if cardURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        return phase == .entering || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func propose() async {
        guard canContinue else { return }
        let address: String = cardURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let label: String = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret: String? = key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : key
        let shared: [String]? = recipients
        key = ""
        phase = .proposing
        problem = nil
        do {
            let proposal = try await service.proposeA2AConnection(
                cardURL: address, name: label.isEmpty ? Self.defaultName(address) : label, key: secret,
                recipients: shared)
            review.present(proposal)
            phase = .reviewing
        } catch {
            if (error as? MeshKernelError)?.code == "connection.key_required" {
                phase = .needsKey
            } else {
                problem = MeshRuntime.describe(error)
                phase = .entering
            }
        }
    }

    func clear() {
        key = ""
    }

    private static func defaultName(_ address: String) -> String {
        URLComponents(string: address)?.host ?? "Agent"
    }
}

struct MeshConnectionA2AAddView: View {
    @Environment(MeshRuntime.self) private var mesh

    var body: some View { MeshConnectionA2AAddScreen(model: MeshConnectionA2AModel(service: mesh)) }
}

private struct MeshConnectionA2AAddScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeStore.self) private var theme
    @Environment(MeshRuntime.self) private var mesh
    @State private var model: MeshConnectionA2AModel

    init(model: MeshConnectionA2AModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        @Bindable var model = model
        @Bindable var review = model.review
        Form {
            if let facts = review.facts {
                MeshConnectionCard(
                    facts: facts, phiSource: $review.phiSource, selectedTools: $review.selectedTools,
                    canApprove: review.canApprove, approve: { Task { await review.approve() } })
            } else {
                MeshConnectionA2AFields(model: model, members: mesh.members)
            }
            if let problem = model.problem ?? review.problem {
                Section {
                    Text(problem).foregroundStyle(theme.palette.error)
                        .accessibilityIdentifier(MeshConnectionID.error)
                }
            }
            if model.phase == .proposing || review.phase == .approving {
                Section { ProgressView().accessibilityIdentifier(MeshConnectionID.working) }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .meshReadableWidth()
        .background(theme.palette.bg)
        .navigationTitle("Add an agent")
        .onDisappear { model.clear() }
        .onChange(of: review.phase) { _, phase in
            if case .done = phase { dismiss() }
        }
    }
}

private struct MeshConnectionA2AFields: View {
    @Bindable var model: MeshConnectionA2AModel
    let members: [MeshMember]

    var body: some View {
        Section {
            TextField("Card address", text: $model.cardURL)
                .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                #endif
                .accessibilityIdentifier(MeshConnectionID.cardAddress)
            TextField("Name (optional)", text: $model.name)
                .accessibilityIdentifier(MeshConnectionID.name)
        } footer: {
            Text("The agent's card is read and checked before you approve anything.")
        }
        if model.phase == .needsKey {
            Section {
                SecureField("Key", text: $model.key)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityLabel("Key")
                    .accessibilityIdentifier(MeshConnectionID.key)
            } footer: {
                Text("This agent needs a key. Paste it here yourself.")
            }
            Section("Sharing") {
                MeshProviderRecipientsPicker(recipients: $model.recipients, members: members)
            }
        }
        Section {
            Button("Continue") { Task { await model.propose() } }
                .disabled(!model.canContinue)
                .accessibilityIdentifier(MeshConnectionID.proceed)
        }
    }
}
