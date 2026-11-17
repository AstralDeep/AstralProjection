// The change card for an A2A agent whose card moved since you approved it: hosts added or dropped, a changed tool, the signer now on the card and the extended card.
// MeshConnectionCard shows it above the agent card on a review, and the agent stays blocked until you approve.

import SwiftUI

nonisolated struct MeshA2AChangeFacts: Equatable, Sendable {
    let addedHosts: [String]
    let removedHosts: [String]
    let toolChanged: Bool
    let signer: String?
    let nowUnsigned: Bool
    let extendedPending: Bool

    init?(_ proposal: MeshConnectionProposal, previous: MeshConnection?) {
        guard proposal.kind == "a2a", proposal.replaces != nil, let card = proposal.card else { return nil }
        let before: Set<String> = Set((previous?.egress ?? []).map(MeshA2ACardFacts.host))
        let after: Set<String> = Set(proposal.egress.map(MeshA2ACardFacts.host))
        addedHosts = after.subtracting(before).sorted()
        removedHosts = previous == nil ? [] : before.subtracting(after).sorted()
        let held: Set<MeshConnectionTool> = Set(previous?.tools ?? [])
        toolChanged = previous != nil && Set(proposal.tools) != held
        signer = card.signed ? card.signer.map(MeshConnectionCardFacts.shortHash) : nil
        nowUnsigned = !card.signed
        extendedPending = card.extendedPending
    }

    var blockedLine: String { "Blocked until you approve." }
}

struct MeshConnectionChangeCard: View {
    let facts: MeshA2AChangeFacts
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        Section("What changed") {
            Label(facts.blockedLine, systemImage: "hand.raised.fill")
                .foregroundStyle(theme.palette.warning)
                .accessibilityIdentifier(MeshConnectionID.a2aBlocked)
            MeshConnectionHostsRow(label: "Now reaches", hosts: facts.addedHosts, id: "change.added")
            MeshConnectionHostsRow(label: "No longer reaches", hosts: facts.removedHosts, id: "change.removed")
            if facts.toolChanged {
                MeshConnectionFactRow(label: "Tool", value: "Changed", id: "change.tool")
            }
            if let signer = facts.signer {
                MeshConnectionFactRow(label: "Signed by", value: signer, id: "change.signer")
            }
            if facts.nowUnsigned {
                MeshConnectionFactRow(label: "Signature", value: "Not signed", id: "change.unsigned")
            }
            if facts.extendedPending {
                MeshConnectionFactRow(label: "Extended card", value: "Changed. Review it.", id: "change.extended")
            }
        }
    }
}
