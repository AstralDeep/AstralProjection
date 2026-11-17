// The sheet that asks about an uncertain PHI match: each finding's kind and excerpt, and two answers, send or treat as PHI.
// MeshShell presents it from MeshPhiPromptCenter, and closing it without a tap counts as treat as PHI.

import SwiftUI

struct MeshPhiPromptSheet: View {
    let request: MeshPhiPromptRequest
    let center: MeshPhiPromptCenter

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(request.question.items.enumerated()), id: \.offset) { index, item in
                        MeshPhiPromptItemRow(item: item, index: index)
                    }
                } header: {
                    Text("This may be patient information")
                } footer: {
                    Text("Send keeps it as it is. Treat as PHI keeps it off cloud models.")
                }
                Section {
                    Button("Treat as PHI") { center.answer(.treatAsPhi) }
                        .accessibilityIdentifier(MeshPhiPromptID.treat)
                    Button("Send") { center.answer(.send) }
                        .accessibilityIdentifier(MeshPhiPromptID.send)
                }
            }
            .navigationTitle("Check this text")
        }
        .accessibilityIdentifier(MeshPhiPromptID.sheet)
        .onDisappear { center.expire(request.id) }
    }
}

private struct MeshPhiPromptItemRow: View {
    let item: MeshPhiQuestionItem
    let index: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(MeshPhiPromptCopy.kind(item.kind)).font(.headline)
            Text(item.excerpt).font(.body)
            Text(MeshPhiPromptCopy.source(item.source)).font(.footnote).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(MeshPhiPromptID.item(index))
    }
}

nonisolated enum MeshPhiPromptID {
    static let sheet = "mesh.phi.prompt"
    static let send = "mesh.phi.prompt.send"
    static let treat = "mesh.phi.prompt.treat"
    static func item(_ index: Int) -> String { "mesh.phi.prompt.item.\(index)" }
}

nonisolated enum MeshPhiPromptCopy {
    static func kind(_ kind: String) -> String {
        switch kind {
        case "name": return "A name"
        case "date": return "A date"
        case "contact": return "Contact details"
        case "identifier": return "An identifier"
        case "address": return "An address"
        default: return "Something that may identify a person"
        }
    }

    static func source(_ source: String) -> String {
        switch source {
        case "message": return "In your message"
        case "attachment": return "In a file"
        case "tool_result": return "In a tool result"
        default: return "In this chat"
        }
    }
}
