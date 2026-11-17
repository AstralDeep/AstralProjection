// The add screen: an address form, then the review card the Kernel's proposal fills in.
// MeshConnectionsView presents it, and MeshConnectionReviewView reuses the card for pending tools and extra permissions.

import SwiftUI

struct MeshConnectionAddView: View {
    @Environment(MeshRuntime.self) private var mesh

    var body: some View { MeshConnectionAddScreen(model: MeshConnectionAddModel(service: mesh)) }
}

struct MeshConnectionReviewView: View {
    @Environment(MeshRuntime.self) private var mesh
    let connectionId: String

    var body: some View {
        MeshConnectionAddScreen(model: MeshConnectionAddModel(service: mesh), reviewing: connectionId)
    }
}

private struct MeshConnectionAddScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeStore.self) private var theme
    @State private var model: MeshConnectionAddModel
    private let reviewing: String?

    init(model: MeshConnectionAddModel, reviewing: String? = nil) {
        _model = State(initialValue: model)
        self.reviewing = reviewing
    }

    var body: some View {
        @Bindable var model = model
        Form {
            if reviewing == nil && model.facts == nil { MeshConnectionAddressSection(model: model) }
            if let facts = model.facts {
                MeshConnectionCard(
                    facts: facts, phiSource: $model.phiSource, selectedTools: $model.selectedTools,
                    canApprove: model.canApprove,
                    approve: { Task { await model.approve() } })
            }
            if let problem = model.problem {
                Section {
                    Text(problem).foregroundStyle(theme.palette.error)
                        .accessibilityIdentifier(MeshConnectionID.error)
                }
            }
            if model.phase == .proposing || model.phase == .approving {
                Section { ProgressView().accessibilityIdentifier(MeshConnectionID.working) }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .meshReadableWidth()
        .background(theme.palette.bg)
        .navigationTitle(reviewing == nil ? "Add a connection" : "Review")
        .task { if let reviewing { await model.review(connection: reviewing) } }
        .onChange(of: model.phase) { _, phase in
            if case .done = phase { dismiss() }
        }
    }
}

private struct MeshConnectionAddressSection: View {
    @Bindable var model: MeshConnectionAddModel

    var body: some View {
        Section {
            TextField("Address", text: $model.endpoint)
                .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                #endif
                .accessibilityIdentifier(MeshConnectionID.address)
            TextField("Name (optional)", text: $model.name)
                .accessibilityIdentifier(MeshConnectionID.name)
            if model.showsLocalToggle {
                Toggle("This server runs on this device", isOn: $model.local)
                    .accessibilityIdentifier(MeshConnectionID.local)
            }
            Button("Continue") { Task { await model.propose() } }
                .disabled(!model.canContinue)
                .accessibilityIdentifier(MeshConnectionID.proceed)
        } footer: {
            Text("The server is asked for its sign-in and tools before you approve anything.")
        }
    }
}
