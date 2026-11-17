// The list of chats other people share with this person, each marked as from its contact and showing whether it can be read yet.
// It reads MeshRuntime's shared items, opens a chat read only, and starts the code comparison for a contact who is not verified.

import SwiftUI

struct MeshSharedWithMeView: View {
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    @State private var verifying: MeshContactExchange?
    @State private var problem: String?
    private var p: AstralPalette { theme.palette }

    var body: some View {
        List {
            ForEach(mesh.sharedItems) { item in
                row(item)
            }
            if let problem { Text(problem).foregroundStyle(p.error) }
        }
        .accessibilityIdentifier(MeshSharedID.list)
        .overlay {
            if mesh.sharedItems.isEmpty {
                ContentUnavailableView {
                    Label("Nothing shared with you", systemImage: "tray")
                } description: {
                    Text("Chats your contacts share show up here.")
                }
            }
        }
        .background(p.bg)
        .navigationTitle("Shared with Me")
        .task { await mesh.refreshSharedItems() }
        .sheet(item: $verifying) { exchange in MeshContactCompareSheet(exchange: exchange) }
    }

    @ViewBuilder
    private func row(_ item: MeshSharedItem) -> some View {
        let facts = MeshSharedRowFacts(item)
        if facts.canOpen {
            NavigationLink {
                MeshSharedChatView(item: item)
            } label: {
                label(facts)
            }
            .accessibilityIdentifier(MeshSharedID.row(item.grant))
        } else {
            label(facts).accessibilityIdentifier(MeshSharedID.row(item.grant))
        }
    }

    private func label(_ facts: MeshSharedRowFacts) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: facts.title).font(ConsoleTypography.headline).lineLimit(1)
            Text(verbatim: facts.badge.text).font(ConsoleTypography.footnote).foregroundStyle(p.muted)
            if let line = facts.stateLine {
                Text(verbatim: line).font(ConsoleTypography.caption).foregroundStyle(p.warning)
            }
            if let line = facts.withheldLine {
                Text(line).font(ConsoleTypography.caption).foregroundStyle(p.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
