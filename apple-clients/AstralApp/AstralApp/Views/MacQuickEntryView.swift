// Provides a compact macOS composer that sends through the app's existing authenticated chat path.
// It shows the destination and refuses to submit when an attachment, owner session, or project choice is unclear.

#if os(macOS)
    import AstralCore
    import SwiftUI

    struct MacQuickEntryState {
        let signedIn: Bool
        let connected: Bool
        let updateRequired: Bool
        let locked: Bool
        let projectReady: Bool
        let attachmentsPending: Bool
        let mainDraftPending: Bool
        let destination: String

        var canSubmit: Bool {
            signedIn && connected && !updateRequired && !locked && projectReady && !attachmentsPending
                && !mainDraftPending
        }

        var guidance: String {
            if updateRequired { return "Update AstralDeep before sending." }
            if !signedIn { return "Sign in from the main window before sending." }
            if !connected { return "Reconnect before sending." }
            if locked { return "This conversation is read only." }
            if !projectReady { return "Choose a project chat in the main window first." }
            if attachmentsPending { return "Review pending attachments in the main window first." }
            if mainDraftPending { return "Finish the draft in the main window first." }
            return destination
        }
    }

    struct MacQuickEntryView: View {
        let model: AppModel
        let updateRequired: Bool
        @State private var draft = ""
        @FocusState private var focused: Bool
        @Environment(\.openWindow) private var openWindow

        private var state: MacQuickEntryState {
            let chat = model.activeChatId
            let title = chat.flatMap { id in model.history.first { $0.id == id }?.displayTitle }
            let projectReady =
                !model.projects.negotiating
                && (!model.projects.enabled || chat.flatMap { model.projects.project(for: $0) } != nil)
            return MacQuickEntryState(
                signedIn: model.signedIn, connected: model.connected, updateRequired: updateRequired,
                locked: model.screen != .chat || model.isViewingHistory || model.mandatorySurface
                    || model.mutationsLocked, projectReady: projectReady,
                attachmentsPending: !model.staged.isEmpty, mainDraftPending: !model.composerDraft.isEmpty,
                destination: title.map { "Current chat: \($0)" } ?? "New chat")
        }

        var body: some View {
            let current = state
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Quick Entry", systemImage: "sparkles")
                        .font(ConsoleTypography.subheadline)
                    Spacer()
                    Text(current.guidance)
                        .font(ConsoleTypography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .accessibilityIdentifier("mac-quick-entry-destination")
                }
                TextField("Ask AstralDeep", text: $draft, axis: .vertical)
                    .lineLimit(3...6)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .accessibilityIdentifier("mac-quick-entry-input")
                HStack {
                    if model.composerSteeringApplies {
                        Text("This follows the current task's steer or queue setting.")
                            .font(ConsoleTypography.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open chat") {
                        if model.composerDraft.isEmpty { model.composerDraft = draft }
                        MacMainWindow.show(using: openWindow)
                    }
                    Button("Send") { submit() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!current.canSubmit || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("mac-quick-entry-send")
                }
            }
            .padding(20)
            .frame(minWidth: 440, minHeight: 220)
            .onAppear { focused = true }
        }

        private func submit() {
            guard state.canSubmit else { return }
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            model.sendComposerText(text)
            draft = ""
            MacMainWindow.show(using: openWindow)
        }
    }
#endif
