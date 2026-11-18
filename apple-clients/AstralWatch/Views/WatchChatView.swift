// The wrist conversation view: the chat the paired iPhone relays rendered through WatchComponentView, dictation-first input with confirm-before-send, a stop control while the phone runs, and voice on the phone.
// It reads and writes only WatchModel, which talks to the phone and never to a server.

import AstralCore
import SwiftUI

struct WatchChatView: View {
    @Environment(WatchModel.self) var model

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Not lazy: scrolling a lazy stack to a trailing navigation link re-lays it out forever on watchOS.
                VStack(alignment: .leading, spacing: 8) {
                    transcript
                    notices
                    inputArea
                }.padding(.horizontal, 4)
            }
            .onChange(of: model.chatComponents.count) { _, count in
                if count > 0 { withAnimation { proxy.scrollTo("transcript", anchor: .bottom) } }
            }
        }
        .navigationTitle(model.activeChatTitle.isEmpty ? "Chat" : model.activeChatTitle)
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
                .disabled(model.companionVoiceActive)
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
            }
        }
        .onDisappear { model.speaker.stop() }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.chatComponents.isEmpty {
                ProgressView("Loading the chat…")
                    .font(ConsoleTypography.footnote)
            }
            ForEach(Array(model.chatComponents.enumerated()), id: \.offset) { _, component in
                WatchComponentView(component: component)
            }
        }
        .id("transcript")
    }

    @ViewBuilder
    private var notices: some View {
        if model.runActive {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(model.runState == .stopping ? "Stopping…" : "Working on your iPhone…")
                    .font(ConsoleTypography.footnote).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Stop") { model.stopRun() }
                    .font(ConsoleTypography.footnote)
                    .disabled(model.runState == .stopping)
                    .accessibilityIdentifier("watch-stop-run")
            }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.updatesFrequently)
        } else if let status = model.statusText {
            Text(status)
                .font(ConsoleTypography.footnote).foregroundStyle(.secondary)
                .accessibilityAddTraits(.updatesFrequently)
        }
        if !model.connected {
            Label("Your iPhone is out of reach", systemImage: "iphone.slash")
                .font(ConsoleTypography.footnote)
                .accessibilityIdentifier("watch-chat-offline")
        }
        if let banner = model.errorBanner {
            Label(banner, systemImage: "exclamationmark.triangle")
                .font(ConsoleTypography.footnote)
                .foregroundStyle(model.theme.palette.warning)
                .accessibilityIdentifier("watch-chat-error")
        }
    }

    @ViewBuilder
    private var inputArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            voiceConversationControls
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
                draft
            }
        }
    }

    private var draft: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("“\(model.pendingDictation)”")
                .font(ConsoleTypography.footnote)
                .italic()
            TextFieldLink(prompt: Text("Edit message")) {
                Label("Edit", systemImage: "pencil")
            } onSubmit: {
                model.pendingDictation = $0
            }
            HStack {
                Button("Send") { model.sendPending() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.connected)
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

    @ViewBuilder
    private var voiceConversationControls: some View {
        let active = model.companionVoiceActive
        Button {
            model.performPrimaryVoiceAction()
        } label: {
            Label(active ? "Stop voice" : "Start voice on iPhone", systemImage: active ? "stop.fill" : "mic.fill")
                .lineLimit(2)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(active ? model.theme.palette.warning : model.theme.palette.primary)
        .accessibilityIdentifier("voice.conversation.primary")
        .accessibilityLabel(active ? "Stop voice" : "Start voice on iPhone")
        .accessibilityValue(model.voiceStatusLabel)
        if active || model.voiceMessage != nil {
            HStack(spacing: 4) {
                if model.voiceActivationBusy { ProgressView().controlSize(.mini) }
                Text(model.voiceStatusLabel).font(ConsoleTypography.caption2).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("voice.conversation.state")
            .accessibilityLabel("Voice conversation")
            .accessibilityValue(model.voiceStatusLabel)
        }
        if let partial = model.voicePartialTranscript, !partial.isEmpty {
            Text(partial).font(ConsoleTypography.caption2).italic().lineLimit(3)
                .accessibilityLabel("Voice transcript: \(partial)")
        }
    }
}
