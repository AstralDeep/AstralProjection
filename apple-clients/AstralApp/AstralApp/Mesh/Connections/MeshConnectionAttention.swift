// Turns the Kernel's attention flag on a connection into short text, a list badge and a banner for the chat.
// MeshConnectionsView shows the badge and sign-in action, and MeshSyncStrip shows the banner above the conversation.

import SwiftUI

nonisolated struct MeshConnectionAttentionFacts: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let reason: String?

    init?(_ connection: MeshConnection) {
        guard connection.attention != nil || connection.thisDevice.state == "needs_attention" else { return nil }
        id = connection.id
        name = connection.name
        reason = connection.attention ?? connection.thisDevice.reason
    }

    var line: String { Self.text(reason: reason) }

    var needsReview: Bool { reason == "scope" }

    static func text(reason: String?) -> String {
        switch reason {
        case "scope": return "Needs more permissions. Review them to continue."
        case "expired": return "Your sign-in ended. Sign in again."
        case "refresh_refused": return "The service refused to renew your sign-in. Sign in again."
        default: return "Needs you to sign in again."
        }
    }

    static func all(_ connections: [MeshConnection]) -> [MeshConnectionAttentionFacts] {
        connections.compactMap(MeshConnectionAttentionFacts.init)
    }
}

struct MeshConnectionAttentionBadge: View {
    let facts: MeshConnectionAttentionFacts
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        Label(facts.line, systemImage: "exclamationmark.circle.fill")
            .font(ConsoleTypography.caption)
            .foregroundStyle(theme.palette.warning)
            .accessibilityIdentifier(MeshConnectionID.attention(facts.id))
    }
}

struct MeshConnectionAttentionBanner: View {
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    @State private var showing = false

    var body: some View {
        let items = MeshConnectionAttentionFacts.all(mesh.connections)
        if let first = items.first {
            Button {
                showing = true
            } label: {
                Text(bannerText(first, count: items.count))
                    .font(ConsoleTypography.caption)
                    .foregroundStyle(theme.palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(theme.palette.surface)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(MeshConnectionID.banner)
            .sheet(isPresented: $showing) { NavigationStack { MeshConnectionsView() } }
        }
    }

    private func bannerText(_ first: MeshConnectionAttentionFacts, count: Int) -> String {
        count == 1 ? "\(first.name): \(first.line)" : "\(count) connections need you. Open Connections."
    }
}
