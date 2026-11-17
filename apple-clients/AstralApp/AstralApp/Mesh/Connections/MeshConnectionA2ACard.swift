// The facts and card for an A2A agent: who signed it, whether it is signed at all, and which hosts it signs in with and talks to.
// MeshConnectionCard shows it for an agent proposal, and every fact comes from the Kernel's proposal rather than from chat text.

import SwiftUI

nonisolated struct MeshA2ACardFacts: Equatable, Sendable {
    let url: String
    let signed: Bool
    let signer: String?
    let scheme: String
    let authHosts: [String]
    let interfaceHosts: [String]
    let skills: [String]
    let extendedPending: Bool

    init?(_ proposal: MeshConnectionProposal) {
        guard proposal.kind == "a2a", let card = proposal.card else { return nil }
        url = card.url
        signed = card.signed
        signer = card.signer.map(MeshConnectionCardFacts.shortHash)
        scheme = proposal.scheme
        let auth: [String] = [proposal.issuerHost, proposal.redirectHost].compactMap { $0 }
        authHosts = Self.unique(auth)
        let own: Set<String> = Set([Self.host(card.url)] + auth)
        interfaceHosts = Self.unique(proposal.egress.map(Self.host).filter { !own.contains($0) })
        skills = card.skills
        extendedPending = card.extendedPending
    }

    var signedLine: String {
        guard signed else { return "Not signed" }
        return signer.map { "Signed by \($0)" } ?? "Signed"
    }

    var unsignedWarning: String { "This card is not signed. Anyone could have changed it." }

    var schemeLine: String {
        switch scheme {
        case "oauth": return "Signs in with its own site"
        case "key": return "Uses a key you paste"
        default: return "No sign-in"
        }
    }

    static func host(_ entry: String) -> String {
        guard entry.contains("://"), let host = URLComponents(string: entry)?.host else { return entry }
        return host
    }

    private static func unique(_ hosts: [String]) -> [String] {
        var seen: Set<String> = []
        return hosts.filter { seen.insert($0).inserted }
    }
}

struct MeshConnectionA2ACard: View {
    let facts: MeshA2ACardFacts
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        Section("Agent card") {
            MeshConnectionFactRow(label: "Card", value: facts.url, id: "a2a.card")
            MeshConnectionFactRow(label: "Signature", value: facts.signedLine, id: "a2a.signer")
            if !facts.signed {
                Label(facts.unsignedWarning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.palette.warning)
                    .accessibilityIdentifier(MeshConnectionID.a2aUnsigned)
            }
            MeshConnectionFactRow(label: "Sign-in", value: facts.schemeLine, id: "a2a.scheme")
            MeshConnectionHostsRow(label: "Sign-in sites", hosts: facts.authHosts, id: "a2a.auth")
            MeshConnectionHostsRow(label: "Talks to", hosts: facts.interfaceHosts, id: "a2a.interfaces")
            if !facts.skills.isEmpty {
                MeshConnectionFactRow(label: "Skills", value: facts.skills.joined(separator: ", "), id: "a2a.skills")
            }
        }
    }
}

struct MeshConnectionHostsRow: View {
    let label: String
    let hosts: [String]
    let id: String

    var body: some View {
        if !hosts.isEmpty {
            MeshConnectionFactRow(label: label, value: hosts.joined(separator: ", "), id: id)
        }
    }
}
