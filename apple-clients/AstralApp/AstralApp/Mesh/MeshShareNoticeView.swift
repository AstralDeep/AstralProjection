// A short notice about one share: waiting for the contact to verify, PHI withheld with a Share PHI too action, or shared.
// The text comes from the Kernel's share state and the contact name is drawn as plain text.

import SwiftUI

struct MeshShareNoticeView: View {
    let share: MeshShareInfo
    let onSharePhi: (() -> Void)?
    @Environment(ThemeStore.self) private var theme
    private var p: AstralPalette { theme.palette }

    var body: some View {
        let facts = MeshShareRowFacts(share)
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(p.accent).accessibilityHidden(true)
            Text(verbatim: headline(facts)).font(ConsoleTypography.title3).multilineTextAlignment(.center)
            if share.state == .waiting {
                Text(verbatim: "They have not verified you yet. The chat reaches them once they do.")
                    .font(ConsoleTypography.footnote).foregroundStyle(p.muted).multilineTextAlignment(.center)
                    .accessibilityIdentifier("mesh.share.notice.waiting")
            }
            if let line = facts.phiLine {
                Label(line, systemImage: "cross.case").font(ConsoleTypography.subheadline)
                    .accessibilityIdentifier("mesh.share.notice.phi")
            }
            if facts.canSharePhi, let onSharePhi {
                Button("Share PHI Too", action: onSharePhi)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(MeshShareID.sharePhi)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mesh.share.notice")
    }

    private var icon: String {
        switch share.state {
        case .inEffect: return "checkmark.circle.fill"
        case .waiting: return "hourglass"
        case .revoked: return "xmark.circle"
        }
    }

    private func headline(_ facts: MeshShareRowFacts) -> String {
        switch share.state {
        case .inEffect: return "Shared with " + facts.contactName
        case .waiting: return "Waiting for " + (facts.contactName.isEmpty ? "them" : facts.contactName)
        case .revoked: return "Sharing with " + facts.contactName + " has ended"
        }
    }
}
