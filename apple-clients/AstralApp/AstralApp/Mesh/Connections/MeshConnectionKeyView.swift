// The pasted-key screen: an address when the connection is new, a secure key field, the header choice for an HTTP API and who may use the key.
// MeshConnectionsView opens it for a key connection, and a new connection continues into the review card from its proposal.

import SwiftUI

struct MeshConnectionKeyView: View {
    @Environment(MeshRuntime.self) private var mesh

    let target: MeshConnectionKeyModel.Target

    var body: some View {
        MeshConnectionKeyScreen(model: MeshConnectionKeyModel(service: mesh, target: target), service: mesh)
    }
}

private struct MeshConnectionKeyScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeStore.self) private var theme
    @Environment(MeshRuntime.self) private var mesh
    @State private var model: MeshConnectionKeyModel
    @State private var review: MeshConnectionAddModel

    init(model: MeshConnectionKeyModel, service: any MeshConnectionService) {
        _model = State(initialValue: model)
        _review = State(initialValue: MeshConnectionAddModel(service: service))
    }

    var body: some View {
        @Bindable var model = model
        @Bindable var review = review
        Form {
            if let facts = review.facts {
                MeshConnectionCard(
                    facts: facts, phiSource: $review.phiSource, selectedTools: $review.selectedTools,
                    canApprove: review.canApprove, approve: { Task { await review.approve() } })
            } else {
                MeshConnectionKeyFields(model: model, members: mesh.members)
            }
            if let problem = model.problem ?? review.problem {
                Section {
                    Text(problem).foregroundStyle(theme.palette.error)
                        .accessibilityIdentifier(MeshConnectionID.error)
                }
            }
            if model.phase == .saving || review.phase == .approving {
                Section { ProgressView().accessibilityIdentifier(MeshConnectionID.working) }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .meshReadableWidth()
        .background(theme.palette.bg)
        .navigationTitle("Key")
        .onDisappear { model.clear() }
        .onChange(of: model.phase) { _, phase in
            if phase == .saved { dismiss() }
            if phase == .proposed, let proposal = model.proposal { review.present(proposal) }
        }
        .onChange(of: review.phase) { _, phase in
            if case .done = phase { dismiss() }
        }
    }
}

struct MeshConnectionKeyFields: View {
    @Bindable var model: MeshConnectionKeyModel
    let members: [MeshMember]

    var body: some View {
        if model.needsAddress { MeshConnectionKeyAddress(model: model) }
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
            Text("Paste it here yourself. A chat or a model can never fill it in.")
        }
        if model.showsHeader { MeshConnectionKeyHeader(model: model) }
        Section("Sharing") {
            MeshProviderRecipientsPicker(recipients: $model.recipients, members: members)
        }
        Section {
            Button("Save") { Task { await model.save() } }
                .disabled(!model.canSave)
                .accessibilityIdentifier(MeshConnectionID.keySave)
        }
    }
}

private struct MeshConnectionKeyAddress: View {
    @Bindable var model: MeshConnectionKeyModel

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
        }
    }
}

private struct MeshConnectionKeyHeader: View {
    @Bindable var model: MeshConnectionKeyModel

    var body: some View {
        Section("Header") {
            TextField("Header name", text: $model.header)
                .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
                .accessibilityIdentifier(MeshConnectionID.keyHeader)
            Picker("Format", selection: $model.format) {
                ForEach(MeshKeyFormat.allCases) { format in
                    Text(format.label).tag(format)
                }
            }
            .accessibilityIdentifier(MeshConnectionID.keyFormat)
        }
    }
}
