// The review card for a connection proposal, one small subview per fact the Kernel reported.
// MeshConnectionAddView and the review screen embed it and supply the bindings and the approve action.

import SwiftUI

struct MeshConnectionCard: View {
    let facts: MeshConnectionCardFacts
    @Binding var phiSource: Bool
    @Binding var selectedTools: Set<String>
    let canApprove: Bool
    let approve: () -> Void

    var body: some View {
        if let change = facts.change { MeshConnectionChangeCard(facts: change) }
        if let a2a = facts.a2a {
            Section {
                MeshConnectionFactRow(label: "Name", value: facts.name, id: "name")
            } header: {
                Text(facts.replacesExisting ? "Review the changes" : "Review this agent")
            }
            MeshConnectionA2ACard(facts: a2a)
            MeshConnectionScopesRow(scopes: facts.scopes)
        } else {
            MeshConnectionPlainFacts(facts: facts)
        }
        MeshConnectionToolsSection(tools: facts.tools, selected: $selectedTools)
        MeshConnectionLabelSection(phiSource: $phiSource)
        Section {
            Button("Approve", action: approve)
                .disabled(!canApprove)
                .accessibilityIdentifier(MeshConnectionID.approve)
        }
    }
}

struct MeshConnectionPlainFacts: View {
    let facts: MeshConnectionCardFacts

    var body: some View {
        Section {
            MeshConnectionFactRow(label: "Name", value: facts.name, id: "name")
            MeshConnectionFactRow(label: "Address", value: facts.address, id: "address")
            MeshConnectionSignInRow(host: facts.signInHost)
            MeshConnectionRedirectRow(host: facts.redirectHost)
            MeshConnectionScopesRow(scopes: facts.scopes)
            MeshConnectionEgressRow(hosts: facts.egress)
        } header: {
            Text(facts.replacesExisting ? "Review the changes" : "Review this connection")
        }
    }
}

struct MeshConnectionFactRow: View {
    let label: String
    let value: String
    let id: String

    var body: some View {
        LabeledContent(label) {
            Text(value).textSelection(.enabled).multilineTextAlignment(.trailing)
        }
        .accessibilityIdentifier(MeshConnectionID.fact(id))
    }
}

struct MeshConnectionSignInRow: View {
    let host: String?

    var body: some View {
        MeshConnectionFactRow(label: "Sign-in site", value: host ?? "No sign-in needed", id: "signin")
    }
}

struct MeshConnectionRedirectRow: View {
    let host: String?

    var body: some View {
        if let host {
            MeshConnectionFactRow(label: "Returns to", value: host, id: "redirect")
        }
    }
}

struct MeshConnectionScopesRow: View {
    let scopes: [String]

    var body: some View {
        MeshConnectionFactRow(
            label: "Permissions", value: scopes.isEmpty ? "None asked" : scopes.joined(separator: ", "), id: "scopes")
    }
}

struct MeshConnectionEgressRow: View {
    let hosts: [String]

    var body: some View {
        MeshConnectionFactRow(
            label: "Reaches", value: hosts.isEmpty ? "Only its own address" : hosts.joined(separator: ", "),
            id: "egress")
    }
}

struct MeshConnectionToolsSection: View {
    let tools: [MeshConnectionCardFacts.Tool]
    @Binding var selected: Set<String>

    var body: some View {
        Section("Tools") {
            if tools.isEmpty {
                Text("No tools yet. They appear for review after you sign in.")
                    .accessibilityIdentifier(MeshConnectionID.noTools)
            }
            ForEach(tools) { tool in
                Toggle(isOn: binding(for: tool.name)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name)
                        Text(tool.shortHash).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier(MeshConnectionID.tool(tool.name))
            }
        }
    }

    private func binding(for name: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(name) },
            set: { on in
                if on { selected.insert(name) } else { selected.remove(name) }
            })
    }
}

struct MeshConnectionLabelSection: View {
    @Binding var phiSource: Bool

    var body: some View {
        Section {
            Toggle("This source holds patient information", isOn: $phiSource)
                .accessibilityIdentifier(MeshConnectionID.phiSource)
        } footer: {
            Text("Its results stay off cloud models until you approve where they may go.")
        }
    }
}
