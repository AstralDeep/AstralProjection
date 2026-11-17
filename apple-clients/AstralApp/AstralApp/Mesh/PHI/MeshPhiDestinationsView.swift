// The PHI screen reached from Settings and Devices: the PHI group, and each place approved to receive PHI with a way to take it back.
// New approvals start from the provider or connection that owns the destination, so this list has no field for typing one.

import SwiftUI

struct MeshPhiDestinationsView: View {
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    @State private var model: MeshPhiGroupModel?

    var body: some View {
        List {
            Section {
                NavigationLink {
                    MeshPhiAdoptionCard()
                } label: {
                    Label("PHI group", systemImage: "person.2.badge.key")
                }
                .accessibilityIdentifier("mesh.phi.group-link")
            }
            if let model { MeshPhiDestinationRows(model: model) }
        }
        .scrollContentBackground(.hidden)
        .meshReadableWidth()
        .background(theme.palette.bg)
        .navigationTitle("PHI")
        .accessibilityIdentifier(MeshPhiID.destinations)
        .task {
            let made = MeshPhiGroupModel(service: mesh)
            model = made
            await made.load()
        }
    }
}

private struct MeshPhiDestinationRows: View {
    let model: MeshPhiGroupModel

    var body: some View {
        Section {
            ForEach(model.destinationRows) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).textSelection(.enabled)
                    Text(row.statusLine).font(.footnote).foregroundStyle(.secondary)
                    if row.canRevoke {
                        Button("Take back", role: .destructive) { Task { await model.revoke(row.id) } }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier(MeshPhiID.revoke(row.id))
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(MeshPhiID.destination(row.id))
            }
            if model.destinationRows.isEmpty, model.phase == .ready {
                Text("No outside place can receive PHI. Approve one from its model or connection.")
            }
            if let problem = model.problem {
                Text(problem).foregroundStyle(.red).accessibilityIdentifier(MeshPhiID.problem)
            }
        } header: {
            Text("Approved places")
        }
    }
}

struct MeshPhiOfferSheet: View {
    let offer: MeshPhiOffer
    @Environment(MeshRuntime.self) private var mesh

    var body: some View {
        NavigationStack {
            content
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { mesh.presentingPhi = nil }
                    }
                }
        }
        .environment(mesh)
    }

    @ViewBuilder
    private var content: some View {
        switch offer {
        case .adoption: MeshPhiAdoptionCard()
        case .destination(let request): MeshPhiDestinationCard(request: request)
        case .destinations: MeshPhiDestinationsView()
        }
    }
}
