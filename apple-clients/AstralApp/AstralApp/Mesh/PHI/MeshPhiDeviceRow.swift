// One device on the PHI adoption card: its name, where it stands in the PHI group, its approvals, and the exclude or include control.
// MeshPhiAdoptionCard lists these rows and owns the exclusion confirmation.

import SwiftUI

struct MeshPhiDeviceRow: View {
    let facts: MeshPhiDeviceRowFacts
    let exclude: () -> Void
    let include: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: facts.icon).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(facts.isThisDevice ? facts.label + " (this device)" : facts.label)
                Text(facts.stateLine).font(.footnote).foregroundStyle(.secondary)
                Text(facts.approvalsLine).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            control
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(MeshPhiID.device(facts.id))
    }

    @ViewBuilder
    private var control: some View {
        if facts.canExclude {
            Button("Exclude", role: .destructive, action: exclude)
                .buttonStyle(.borderless)
                .accessibilityIdentifier(MeshPhiID.exclude(facts.id))
        } else if facts.canInclude {
            Button("Include", action: include)
                .buttonStyle(.borderless)
                .accessibilityIdentifier(MeshPhiID.include(facts.id))
        }
    }
}
