// The wrist conversation view: crown-scrollable adapted components, dictation-first input with
// confirm-before-send, and voice controls wired to WatchModel and Speaker; mirrors ChatView.swift's markdown
// and icon handling.

import AstralCore
import SwiftUI

struct WatchChatView: View {
    @Environment(WatchModel.self) var model

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if !model.workspaceStarted {
                        if let console = model.console {
                            Text(verbatim: console.labels["title"] ?? "").font(ConsoleTypography.title3)
                            Text(verbatim: console.labels["subtitle"] ?? "").font(ConsoleTypography.footnote)
                            notices
                            inputArea
                            NavigationLink(console.labels["start_here"] ?? "") { WatchConsoleCatalogView() }
                        } else {
                            welcome(.intro)
                            welcome(.permission)
                            notices
                            inputArea
                            welcome(.examples)
                            welcome(.more)
                        }
                    } else {
                        ForEach(model.visibleEntries) { entry in
                            entryView(entry).id(entry.id)
                        }
                        if model.console != nil, !model.workspaceCanvas.isEmpty {
                            resultPreview(model.workspaceCanvas, entryID: nil).id("canvas")
                        } else {
                            ForEach(Array(model.workspaceCanvas.enumerated()), id: \.offset) { _, comp in
                                WatchComponentView(component: comp)
                            }.id("canvas")
                        }
                        notices
                        inputArea
                    }
                }.padding(model.consoleContentInsets)
            }
            .onChange(of: model.visibleEntries.count) { _, _ in
                if let last = model.visibleEntries.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: model.workspaceCanvas.count) { _, count in
                if count > 0 { withAnimation { proxy.scrollTo("canvas", anchor: .bottom) } }
            }
        }
        .navigationTitle("Chat")
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    model.speaker.replay()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .foregroundStyle(.white)
                }
                .accessibilityIdentifier(WatchAccessibility060.replay.identifier)
                .accessibilityLabel(WatchAccessibility060.replay.name)
                .accessibilityValue(WatchAccessibility060.replay.state)
                .disabled(model.voiceSession != nil)
                Spacer()
                let stopAccessibility = WatchAccessibility060.stop(
                    isSpeaking: model.speaker.isSpeaking)
                Button {
                    model.speaker.stop()
                } label: {
                    Image(
                        systemName: model.speaker.isSpeaking
                            ? "speaker.slash.fill" : "speaker.wave.2"
                    )
                    .foregroundStyle(.white)
                }
                .accessibilityIdentifier(stopAccessibility.identifier)
                .accessibilityLabel(stopAccessibility.name)
                .accessibilityValue(stopAccessibility.state)
                .disabled(model.voiceSession != nil)
            }
        }
        .onDisappear { model.speaker.stop() }
    }

    @ViewBuilder
    private var notices: some View {
        if let status = model.statusText {
            let accessibility = WatchAccessibility060.operationStatus(status)
            HStack(spacing: 4) {
                if model.statusShowsActivity {
                    ProgressView().controlSize(.mini)
                }
                Text(InlineMarkdown.attributed(status))
                    .font(ConsoleTypography.footnote).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(accessibility.identifier)
            .accessibilityLabel(accessibility.name)
            .accessibilityValue(accessibility.state)
            .accessibilityAddTraits(.updatesFrequently)
        }
        if let banner = model.errorBanner {
            Label(banner, systemImage: "exclamationmark.triangle")
                .font(ConsoleTypography.footnote)
                .foregroundStyle(model.theme.palette.warning)
        }
    }

    private func welcome(_ role: WorkspaceWelcome.Role) -> some View {
        ForEach(Array(WorkspaceWelcome.components(model.visibleCanvas, for: role).enumerated()), id: \.offset) {
            _, component in
            WatchComponentView(component: component)
        }
    }

    @ViewBuilder
    private func entryView(_ entry: WatchModel.Entry) -> some View {
        switch entry {
        case .user(_, let text, let attachments):
            VStack(alignment: .trailing, spacing: 3) {
                if !text.isEmpty {
                    Text(text)
                        .font(ConsoleTypography.footnote)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .background(
                            model.theme.palette.primary.opacity(0.25),
                            in: RoundedRectangle(cornerRadius: 8))
                }
                ForEach(attachments, id: \.self) { name in
                    Label(name, systemImage: "paperclip")
                        .font(ConsoleTypography.caption2)
                        .lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.gray.opacity(0.25), in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .status(_, let text):
            Text(InlineMarkdown.attributed(MarkdownBlocks.plainText(text)))
                .font(ConsoleTypography.footnote).foregroundStyle(.secondary)
        case .turn(let id, let components):
            if model.console != nil {
                resultPreview(components, entryID: id)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(components.enumerated()), id: \.offset) { _, comp in
                        WatchComponentView(component: comp)
                    }
                }
            }
        }
    }

    private func resultPreview(_ components: [AstralComponent], entryID: String?) -> some View {
        NavigationLink {
            WatchConsoleResultView(entryID: entryID)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: model.consoleLabel("result_default_agent", fallback: "AstralDeep"))
                    .font(ConsoleTypography.headline)
                Text(verbatim: String(components.map(\.fallbackText).joined(separator: "\n").prefix(500)))
                    .font(ConsoleTypography.footnote).lineLimit(5)
                Label(model.consoleLabel("fullscreen"), systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(ConsoleTypography.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxHeight: model.consolePresentation.map { CGFloat($0.resultPreviewMaxHeight) })
            .padding(8)
            .background(model.theme.palette.surface, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }

    @ViewBuilder
    private var inputArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notice = model.voiceTerminalNotice {
                WatchVoiceTerminalNoticeView(notice: notice)
            }
            voiceConversationControls
            if model.console != nil {
                NavigationLink(model.consoleLabel("more")) { WatchConsoleActionsView() }
                    .frame(minHeight: model.consolePresentation?.minimumControlHeight ?? 44)
                if !model.turnSelection.isEmpty {
                    Label(
                        model.console?.selectionSummary(model.turnSelection) ?? model.consoleLabel("advanced"),
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(ConsoleTypography.caption)
                }
            }
            if model.pendingDictation.isEmpty {
                TextFieldLink(prompt: Text("Dictate one message")) {
                    Label("Dictate", systemImage: "text.bubble")
                        .frame(maxWidth: .infinity)
                } onSubmit: { text in
                    model.pendingDictation = text
                }
                .accessibilityIdentifier(WatchAccessibility060.dictate.identifier)
                .accessibilityLabel(WatchAccessibility060.dictate.name)
                .accessibilityValue(WatchAccessibility060.dictate.state)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("“\(model.pendingDictation)”")
                        .font(ConsoleTypography.footnote)
                        .italic()
                    TextFieldLink(prompt: Text(model.consoleLabel("message_placeholder", fallback: "Edit message"))) {
                        Label("Edit", systemImage: "pencil")
                    } onSubmit: {
                        model.pendingDictation = $0
                    }
                    HStack {
                        Button(model.consoleLabel("send", fallback: "Send")) { model.sendPending() }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier(WatchAccessibility060.send.identifier)
                            .accessibilityLabel(WatchAccessibility060.send.name)
                            .accessibilityValue(WatchAccessibility060.send.state)
                        Button("Discard", role: .destructive) {
                            model.pendingDictation = ""
                        }
                        .accessibilityIdentifier(WatchAccessibility060.discard.identifier)
                        .accessibilityLabel(WatchAccessibility060.discard.name)
                        .accessibilityValue(WatchAccessibility060.discard.state)
                    }
                    .font(ConsoleTypography.footnote)
                }
            }
        }.padding(model.consoleComposerInsets)
    }

    @ViewBuilder
    private var voiceConversationControls: some View {
        if model.voiceComposer == nil, model.voiceTerminalNotice == nil {
            // Gate on composer presence, not a visible control
            Button {
            } label: {
                Label("Start voice conversation", systemImage: "mic.fill")
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.theme.palette.primary)
            .disabled(true)
            .accessibilityIdentifier("voice.conversation.primary")
            .accessibilityLabel("Start voice conversation")
            .accessibilityValue("Checking voice availability")
        } else if model.primaryVoiceControl == nil, model.voiceComposer != nil, model.showsVoiceStatus {
            Text(model.voiceStatusLabel)
                .font(ConsoleTypography.caption2)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("voice.conversation.state")
                .accessibilityLabel("Voice conversation")
                .accessibilityValue(model.voiceStatusLabel)
        }
        if let primary = model.primaryVoiceControl {
            Button {
                model.performPrimaryVoiceAction()
            } label: {
                Label(primary.label, systemImage: voiceIcon(primary.icon))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.voiceState.active ? model.theme.palette.warning : model.theme.palette.primary)
            .disabled(!primary.enabled || primary.busy || model.voiceActivationBusy)
            .accessibilityIdentifier("voice.conversation.primary")
            .accessibilityLabel(primary.label)
            .accessibilityValue(model.voiceStatusLabel)

            if model.voiceState.active || model.voiceState == .suspended {
                HStack(spacing: 4) {
                    ForEach(
                        model.visibleVoiceControls.filter {
                            [
                                "voice_microphone_set", "voice_speech_stop",
                                "voice_speech_mute_set", "voice_visible_chat_update",
                                "voice_sensitive_recap_request",
                            ].contains($0.action)
                        },
                        id: \.key
                    ) { control in
                        Button {
                            model.performVoiceAction(control.action)
                        } label: {
                            Image(systemName: voiceIcon(control.icon))
                        }
                        .disabled(!control.enabled || control.busy)
                        .accessibilityIdentifier("voice.conversation.\(control.key)")
                        .accessibilityLabel(control.label)
                        .accessibilityValue(control.pressed ? "On" : "Off")
                    }
                }
            }

            if model.showsVoiceStatus {
                HStack(spacing: 4) {
                    if [.connecting, .speechDetected, .transcribing, .processing, .reconnecting]
                        .contains(model.voiceState)
                    {
                        ProgressView().controlSize(.mini)
                    }
                    Text(model.voiceStatusLabel)
                        .font(ConsoleTypography.caption2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("voice.conversation.state")
                .accessibilityLabel("Voice conversation")
                .accessibilityValue(model.voiceStatusLabel)
            }

            if let partial = model.voicePartialTranscript, !partial.isEmpty {
                Text(partial)
                    .font(ConsoleTypography.caption2)
                    .italic()
                    .lineLimit(3)
                    .accessibilityLabel("Voice transcript: \(partial)")
            }
        }
    }

    private func voiceIcon(_ serverIcon: String) -> String {
        switch serverIcon {
        case "microphone": return "mic.fill"
        case "device-transfer": return "arrow.triangle.2.circlepath"
        case "stop": return "stop.fill"
        case "speaker-stop": return "speaker.slash.fill"
        case "speaker-muted": return "speaker.slash"
        case "speaker-consent": return "speaker.wave.2.bubble"
        case "chat": return "bubble.left.and.bubble.right"
        default: return "waveform"
        }
    }
}

private struct WatchVoiceTerminalNoticeView: View {
    @Environment(WatchModel.self) private var model
    let notice: VoiceTerminalNotice

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(notice.title, systemImage: "exclamationmark.triangle.fill")
                .font(ConsoleTypography.caption.bold())
                .foregroundStyle(model.theme.palette.error)
            Text(notice.serverMessage)
                .font(ConsoleTypography.caption2)
            if let guidance = notice.guidance {
                Text(guidance)
                    .font(ConsoleTypography.caption2)
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            model.theme.palette.error.opacity(0.14),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(model.theme.palette.error.opacity(0.8), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("voice.request.terminal.notice")
        .accessibilityLabel("Voice request alert")
        .accessibilityValue(notice.accessibilityLabel)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
