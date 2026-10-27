// Shows the oldest pending review card in the Mac main window, naming the browser site when the card asks to open
// one, with Allow and Deny that send the card's own decisions through AppModel. MacWorkbenchView places it under the
// toolbar so it stays reachable when the canvas or browser pane is hidden.

#if os(macOS)
    import SwiftUI

    struct MacApprovalBanner: View {
        @Environment(AppModel.self) private var model
        @Environment(ThemeStore.self) private var theme
        let prompt: AppModel.ApprovalPrompt
        private var p: AstralPalette { theme.palette }

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill").foregroundStyle(p.warning).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    if let site = prompt.site {
                        Text(site).font(ConsoleTypography.subheadline.weight(.semibold)).lineLimit(1)
                            .truncationMode(.middle).accessibilityIdentifier("approval-banner-site")
                    }
                    Text(prompt.summary).font(ConsoleTypography.caption)
                        .foregroundStyle(prompt.site == nil ? p.text : p.muted).lineLimit(2)
                        .accessibilityIdentifier("approval-banner-summary")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Deny") { model.decideApproval(prompt, allow: false) }
                    .buttonStyle(AstralButtonStyle(palette: p, variant: "secondary"))
                    .accessibilityIdentifier("approval-banner-deny")
                Button("Allow") { model.decideApproval(prompt, allow: true) }
                    .buttonStyle(AstralButtonStyle(palette: p, variant: "primary"))
                    .accessibilityIdentifier("approval-banner-allow")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(p.warning.opacity(0.14)).background(p.bg)
            .overlay(alignment: .bottom) { p.border.frame(height: 1) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Approval waiting")
            .accessibilityIdentifier("approval-banner")
        }
    }
#endif
