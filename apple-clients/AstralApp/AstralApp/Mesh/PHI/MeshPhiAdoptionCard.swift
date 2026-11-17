// The adoption card: it lists every device with its PHI standing and approvals, adopts the group once, and excludes or re-includes a device.
// Everything shown comes from the Kernel's group view, and each change is one Kernel call that raises the presence prompt itself.

import SwiftUI

struct MeshPhiAdoptionCard: View {
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    @State private var model: MeshPhiGroupModel?
    @State private var excluding: MeshPhiDeviceRowFacts?

    var body: some View {
        Form {
            if let model {
                MeshPhiAdoptionContent(model: model, exclude: { excluding = $0 })
            } else {
                ProgressView()
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .meshReadableWidth()
        .background(theme.palette.bg)
        .navigationTitle("PHI group")
        .accessibilityIdentifier(MeshPhiID.adoptionCard)
        .task {
            let made = MeshPhiGroupModel(service: mesh)
            model = made
            await made.load()
        }
        .confirmationDialog(
            "Exclude this device?", isPresented: excludingShown, titleVisibility: .visible, presenting: excluding
        ) { device in
            Button("Exclude " + device.label, role: .destructive) {
                Task { await model?.exclude(device.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(MeshPhiCopy.exclusionNote)
        }
    }

    private var excludingShown: Binding<Bool> {
        Binding(get: { excluding != nil }, set: { if !$0 { excluding = nil } })
    }
}

private struct MeshPhiAdoptionContent: View {
    let model: MeshPhiGroupModel
    let exclude: (MeshPhiDeviceRowFacts) -> Void

    var body: some View {
        Section {
            ForEach(model.rows) { row in
                MeshPhiDeviceRow(
                    facts: row, exclude: { exclude(row) },
                    include: { Task { await model.include(row.id) } })
            }
        } header: {
            Text("Devices")
        } footer: {
            Text("Only devices in this group can read or write PHI.")
        }
        Section {
            if model.canAdopt {
                Button("Set up PHI on these devices") { Task { await model.adopt() } }
                    .disabled(model.phase != .ready)
                    .accessibilityIdentifier(MeshPhiID.adopt)
            } else if model.adopted {
                Label("PHI is set up", systemImage: "checkmark.circle")
            }
            if let problem = model.problem {
                Text(problem).foregroundStyle(.red).accessibilityIdentifier(MeshPhiID.problem)
            }
        }
    }
}
