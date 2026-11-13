// Chat list and conversation screens for mesh mode, drawn from MeshRuntime's local log through the shared ChatBubble and ComponentView renderers.
// They show queued messages as queued, branches as branches, streamed text, tool activity, approvals waiting, outcome-unknown steps and the honest sync state.

import AstralCore
import SwiftUI

struct MeshChatRow: View {
    let chat: MeshChatSummary
    @Environment(ThemeStore.self) private var theme
    private var p: AstralPalette { theme.palette }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(chat.title).font(ConsoleTypography.headline).lineLimit(1)
            if !chat.preview.isEmpty {
                Text(MeshModelText.plainPreview(chat.preview))
                    .font(ConsoleTypography.footnote).foregroundStyle(p.muted).lineLimit(2)
            }
            if chat.queuedCount > 0 || chat.branchCount > 0 {
                HStack(spacing: 10) {
                    if chat.queuedCount > 0 {
                        Label("\(chat.queuedCount) waiting to send", systemImage: "clock")
                            .accessibilityIdentifier("mesh.chat.queued.\(chat.chatId)")
                    }
                    if chat.branchCount > 0 {
                        Label(chat.branchCount == 1 ? "1 branch" : "\(chat.branchCount) branches", systemImage: "arrow.triangle.branch")
                    }
                }
                .font(ConsoleTypography.caption).foregroundStyle(p.muted)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mesh.chat.\(chat.chatId)")
    }
}

struct MeshChatListView: View {
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    @Binding var selection: String?
    private var p: AstralPalette { theme.palette }

    var body: some View {
        List(selection: $selection) {
            ForEach(mesh.chats) { chat in
                MeshChatRow(chat: chat).tag(chat.chatId)
            }
        }
        .overlay {
            if mesh.chats.isEmpty {
                ContentUnavailableView {
                    Label("No chats yet", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Start one and it shows up on every device.")
                } actions: {
                    Button("New Chat") { Task { selection = await mesh.newChat() } }
                        .buttonStyle(.borderedProminent)
                }
                .accessibilityIdentifier("mesh.chats.empty")
            }
        }
        .navigationTitle("Chats")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { selection = await mesh.newChat() }
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("mesh.chats.new")
            }
        }
    }
}

struct MeshChatDetailView: View {
    @Environment(MeshRuntime.self) private var mesh
    @Environment(AppModel.self) private var model
    @Environment(ThemeStore.self) private var theme
    @State private var draft = ""
    @State private var requesting: MeshMember?
    private var p: AstralPalette { theme.palette }

    var body: some View {
        VStack(spacing: 0) {
            #if os(iOS)
                MeshSyncStrip()
            #endif
            transcript
            Divider().overlay(p.border)
            composer
        }
        .background(p.bg)
        .navigationTitle(mesh.currentChat?.title ?? "Chat")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if !otherMembers.isEmpty {
                ToolbarItem(placement: .primaryAction) { chatMenu }
            }
        }
        .sheet(item: $requesting) { member in
            NavigationStack {
                MeshSendRequestView(member: member, initialText: draft)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { requesting = nil } }
                    }
            }
                #if os(macOS)
                    .frame(minWidth: 420, minHeight: 360)
                #endif
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(mesh.displayRows) { row in
                        MeshMessageRow(row: row)
                    }
                    MeshChatRequestList()
                    MeshTurnActivityView()
                    Color.clear.frame(height: 1).id("mesh-bottom")
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: 780)
                .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("mesh.transcript")
            .onChange(of: mesh.displayRows.count) { _, _ in
                withAnimation { proxy.scrollTo("mesh-bottom", anchor: .bottom) }
            }
            .onChange(of: mesh.currentTurn?.streamingText) { _, _ in
                proxy.scrollTo("mesh-bottom", anchor: .bottom)
            }
        }
    }

    private var running: Bool { mesh.currentTurn?.running == true }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(running ? "Steer the answer" : "Message", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(p.surface2, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(p.border, lineWidth: 1))
                .accessibilityIdentifier("mesh.composer")
                .onSubmit(send)
            Button {
                Task { await model.onDeviceVoice.activate() }
            } label: {
                Image(systemName: model.onDeviceVoice.isRunning ? "mic.fill" : "mic").font(.title3)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .foregroundStyle(p.accent)
            .help("Talk")
            .accessibilityLabel("Talk")
            .accessibilityIdentifier("mesh.composer.mic")
            if running {
                Button {
                    Task { await mesh.interrupt() }
                } label: {
                    Image(systemName: "stop.circle.fill").font(.title).frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.accent)
                .help("Stop")
                .accessibilityLabel("Stop")
                .accessibilityIdentifier("mesh.composer.stop")
            }
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.title).frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSend ? p.accent : p.muted)
            .disabled(!canSend)
            .help(running ? "Steer" : "Send")
            .accessibilityLabel(running ? "Steer" : "Send")
            .accessibilityIdentifier("mesh.composer.send")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: 780)
        .frame(maxWidth: .infinity)
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var otherMembers: [MeshMember] { mesh.members.filter { !$0.isThisDevice } }

    private var chatMenu: some View {
        Menu {
            ForEach(otherMembers) { member in
                Button("Send a Request to " + member.label, systemImage: "paperplane") { requesting = member }
            }
        } label: {
            Label("Chat options", systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("mesh.chat.menu")
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            let accepted = running ? await steer(text) : await mesh.send(text)
            if accepted, draft == text { draft = "" }
        }
    }

    private func steer(_ text: String) async -> Bool {
        await mesh.steer(text)
        return true
    }
}

struct MeshMessageRow: View {
    let row: MeshChatMapper.Row
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    private var p: AstralPalette { theme.palette }

    var body: some View {
        VStack(alignment: row.turn.role == "user" ? .trailing : .leading, spacing: 4) {
            ChatBubble(turn: row.turn)
                .environment(\.astralMeshAction, surfaceAction)
            if let message = row.message {
                if message.delivery == .queued {
                    Label("Waiting to send", systemImage: "clock")
                        .font(ConsoleTypography.caption).foregroundStyle(p.muted)
                        .accessibilityIdentifier("mesh.message.queued")
                }
                branchSwitcher(for: message)
            }
        }
        .frame(maxWidth: .infinity, alignment: row.turn.role == "user" ? .trailing : .leading)
        .contextMenu {
            if let message = row.message {
                Button("Branch from here", systemImage: "arrow.triangle.branch") {
                    Task { await mesh.branchFrom(message: message) }
                }
                Button("Copy", systemImage: "doc.on.doc") { ComponentPasteboard.copy(message.text) }
            }
        }
    }

    private var surfaceAction: @MainActor @Sendable (String, String, [String: JSONValue]) -> Void {
        let surfaces = row.message?.surfaceIds ?? []
        return { componentId, capability, args in
            guard let surfaceId = surfaces.first else { return }
            Task { await mesh.act(surfaceId: surfaceId, componentId: componentId, capability: capability, args: args) }
        }
    }

    @ViewBuilder
    private func branchSwitcher(for message: MeshChatMessage) -> some View {
        if let view = mesh.currentChat {
            let siblings = MeshChatTree.siblings(of: message, in: view.messages)
            if siblings.count > 1, let index = siblings.firstIndex(where: { $0.eventId == message.eventId }) {
                HStack(spacing: 10) {
                    Button {
                        mesh.selectBranch(head: siblings[index - 1].eventId)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(index == 0)
                    .accessibilityLabel("Previous branch")
                    Text("Branch \(index + 1) of \(siblings.count)").font(ConsoleTypography.caption)
                    Button {
                        mesh.selectBranch(head: siblings[index + 1].eventId)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(index == siblings.count - 1)
                    .accessibilityLabel("Next branch")
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.accent)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("mesh.message.branches")
            }
        }
    }
}

struct MeshTurnActivityView: View {
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    private var p: AstralPalette { theme.palette }

    var body: some View {
        if let turn = mesh.currentTurn {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(turn.tools) { tool in
                    HStack(spacing: 6) {
                        switch tool.state {
                        case .running: ProgressView().controlSize(.small)
                        case .succeeded: Image(systemName: "checkmark.circle").foregroundStyle(p.success)
                        case .failed: Image(systemName: "xmark.circle").foregroundStyle(p.error)
                        }
                        Text(tool.name).font(ConsoleTypography.footnote)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("mesh.tool.\(tool.id)")
                }
                if turn.running, turn.streamingText.isEmpty, turn.tools.isEmpty, turn.awaitingConsent == nil {
                    StatusLine(text: "Working", showsActivity: true)
                }
                if turn.awaitingConsent != nil {
                    Label("Waiting for your approval", systemImage: "hand.raised")
                        .font(ConsoleTypography.footnote).foregroundStyle(p.warning)
                        .accessibilityIdentifier("mesh.turn.awaiting")
                }
                if turn.interrupted {
                    Text("Stopped").font(ConsoleTypography.footnote).foregroundStyle(p.muted)
                }
                if turn.answeredOnDevice {
                    Label("Answered on this device. Add a model in Settings for fuller answers.", systemImage: "cpu")
                        .font(ConsoleTypography.footnote).foregroundStyle(p.muted)
                        .accessibilityIdentifier("mesh.turn.on-device")
                }
                if let failure = turn.failure {
                    Text(failure).font(ConsoleTypography.footnote).foregroundStyle(p.error)
                        .accessibilityIdentifier("mesh.turn.failure")
                    if mesh.providers.isEmpty, !mesh.onDeviceModelAvailable {
                        Text("No model is set up. Add one in Settings.")
                            .font(ConsoleTypography.footnote).foregroundStyle(p.muted)
                    }
                }
                ForEach(turn.unknown.filter(mesh.outcomeNeedsAttention)) { outcome in
                    MeshUnknownOutcomeCard(outcome: outcome)
                }
            }
        }
    }
}

struct MeshUnknownOutcomeCard: View {
    let outcome: MeshUnknownOutcome
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    private var p: AstralPalette { theme.palette }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Not sure this ran: \(outcome.tool)", systemImage: "questionmark.circle")
                .font(ConsoleTypography.headline).foregroundStyle(p.warning)
            Text(MeshModelText.plainPreview(outcome.summary)).font(ConsoleTypography.footnote)
            Text("The step was sent but no answer came back. It will not run again by itself.")
                .font(ConsoleTypography.footnote).foregroundStyle(p.muted)
            HStack {
                Button("Check it") { Task { await mesh.resolveUnknown(outcome, choice: .checkFirst) } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("mesh.unknown.check")
                Button("Leave it") { Task { await mesh.resolveUnknown(outcome, choice: .leaveAsUnknown) } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("mesh.unknown.leave")
            }
            .controlSize(.regular)
        }
        .padding(12)
        .background(p.surface2, in: RoundedRectangle(cornerRadius: AstralRadius.md))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mesh.unknown.\(outcome.stepId)")
    }
}

struct MeshSyncStrip: View {
    var showsSync = true
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    private var p: AstralPalette { theme.palette }

    var body: some View {
        VStack(spacing: 0) {
            if mesh.status.stopped {
                strip("Every device is stopped. Resume it in Devices.", color: p.error, id: "stopped")
            }
            if let notice = mesh.networkNotice {
                strip(notice, color: p.warning, id: "network")
            }
            if showsSync, case .waiting = mesh.syncSummary {
                strip(MeshPresentation.syncLine(mesh.syncSummary), color: p.muted, id: "sync")
            }
        }
    }

    private func strip(_ text: String, color: Color, id: String) -> some View {
        Text(text)
            .font(ConsoleTypography.caption)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(p.surface)
            .accessibilityIdentifier("mesh.strip.\(id)")
    }
}

struct MeshConsentCards: View {
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    private var p: AstralPalette { theme.palette }

    var body: some View {
        VStack(spacing: 6) {
            ForEach(mesh.pendingConsents) { request in
                let prompt = mesh.prompt(for: request)
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(p.warning).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(prompt?.actionTitle ?? "Unreadable approval request")
                            .font(ConsoleTypography.subheadline.weight(.semibold)).lineLimit(1)
                        if let source = prompt?.untrustedSource {
                            Label("Influenced by untrusted content", systemImage: "exclamationmark.triangle.fill")
                                .font(ConsoleTypography.caption).foregroundStyle(p.warning)
                                .accessibilityLabel("Influenced by untrusted content: \(source)")
                        } else {
                            Text("Needs your approval").font(ConsoleTypography.caption).foregroundStyle(p.muted)
                        }
                    }
                    Spacer(minLength: 8)
                    if prompt != nil {
                        Button("Review") { Task { await mesh.review(request) } }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("mesh.consent.review")
                    }
                    Button("Deny", role: .destructive) { Task { await mesh.deny(request) } }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("mesh.consent.deny")
                }
                .controlSize(.small)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(p.surface2, in: RoundedRectangle(cornerRadius: AstralRadius.md))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("mesh.consent.\(request.requestId)")
            }
        }
        .padding(.horizontal, mesh.pendingConsents.isEmpty ? 0 : 12)
        .padding(.vertical, mesh.pendingConsents.isEmpty ? 0 : 6)
    }
}
