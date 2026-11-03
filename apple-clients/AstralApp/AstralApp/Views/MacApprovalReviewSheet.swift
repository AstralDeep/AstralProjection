// Shows every text and code entry of a pending review card in full, selectable monospaced text before Deny or Allow.
// MacApprovalBanner presents it for cards that need a full read; both buttons send the card's own decisions through
// AppModel, and the sheet closes when the card is no longer pending.

#if os(macOS)
    import SwiftUI

    struct MacApprovalReviewSheet: View {
        @Environment(AppModel.self) private var model
        @Environment(ThemeStore.self) private var theme
        @Environment(\.dismiss) private var dismiss
        let prompt: AppModel.ApprovalPrompt
        private var p: AstralPalette { theme.palette }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: prompt.title ?? "Review approval").font(ConsoleTypography.headline)
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("approval-review-title")
                if prompt.hiddenCharacters {
                    Label {
                        Text(verbatim: "Contains hidden or direction-changing characters, shown as \\u{…} escapes.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(ConsoleTypography.caption.weight(.semibold)).foregroundStyle(p.warning)
                    .accessibilityIdentifier("approval-review-warning")
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(prompt.details.enumerated()), id: \.offset) { index, detail in
                            Text(verbatim: detail).font(ConsoleTypography.mono(12)).foregroundStyle(p.text)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("approval-review-detail-\(index)")
                        }
                    }
                    .padding(12)
                }
                .frame(minHeight: 120, maxHeight: 440)
                .background(p.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: AstralRadius.sm))
                .overlay(RoundedRectangle(cornerRadius: AstralRadius.sm).stroke(p.border))
                HStack {
                    Spacer()
                    Button("Deny") { decide(allow: false) }.keyboardShortcut(.cancelAction)
                        .buttonStyle(AstralButtonStyle(palette: p, variant: "secondary"))
                        .accessibilityIdentifier("approval-review-deny")
                    Button("Allow") { decide(allow: true) }.keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(AstralButtonStyle(palette: p, variant: "primary"))
                        .accessibilityIdentifier("approval-review-allow")
                }
            }
            .font(ConsoleTypography.subheadline).foregroundStyle(p.text)
            .padding(20).frame(width: 620).background(p.surface)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Review approval")
            .accessibilityIdentifier("approval-review-sheet")
            .onChange(of: model.approvalPrompts, initial: true) { _, pending in
                if !pending.contains(prompt) { dismiss() }
            }
        }

        private func decide(allow: Bool) {
            model.decideApproval(prompt, allow: allow)
            dismiss()
        }
    }
#endif
