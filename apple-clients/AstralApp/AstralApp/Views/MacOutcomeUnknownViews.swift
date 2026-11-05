// Shows the owner the Outcome unknown card for retained computer jobs whose result never reached the server:
// per-job Inspect opens the local output, Acknowledge and continue and Discard each send exactly one intent,
// a failed delivery keeps the card with Retry, and a card from another account or a stale incarnation after
// relaunch stays a non-actionable banner that names the chat as the place the decision is waiting.

#if os(macOS)
    import SwiftUI

    struct MacOutcomeJobPreview: Equatable, Identifiable {
        let jobId: String
        let state: String
        let output: String
        var id: String { jobId }
    }

    struct MacOutcomeUnknownCardView: View {
        @Environment(AppModel.self) private var model
        @Environment(ThemeStore.self) private var theme
        @State private var inspected: MacOutcomeJobPreview?
        private var p: AstralPalette { theme.palette }

        private var card: AppModel.OutcomeUnknownCard? { model.outcomeUnknownCard }
        private var actionable: Bool { model.outcomeUnknownCardActionable }

        private var bannerText: String {
            let count = card?.jobs.count ?? 0
            return "The chat is waiting for your decision about \(count) earlier computer "
                + (count == 1 ? "action" : "actions") + ". Open the chat to review it."
        }

        var body: some View {
            if let card {
                VStack(alignment: .leading, spacing: 8) {
                    if card.restored {
                        Label {
                            Text(bannerText)
                                .font(ConsoleTypography.subheadline.weight(.semibold))
                        } icon: {
                            Image(systemName: "questionmark.circle").foregroundStyle(p.warning)
                                .accessibilityHidden(true)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("outcome-unknown-banner")
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "questionmark.circle").foregroundStyle(p.warning)
                                .accessibilityHidden(true)
                            Text("Outcome unknown").font(ConsoleTypography.subheadline.weight(.semibold))
                                .accessibilityIdentifier("outcome-unknown-title")
                            Spacer()
                            if card.delivery == .failed {
                                Text("The decision did not reach the server.").font(ConsoleTypography.caption)
                                    .foregroundStyle(p.error)
                                    .accessibilityIdentifier("outcome-unknown-failure")
                                Button("Retry") { model.retryOutcomeUnknown() }
                                    .buttonStyle(AstralButtonStyle(palette: p, variant: "secondary"))
                                    .accessibilityIdentifier("outcome-unknown-retry")
                            }
                        }
                        ForEach(Array(card.jobs.enumerated()), id: \.element.id) { index, job in
                            HStack(spacing: 8) {
                                Text(Self.jobTitle(job)).font(ConsoleTypography.mono(12))
                                    .lineLimit(1).truncationMode(.middle)
                                    .accessibilityIdentifier("outcome-unknown-job-\(index)")
                                Spacer()
                                Button("Inspect") {
                                    inspected = model.outcomeJobPreview(job.id).map {
                                        MacOutcomeJobPreview(jobId: job.id, state: job.state, output: $0.output)
                                    }
                                }
                                .buttonStyle(AstralButtonStyle(palette: p, variant: "secondary"))
                                .disabled(!actionable)
                                .accessibilityIdentifier("outcome-unknown-inspect-\(index)")
                            }
                        }
                        HStack(spacing: 8) {
                            Button("Discard") { model.decideOutcomeUnknown("discard") }
                                .buttonStyle(AstralButtonStyle(palette: p, variant: "secondary"))
                                .disabled(!actionable)
                                .help("Dismiss these earlier unknown results. Other chats keep running.")
                                .accessibilityIdentifier("outcome-unknown-discard")
                            Button("Acknowledge and continue") { model.decideOutcomeUnknown("acknowledge") }
                                .buttonStyle(AstralButtonStyle(palette: p, variant: "primary"))
                                .disabled(!actionable)
                                .accessibilityIdentifier("outcome-unknown-acknowledge")
                            Spacer()
                            if !actionable {
                                Text(
                                    card.decision == nil
                                        ? "Open this Mac's owner session to act." : "Waiting for server confirmation."
                                )
                                .font(ConsoleTypography.caption).foregroundStyle(p.muted)
                                .accessibilityIdentifier("outcome-unknown-note")
                            }
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(p.warning.opacity(0.14)).background(p.bg)
                .overlay(alignment: .bottom) { p.border.frame(height: 1) }
                .accessibilityElement(children: card.restored ? .combine : .contain)
                .accessibilityLabel(card.restored ? "Chat waiting for outcome decision" : "Outcome unknown")
                .accessibilityIdentifier("outcome-unknown-card")
                .sheet(item: $inspected) { preview in
                    MacOutcomePreviewSheet(preview: preview, palette: p)
                }
            }
        }

        static func jobTitle(_ job: OutcomeUnknownRecordJob) -> String {
            var parts = [String(job.id.prefix(8)), job.state]
            if let exitCode = job.exitCode { parts.append("exit \(exitCode)") }
            if let signal = job.signal { parts.append("signal \(signal)") }
            parts.append(Self.size(job.outputBytes))
            return parts.joined(separator: " · ")
        }

        static func size(_ bytes: Int) -> String {
            bytes >= 1_048_576
                ? String(format: "%.1f MB", Double(bytes) / 1_048_576)
                : bytes >= 1024 ? String(format: "%.1f KB", Double(bytes) / 1024) : "\(bytes) B"
        }
    }

    struct MacOutcomePreviewSheet: View {
        let preview: MacOutcomeJobPreview
        let palette: AstralPalette
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Command output").font(ConsoleTypography.subheadline.weight(.semibold))
                        .accessibilityIdentifier("outcome-preview-title")
                    Spacer()
                    Button("Close") { dismiss() }
                        .buttonStyle(AstralButtonStyle(palette: palette, variant: "secondary"))
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("outcome-preview-close")
                }
                ScrollView {
                    Text(preview.output.isEmpty ? "No output was captured." : preview.output)
                        .font(ConsoleTypography.mono(12)).frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("outcome-preview-output")
                }
                .frame(minHeight: 160, maxHeight: 420)
            }
            .padding(16).frame(width: 560)
        }
    }
#endif
