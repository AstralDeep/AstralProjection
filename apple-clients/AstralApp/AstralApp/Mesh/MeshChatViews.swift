// Chat list and conversation screens for mesh mode, drawn from MeshRuntime's local log through the shared ChatBubble and ComponentView renderers.
// They show queued messages as queued, branches as branches, streamed text, tool activity, approvals waiting, outcome-unknown steps and the honest sync state.

import AstralCore
import SwiftUI

struct MeshChatListView: View {
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    @Binding var selection: String?
    private var p: AstralPalette { theme.palette }

    var body: some View {
        List(selection: $selection) {
            if mesh.chats.isEmpty {
                Text("No chats yet. Start one with the plus button.")
                    .foregroundStyle(p.muted)
                    .accessibilityIdentifier("mesh.chats.empty")
            }
            ForEach(mesh.chats) { chat in
                VStack(alignment: .leading, spacing: 3) {
                    Text(chat.title).font(ConsoleTypography.headline).lineLimit(1)
                    if !chat.preview.isEmpty {
                        Text(MeshModelText.plainPreview(chat.preview))
                            .font(ConsoleTypography.footnote).foregroundStyle(p.muted).lineLimit(2)
                    }
                    HStack(spacing: 10) {
                        if chat.queuedCount > 0 {
                            Label("\(chat.queuedCount) queued", systemImage: "clock")
                        }
                        if chat.branchCount > 0 {
                            Label("\(chat.branchCount) branches", systemImage: "arrow.triangle.branch")
                        }
                    }
                    .font(ConsoleTypography.caption).foregroundStyle(p.muted)
                }
                .tag(chat.chatId)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("mesh.chat.\(chat.chatId)")
            }
        }
        .navigationTitle("Chats")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { selection = await mesh.newChat() }
                } label: {
                    Label("New chat", systemImage: "square.and.pencil")
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
    private var p: AstralPalette { theme.palette }

    var body: some View {
        VStack(spacing: 0) {
            MeshSyncStrip()
            transcript
            Divider().overlay(p.border)
            composer
        }
        .background(p.bg)
        .navigationTitle(mesh.currentChat?.title ?? "Chat")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
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
                .padding(.horizontal, 12).padding(.vertical, 8)
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
        HStack(alignment: .bottom, spacing: 8) {
            TextField(running ? "Steer the answer" : "Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("mesh.composer")
                .onSubmit(send)
            requestMenu
            Button {
                Task { await model.onDeviceVoice.activate() }
            } label: {
                Image(systemName: model.onDeviceVoice.isRunning ? "mic.fill" : "mic")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Talk")
            .accessibilityIdentifier("mesh.composer.mic")
            if running {
                Button {
                    Task { await mesh.interrupt() }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Stop")
                .accessibilityIdentifier("mesh.composer.stop")
            }
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(running ? "Steer" : "Send")
            .accessibilityIdentifier("mesh.composer.send")
        }
        .padding(12)
    }

    private var otherMembers: [MeshMember] { mesh.members.filter { !$0.isThisDevice } }

    private var requestMenu: some View {
        Menu {
            ForEach(otherMembers) { member in
                Button("Send to " + member.label) {
                    let text = draft
                    Task { if await mesh.sendRequest(text, to: member) { draft = "" } }
                }
            }
        } label: {
            Image(systemName: "paperplane")
        }
        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || otherMembers.isEmpty)
        .accessibilityLabel("Send as a request to another device")
        .accessibilityIdentifier("mesh.composer.request")
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
                    Label("Queued", systemImage: "clock")
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
            Label("Outcome unknown: \(outcome.tool)", systemImage: "questionmark.circle")
                .font(ConsoleTypography.headline).foregroundStyle(p.warning)
            Text(MeshModelText.plainPreview(outcome.summary)).font(ConsoleTypography.footnote)
            Text("The step was sent, but no result came back. It will not be repeated on its own.")
                .font(ConsoleTypography.footnote).foregroundStyle(p.muted)
            HStack {
                Button("Check first") { Task { await mesh.resolveUnknown(outcome, choice: .checkFirst) } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("mesh.unknown.check")
                Button("Leave it") { Task { await mesh.resolveUnknown(outcome, choice: .leaveAsUnknown) } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("mesh.unknown.leave")
            }
        }
        .padding(12)
        .background(p.surface2, in: RoundedRectangle(cornerRadius: AstralRadius.md))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mesh.unknown.\(outcome.stepId)")
    }
}

struct MeshSyncStrip: View {
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    private var p: AstralPalette { theme.palette }

    var body: some View {
        VStack(spacing: 0) {
            if mesh.status.stopped {
                strip("The mesh is stopped. Nothing will run until you resume it in Devices.", color: p.error, id: "stopped")
            }
            if let notice = mesh.networkNotice {
                strip(notice, color: p.warning, id: "network")
            }
            strip(MeshPresentation.syncLine(mesh.syncSummary), color: p.muted, id: "sync")
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
        VStack(spacing: 8) {
            ForEach(mesh.pendingConsents) { request in
                let prompt = mesh.prompt(for: request)
                VStack(alignment: .leading, spacing: 6) {
                    Text(prompt?.actionTitle ?? "Unreadable approval request").font(ConsoleTypography.headline)
                    if let prompt {
                        Text(prompt.target).font(ConsoleTypography.footnote).foregroundStyle(p.muted)
                        if let source = prompt.untrustedSource {
                            Label("Influenced by untrusted content", systemImage: "exclamationmark.triangle.fill")
                                .font(ConsoleTypography.caption).foregroundStyle(p.warning)
                                .accessibilityLabel("Influenced by untrusted content: \(source)")
                        }
                    }
                    HStack {
                        if prompt != nil {
                            Button("Review") { Task { await mesh.review(request) } }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("mesh.consent.review")
                        }
                        Button("Deny", role: .destructive) { Task { await mesh.deny(request) } }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("mesh.consent.deny")
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(p.surface2, in: RoundedRectangle(cornerRadius: AstralRadius.md))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("mesh.consent.\(request.requestId)")
            }
        }
        .padding(.horizontal, mesh.pendingConsents.isEmpty ? 0 : 12)
        .padding(.top, mesh.pendingConsents.isEmpty ? 0 : 8)
    }
}
