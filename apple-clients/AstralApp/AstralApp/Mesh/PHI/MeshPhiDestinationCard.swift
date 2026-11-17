// The warning card for one PHI destination: its name and canonical address, the three plain facts, and a single approve button.
// It opens for one named destination from the provider, connection, devices or settings screens and approves only that one.

import SwiftUI

struct MeshPhiDestinationCard: View {
    let request: MeshPhiDestinationRequest
    var onFinished: () -> Void = {}
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    @State private var model: MeshPhiDestinationModel?

    var body: some View {
        Form {
            if let model {
                MeshPhiDestinationContent(model: model, adopt: { mesh.presentingPhi = .adoption })
            } else {
                ProgressView()
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .meshReadableWidth()
        .background(theme.palette.bg)
        .navigationTitle("PHI destination")
        .accessibilityIdentifier(MeshPhiID.destinationCard)
        .task(id: request) {
            let made = MeshPhiDestinationModel(service: mesh)
            model = made
            await made.load(request)
        }
        .onChange(of: model?.phase) { _, phase in
            if phase == .approved { onFinished() }
        }
    }
}

private struct MeshPhiDestinationContent: View {
    let model: MeshPhiDestinationModel
    let adopt: () -> Void

    var body: some View {
        if let facts = model.facts {
            MeshPhiFactsSection(facts: facts)
            if facts.needsApproval { MeshPhiWarningSection(lines: facts.lines) }
        }
        MeshPhiDestinationFooter(model: model, adopt: adopt)
    }
}

private struct MeshPhiFactsSection: View {
    let facts: MeshPhiCardFacts

    var body: some View {
        Section {
            LabeledContent("Name", value: facts.name)
                .accessibilityIdentifier(MeshPhiID.fact("name"))
            LabeledContent(facts.kindLine) {
                Text(facts.endpoint).textSelection(.enabled).multilineTextAlignment(.trailing)
            }
            .accessibilityIdentifier(MeshPhiID.fact("endpoint"))
            if facts.onThisDeviceOnly {
                Text("Only this device may send it PHI.").foregroundStyle(.secondary)
                    .accessibilityIdentifier(MeshPhiID.fact("local"))
            }
        }
    }
}

private struct MeshPhiWarningSection: View {
    let lines: [String]

    var body: some View {
        Section("Before you approve") {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Label(line, systemImage: "exclamationmark.triangle")
                    .accessibilityIdentifier(MeshPhiID.line(index))
            }
        }
    }
}

private struct MeshPhiDestinationFooter: View {
    let model: MeshPhiDestinationModel
    let adopt: () -> Void

    var body: some View {
        Section {
            switch model.phase {
            case .loading: ProgressView()
            case .reviewing, .approving: approveButton
            case .approved: Label("Approved", systemImage: "checkmark.circle")
            case .notNeeded: Text("This runs on this device, so it needs no approval.")
            case .failed: EmptyView()
            }
            if let problem = model.problem {
                Text(problem).foregroundStyle(.red).accessibilityIdentifier(MeshPhiID.problem)
            }
            if model.offersAdoption {
                Button("Set up PHI", action: adopt).accessibilityIdentifier(MeshPhiID.openAdoption)
            }
        }
    }

    private var approveButton: some View {
        Button("Approve this one") { Task { await model.approve() } }
            .disabled(!model.canApprove)
            .accessibilityIdentifier(MeshPhiID.approve)
    }
}
