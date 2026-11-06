// Presents the console transcript with inline tool steps and one persistent result renderer across preview and full
// screen. Existing component and workspace action contexts continue to authorize all result interactions.

import AstralCore
import SwiftUI

#if os(macOS)
    import AppKit

    enum MacTranscriptEntry: Identifiable {
        case turn(AppModel.ChatTurn)
        case tools(Int, [AppModel.ActivityRow])

        var id: String {
            switch self {
            case .turn(let turn): return turn.id
            case .tools(let position, _): return "tool-steps-\(position)"
            }
        }

        static func build(turns: [AppModel.ChatTurn], activity: [AppModel.ActivityRow]) -> [MacTranscriptEntry] {
            let groups = Dictionary(grouping: activity) { min(max($0.position, 0), turns.count) }
            var entries = groups[0].map { [MacTranscriptEntry.tools(0, $0)] } ?? []
            for (index, turn) in turns.enumerated() {
                if !turn.text.isEmpty || !turn.components.isEmpty { entries.append(.turn(turn)) }
                if let rows = groups[index + 1] { entries.append(.tools(index + 1, rows)) }
            }
            return entries
        }
    }

    struct MacWorkbenchTranscript: View {
        @Environment(AppModel.self) private var model
        @Environment(ThemeStore.self) private var theme
        let maximumWidth: Double
        let contentPadding: EdgeInsets
        @State private var followsLatest = true
        @State private var hoveredTurnId: String?
        private var p: AstralPalette { theme.palette }
        private var turns: [AppModel.ChatTurn] {
            model.visibleTurns.filter { !$0.text.isEmpty || !$0.components.isEmpty }
        }
        private var entries: [MacTranscriptEntry] {
            MacTranscriptEntry.build(turns: model.visibleTurns, activity: model.activity)
        }

        var body: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        ForEach(entries) { entry in
                            switch entry {
                            case .turn(let turn):
                                turnView(turn)
                            case .tools(_, let rows):
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(rows) { row in
                                        MacActivityRowView(row: row, compact: true)
                                            .accessibilityIdentifier("conversation-tool-\(row.id)")
                                    }
                                }
                                .padding(.horizontal, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        if let status = model.statusText {
                            StatusLine(text: status, showsActivity: model.statusShowsActivity)
                        }
                        Color.clear.frame(height: 1).id("workbench-latest")
                    }
                    .frame(maxWidth: maximumWidth, alignment: .leading)
                    .padding(contentPadding)
                    .frame(maxWidth: .infinity)
                    .background(MacTranscriptScrollObserver { followsLatest = $0 })
                }
                .accessibilityIdentifier("conversation-message-scroll")
                .overlay(alignment: .bottom) {
                    if !followsLatest {
                        Button {
                            followsLatest = true
                            scrollToLatest(proxy)
                        } label: {
                            Label("Jump to latest", systemImage: "arrow.down")
                                .font(ConsoleTypography.caption).padding(.horizontal, 12).padding(.vertical, 8)
                                .background(p.surface, in: Capsule()).overlay(Capsule().stroke(p.border))
                        }
                        .buttonStyle(.plain).padding(.bottom, 12)
                    }
                }
                .onAppear { scrollToLatest(proxy) }
                .onChange(of: model.activeChatId) { _, _ in
                    followsLatest = true
                    scrollToLatest(proxy)
                }
                .onChange(of: turns) { _, _ in if followsLatest { scrollToLatest(proxy) } }
                .onChange(of: model.activity.count) { _, _ in if followsLatest { scrollToLatest(proxy) } }
                .onChange(of: model.statusText) { _, _ in if followsLatest { scrollToLatest(proxy) } }
            }
        }

        private func turnView(_ turn: AppModel.ChatTurn) -> some View {
            Group {
                if turn.role == "reasoning" {
                    ReasoningSnippet(text: turn.text)
                } else if model.turnEditor?.turnId == turn.id {
                    turnEditorCard(turn)
                } else {
                    turnRow(turn)
                }
            }
            .id(turn.id)
        }

        private func turnRow(_ turn: AppModel.ChatTurn) -> some View {
            let isUser = turn.role == "user"
            let isSteer = turn.role == "steer"
            let isOwner = isUser || isSteer
            let actionsVisible = hoveredTurnId == turn.id
            return VStack(alignment: isOwner ? .trailing : .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    if isOwner { Spacer(minLength: 24) }
                    if isOwner {
                        turnActions(turn, isUser: isUser, visible: actionsVisible)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        if isSteer {
                            Text("Steer").font(ConsoleTypography.caption2.weight(.semibold))
                                .foregroundStyle(p.primary)
                                .accessibilityIdentifier("transcript-steer-label")
                        }
                        if !turn.text.isEmpty {
                            if isOwner {
                                Text(turn.text).textSelection(.enabled)
                            } else {
                                MarkdownBlockView(source: turn.text).textSelection(.enabled)
                            }
                        }
                        ForEach(Array(turn.components.enumerated()), id: \.offset) { _, component in
                            ComponentView(component: component)
                                .environment(\.astralNavigationTranscript, turn.id)
                        }
                    }
                    .font(ConsoleTypography.body).foregroundStyle(p.text)
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .background(
                        isOwner ? p.primary.opacity(0.17) : p.surface.opacity(0.55),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .astralChartBackdrop(
                        p, color: isOwner ? p.primary : p.surface, opacity: isOwner ? 0.17 : 0.55
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12).stroke(
                            isOwner ? p.primary.opacity(0.35) : p.border)
                    )
                    .contextMenu { turnContextMenu(turn) }
                    if !isOwner {
                        turnActions(turn, isUser: false, visible: actionsVisible)
                    }
                    if !isOwner { Spacer(minLength: 24) }
                }
                if let branch = turn.branch, branch.count > 1 {
                    branchSwitcher(turn, branch: branch)
                }
                if let change = turn.memoryChange {
                    MacLearnedChipView(
                        turnId: turn.id, change: change, display: model.memoryChipDisplay(change),
                        pending: model.chatMemorySnapshot(for: model.activeChatId)?.pending ?? 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: isOwner ? .trailing : .leading)
            .onHover { hovering in
                guard hovering || hoveredTurnId == turn.id else { return }
                hoveredTurnId = hovering ? turn.id : nil
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(isSteer ? "Steer" : isUser ? "You" : "AstralDeep")
            .accessibilityIdentifier("conversation-turn-\(turn.id)")
        }

        private func turnEditorCard(_ turn: AppModel.ChatTurn) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(
                    text: Binding(
                        get: { model.turnEditor?.draft ?? "" },
                        set: { model.turnEditor?.draft = $0 })
                )
                .font(ConsoleTypography.body).foregroundStyle(p.text)
                .frame(minHeight: 72, alignment: .topLeading)
                .scrollContentBackground(.hidden)
                .accessibilityLabel("Edit your message")
                .accessibilityIdentifier("conversation-edit-field-\(turn.id)")
                if model.conversationShowsBranches {
                    Toggle(
                        "Summarize what I'm leaving",
                        isOn: Binding(
                            get: { model.turnEditor?.summarizesDeparted ?? false },
                            set: { model.turnEditor?.summarizesDeparted = $0 })
                    )
                    .font(ConsoleTypography.caption)
                    .accessibilityIdentifier("conversation-edit-summarize-\(turn.id)")
                }
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Button("Cancel") {
                        model.cancelTurnEdit()
                    }
                    .buttonStyle(.plain).foregroundStyle(p.muted)
                    .accessibilityIdentifier("conversation-edit-cancel-\(turn.id)")
                    Button("Send") {
                        model.sendEditedTurn()
                    }
                    .buttonStyle(.plain).foregroundStyle(p.primary)
                    .disabled(
                        (model.turnEditor?.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                            || model.turnBusy
                    )
                    .accessibilityIdentifier("conversation-edit-send-\(turn.id)")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(p.primary.opacity(0.17), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.primary.opacity(0.35)))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 24)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Editing your message")
            .accessibilityIdentifier("conversation-turn-\(turn.id)")
        }

        @ViewBuilder private func turnActions(_ turn: AppModel.ChatTurn, isUser: Bool, visible: Bool) -> some View {
            HStack(spacing: 2) {
                if isUser {
                    turnActionButton(
                        symbol: "pencil", label: "Edit and resend",
                        identifier: "conversation-edit-\(turn.id)"
                    ) {
                        model.beginTurnEdit(turn)
                    }
                } else {
                    turnActionButton(
                        symbol: "arrow.clockwise", label: "Regenerate reply",
                        identifier: "conversation-regenerate-\(turn.id)"
                    ) {
                        model.regenerateTurn(turn)
                    }
                }
                turnActionButton(
                    symbol: "doc.on.doc", label: "Copy",
                    identifier: "conversation-copy-\(turn.id)"
                ) {
                    model.copyTurnText(turn)
                }
                turnActionButton(
                    symbol: "arrow.turn.up.right", label: isUser ? "Fork to new chat" : "Fork from here",
                    identifier: "conversation-fork-\(turn.id)"
                ) {
                    model.forkFromTurn(turn)
                }
            }
            .font(ConsoleTypography.caption).foregroundStyle(visible ? p.text : p.muted)
        }

        private func turnActionButton(
            symbol: String, label: String, identifier: String, action: @escaping () -> Void
        ) -> some View {
            Button {
                action()
            } label: {
                Image(systemName: symbol).frame(width: 26, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.turnBusy)
            .help(label)
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
        }

        @ViewBuilder private func turnContextMenu(_ turn: AppModel.ChatTurn) -> some View {
            if turn.role == "user" {
                Button("Edit and resend") { model.beginTurnEdit(turn) }
                    .disabled(model.turnBusy)
            } else {
                Button("Regenerate reply") { model.regenerateTurn(turn) }
                    .disabled(model.turnBusy)
            }
            Button("Copy") { model.copyTurnText(turn) }
            Button(turn.role == "user" ? "Fork to new chat" : "Fork from here") {
                model.forkFromTurn(turn)
            }
            .disabled(model.turnBusy)
        }

        private func branchSwitcher(_ turn: AppModel.ChatTurn, branch: ConversationMessageBranch) -> some View {
            HStack(spacing: 4) {
                Button {
                    if let target = branch.neighbor(of: turn.id, step: -1) {
                        model.selectBranch(of: turn, targetTurnId: target)
                    }
                } label: {
                    Image(systemName: "chevron.left").frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(branch.index <= 1 || model.turnBusy)
                .accessibilityLabel("Previous branch")
                .accessibilityIdentifier("conversation-branch-previous-\(turn.id)")
                Text("\(branch.index) of \(branch.count)")
                    .font(ConsoleTypography.caption).foregroundStyle(p.muted)
                    .accessibilityIdentifier("conversation-branch-position-\(turn.id)")
                Button {
                    if let target = branch.neighbor(of: turn.id, step: 1) {
                        model.selectBranch(of: turn, targetTurnId: target)
                    }
                } label: {
                    Image(systemName: "chevron.right").frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(branch.index >= branch.count || model.turnBusy)
                .accessibilityLabel("Next branch")
                .accessibilityIdentifier("conversation-branch-next-\(turn.id)")
            }
            .help("Switch between saved versions of this turn")
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Branch \(branch.index) of \(branch.count)")
            .accessibilityIdentifier("conversation-branch-\(turn.id)")
        }

        private func scrollToLatest(_ proxy: ScrollViewProxy) {
            Task { @MainActor in
                await Task.yield()
                proxy.scrollTo("workbench-latest", anchor: .bottom)
            }
        }
    }

    struct MacLearnedChipView: View {
        @Environment(AppModel.self) private var model
        @Environment(ThemeStore.self) private var theme
        let turnId: String
        let change: MemoryChange
        let display: AppModel.MemoryChipDisplay
        let pending: Int
        @State private var expanded = false
        private var p: AstralPalette { theme.palette }

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                        Text("Learned")
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    }
                    .font(ConsoleTypography.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(chipTint.opacity(0.16), in: Capsule())
                    .overlay(Capsule().stroke(chipTint.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(chipTint)
                .help("This turn changed your memory")
                .accessibilityLabel(accessibilitySummary)
                .accessibilityHint(expanded ? "Collapse memory change" : "Expand memory change")
                .accessibilityIdentifier("conversation-memory-chip-\(turnId)")
                if expanded {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: change.summary)
                            .font(ConsoleTypography.caption)
                            .accessibilityIdentifier("conversation-memory-summary-\(turnId)")
                        HStack(spacing: 10) {
                            switch display {
                            case .pending:
                                Text("Working…").font(ConsoleTypography.caption).foregroundStyle(p.muted)
                                    .accessibilityIdentifier("conversation-memory-pending-\(turnId)")
                            case .conflict:
                                Text("The server has newer memory changes.")
                                    .font(ConsoleTypography.caption).foregroundStyle(p.warning)
                                    .accessibilityIdentifier("conversation-memory-conflict-\(turnId)")
                                Button("Refresh") { model.refreshChatMemory() }
                                    .buttonStyle(.plain).foregroundStyle(p.accent)
                                    .accessibilityLabel("Refresh memory changes")
                                    .accessibilityIdentifier("conversation-memory-refresh-\(turnId)")
                            case .idle:
                                if change.state == .staged {
                                    Button("Approve") { model.decideMemoryChange(change, approve: true) }
                                        .buttonStyle(.plain).foregroundStyle(p.success)
                                        .accessibilityLabel("Approve this memory change")
                                        .accessibilityIdentifier("conversation-memory-approve-\(turnId)")
                                    Button("Reject", role: .destructive) {
                                        model.decideMemoryChange(change, approve: false)
                                    }
                                    .buttonStyle(.plain).foregroundStyle(p.error)
                                    .accessibilityLabel("Reject this memory change")
                                    .accessibilityIdentifier("conversation-memory-reject-\(turnId)")
                                } else {
                                    Button("Undo", role: .destructive) { model.undoMemoryChange(change) }
                                        .buttonStyle(.plain).foregroundStyle(p.error)
                                        .accessibilityLabel("Undo this memory change")
                                        .accessibilityIdentifier("conversation-memory-undo-\(turnId)")
                                }
                            }
                            if pending > 0 {
                                Button("\(pending) awaiting review") { model.openPersonalization() }
                                    .buttonStyle(.plain).foregroundStyle(p.accent)
                                    .accessibilityLabel("Review pending memory, \(pending) awaiting decision")
                                    .accessibilityIdentifier("conversation-memory-personalization-\(turnId)")
                            }
                        }
                    }
                    .padding(10)
                    .background(p.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("conversation-memory-detail-\(turnId)")
                }
            }
        }

        private var chipTint: Color {
            switch display {
            case .conflict: return p.warning
            case .pending: return p.muted
            case .idle: return change.state == .staged ? p.warning : p.success
            }
        }

        private var accessibilitySummary: String {
            switch display {
            case .conflict: return "Learned, change is out of date"
            case .pending: return "Learned, working"
            case .idle: return change.state == .staged ? "Learned, awaiting your decision" : "Learned"
            }
        }
    }

    struct MacTurnDepartureSheet: View {
        @Environment(AppModel.self) private var model
        @Environment(ThemeStore.self) private var theme
        let departure: AppModel.TurnDeparture
        @State private var summarizesDeparted = false
        private var p: AstralPalette { theme.palette }

        private var title: String {
            switch departure.kind {
            case .fork: return "Fork from this turn?"
            case .regenerate: return "Regenerate this reply?"
            case .branchSelect: return "Switch branch?"
            }
        }

        private var confirmationLabel: String {
            switch departure.kind {
            case .fork: return "Fork"
            case .regenerate: return "Regenerate"
            case .branchSelect: return "Switch"
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.headline)
                Text(
                    "This leaves the branch you are on. You can return to it with the turn's branch controls."
                )
                .font(ConsoleTypography.caption).foregroundStyle(p.muted)
                .accessibilityIdentifier("conversation-departure-explanation")
                Toggle("Summarize what I'm leaving", isOn: $summarizesDeparted)
                    .accessibilityIdentifier("conversation-departure-summarize")
                HStack {
                    Spacer(minLength: 0)
                    Button("Stay") {
                        model.cancelTurnDeparture()
                    }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("conversation-departure-cancel")
                    Button(confirmationLabel) {
                        model.confirmTurnDeparture(summarizeDeparted: summarizesDeparted)
                    }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("conversation-departure-confirm")
                }
            }
            .padding(24).frame(width: 400)
            .accessibilityIdentifier("conversation-departure-sheet")
        }
    }

    struct MacActivityRowView: View {
        @Environment(ThemeStore.self) private var theme
        let row: AppModel.ActivityRow
        let compact: Bool
        private var p: AstralPalette { theme.palette }
        private var symbol: String {
            if row.approval == .waiting { return "hand.raised" }
            switch row.state {
            case .running: return "circle.dotted"
            case .completed: return "checkmark.circle"
            case .failed: return "exclamationmark.triangle"
            case .cancelled: return "xmark.circle"
            }
        }
        private var tint: Color {
            if row.approval == .waiting { return p.warning }
            switch row.state {
            case .running: return p.primary
            case .completed: return p.success
            case .failed: return p.error
            case .cancelled: return p.muted
            }
        }
        private var detail: String { row.result.isEmpty ? row.stateLabel : row.result }

        var body: some View {
            HStack(alignment: compact ? .center : .top, spacing: 10) {
                Image(systemName: symbol).foregroundStyle(tint).frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(row.action).font(ConsoleTypography.caption.weight(.semibold)).lineLimit(1)
                        if !row.target.isEmpty {
                            Text(row.target).font(ConsoleTypography.caption).foregroundStyle(p.muted)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        if compact { trailing }
                    }
                    if !compact { trailing }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let thumbnail = row.thumbnail, let image = NSImage(data: thumbnail) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: compact ? 56 : 96, maxHeight: compact ? 32 : 64)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(p.border))
                }
            }
            .padding(.horizontal, compact ? 10 : 0).padding(.vertical, compact ? 6 : 0)
            .background(compact ? p.surface.opacity(0.35) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel(row.accessibilityLabel)
            .accessibilityValue(row.accessibilityValue)
        }

        @ViewBuilder private var trailing: some View {
            HStack(spacing: 6) {
                if let approval = row.approvalLabel {
                    Text(approval).font(ConsoleTypography.caption2.weight(.semibold))
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(tint.opacity(0.16), in: Capsule())
                }
                if row.approval == .none || !row.result.isEmpty {
                    Text(detail).font(ConsoleTypography.caption).foregroundStyle(p.muted)
                        .lineLimit(compact ? 1 : 3)
                }
            }
        }
    }

    private struct MacTranscriptScrollObserver: NSViewRepresentable {
        let followsLatest: (Bool) -> Void

        func makeNSView(context: Context) -> ScrollObserverView {
            let view = ScrollObserverView()
            view.followsLatest = followsLatest
            return view
        }

        func updateNSView(_ view: ScrollObserverView, context: Context) { view.followsLatest = followsLatest }

        final class ScrollObserverView: NSView {
            var followsLatest: ((Bool) -> Void)?
            private var observers: [NSObjectProtocol] = []

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                observers.forEach(NotificationCenter.default.removeObserver)
                observers.removeAll()
                DispatchQueue.main.async { [weak self] in
                    guard let self, let scroll = self.enclosingScrollView, self.window != nil else { return }
                    for name in [NSScrollView.didLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
                        observers.append(
                            NotificationCenter.default.addObserver(forName: name, object: scroll, queue: .main) {
                                [weak self, weak scroll] _ in
                                guard let scroll, let document = scroll.documentView else { return }
                                let remaining = document.bounds.maxY - scroll.contentView.bounds.maxY
                                self?.followsLatest?(remaining <= 24)
                            })
                    }
                }
            }

            deinit { observers.forEach(NotificationCenter.default.removeObserver) }
        }
    }
#endif

struct ConsoleCanvasBounds {
    var result: Anchor<CGRect>?
    var viewport: Anchor<CGRect>?
}

struct ConsoleCanvasBoundsKey: PreferenceKey {
    static var defaultValue = ConsoleCanvasBounds()
    static func reduce(value: inout ConsoleCanvasBounds, nextValue: () -> ConsoleCanvasBounds) {
        let next = nextValue()
        value.result = next.result ?? value.result
        value.viewport = next.viewport ?? value.viewport
    }
}

struct ConsoleConversation: View {
    @Environment(AppModel.self) var model
    @Environment(ThemeStore.self) var theme
    let presentation: ConsolePresentation
    private var p: AstralPalette { theme.palette }
    private var turns: [AppModel.ChatTurn] { model.visibleTurns.filter { !$0.text.isEmpty || !$0.components.isEmpty } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(turns) { turn in
                        if turn.role == "reasoning" {
                            ReasoningSnippet(text: turn.text)
                        } else {
                            let isOwner = turn.role == "user" || turn.role == "steer"
                            HStack {
                                if isOwner { Spacer(minLength: 24) }
                                VStack(alignment: .leading, spacing: 10) {
                                    if turn.role == "steer" {
                                        Text("Steer").font(ConsoleTypography.caption2.weight(.semibold))
                                            .foregroundStyle(p.primary)
                                            .accessibilityIdentifier("transcript-steer-label")
                                    }
                                    if turn.role == "user" || turn.role == "steer" {
                                        Text(turn.text)
                                    } else if !turn.text.isEmpty {
                                        MarkdownBlockView(source: turn.text)
                                    }
                                    ForEach(Array(turn.components.enumerated()), id: \.offset) { _, component in
                                        ComponentView(component: component)
                                            .environment(\.astralNavigationTranscript, turn.id)
                                    }
                                }
                                .font(ConsoleTypography.subheadline).foregroundStyle(p.text)
                                .padding(.horizontal, 16).padding(.vertical, 14)
                                .background(
                                    isOwner ? p.primary.opacity(0.17) : p.surface.opacity(0.55),
                                    in: RoundedRectangle(cornerRadius: 12)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12).stroke(
                                        isOwner ? p.primary.opacity(0.35) : p.border))
                                if !isOwner { Spacer(minLength: 0) }
                            }
                        }
                    }
                    if let status = model.statusText {
                        StatusLine(text: status, showsActivity: model.statusShowsActivity)
                    }
                    if !model.workspaceCanvas.isEmpty || model.showSkeleton {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 10) {
                                Text("✦").foregroundStyle(p.accent).frame(width: 32, height: 32)
                                    .background(p.primary.opacity(0.2), in: RoundedRectangle(cornerRadius: 7))
                                if !model.consoleResultAgent.isEmpty {
                                    Text(model.consoleResultAgent).font(ConsoleTypography.subheadline.weight(.semibold))
                                }
                            }
                            Color.clear
                                .frame(height: model.consoleResultCollapsed ? 54 : presentation.resultPreviewMaxHeight)
                                .anchorPreference(key: ConsoleCanvasBoundsKey.self, value: .bounds) {
                                    ConsoleCanvasBounds(result: $0)
                                }
                        }
                        .id("console-result")
                    }
                    Color.clear.frame(height: 1).id("console-bottom")
                }
                .padding(presentation.contentPadding.edgeInsets)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("conversation-message-scroll")
            .scrollDismissesKeyboard(.immediately)
            .transformAnchorPreference(key: ConsoleCanvasBoundsKey.self, value: .bounds) { value, anchor in
                value.viewport = anchor
            }
            .onAppear { scrollToLatest(proxy) }
            .onChange(of: model.activeChatId) { _, _ in scrollToLatest(proxy) }
            .onChange(of: turns) { _, _ in scrollToLatest(proxy) }
            .onChange(of: model.workspaceCanvas) { _, _ in scrollToLatest(proxy) }
            .onChange(of: model.showSkeleton) { _, _ in scrollToLatest(proxy) }
            .onChange(of: model.statusText) { _, _ in scrollToLatest(proxy) }
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo("console-bottom", anchor: .bottom)
        }
    }
}

struct ConsoleResultPane: View {
    @Environment(AppModel.self) var model
    @Environment(ThemeStore.self) var theme
    let presentation: ConsolePresentation
    @State private var showTimeline = false
    @State private var actionTarget: ComponentActionTarget?
    private var p: AstralPalette { theme.palette }
    private var fullscreen: Bool { model.consoleFullscreen }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text(model.consoleResultTitle).font(ConsoleTypography.subheadline.weight(.semibold))
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    if !fullscreen {
                        Button {
                            model.consoleResultCollapsed.toggle()
                        } label: {
                            Image(systemName: model.consoleResultCollapsed ? "chevron.down" : "chevron.up")
                                .frame(width: 40, height: 44).contentShape(Rectangle())
                        }
                        .accessibilityLabel(model.consoleLabel(model.consoleResultCollapsed ? "expand" : "collapse"))
                    }
                    if !fullscreen {
                        Button {
                            model.consoleFullscreen = true
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 40, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Open this result in full screen")
                    }
                    WorkspaceActionButtons()
                    if fullscreen {
                        Button {
                            model.consoleFullscreen = false
                        } label: {
                            Image(systemName: "xmark").frame(width: 40, height: 44)
                                .foregroundStyle(p.error).background(
                                    p.error.opacity(0.1), in: RoundedRectangle(cornerRadius: 7)
                                )
                                .contentShape(Rectangle())
                        }
                        .keyboardShortcut(.escape, modifiers: [])
                        .accessibilityLabel(model.consoleLabel("exit_fullscreen"))
                    }
                }
                .buttonStyle(.plain).foregroundStyle(p.muted)
                .padding(.horizontal, 8).frame(height: fullscreen ? 64 : 54)
                .background(p.text.opacity(0.025)).overlay(alignment: .bottom) { p.border.frame(height: 1) }
                ZStack(alignment: .bottom) {
                    CanvasArea(
                        showTimeline: $showTimeline, componentActionTarget: $actionTarget, showsTimelineControl: false
                    )
                    .allowsHitTesting(fullscreen).accessibilityHidden(!fullscreen)
                    if !fullscreen {
                        LinearGradient(colors: [.clear, p.surface], startPoint: .top, endPoint: .bottom)
                            .frame(height: 90).allowsHitTesting(false)
                        Button {
                            model.consoleFullscreen = true
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(ConsoleTypography.caption).frame(width: 40, height: 40)
                                .background(p.surface, in: RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.muted.opacity(0.4)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).padding(.bottom, 14)
                        .help(model.consoleLabel("result_preview_action"))
                        .accessibilityLabel(model.consoleLabel("result_preview_action"))
                    }
                }
                .frame(height: fullscreen ? max(0, geometry.size.height - 64) : presentation.resultBodyMaxHeight)
                .opacity(!fullscreen && model.consoleResultCollapsed ? 0 : 1)
                .accessibilityHidden(!fullscreen && model.consoleResultCollapsed)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .background(p.surface).clipShape(RoundedRectangle(cornerRadius: fullscreen ? 0 : 10))
            .overlay(RoundedRectangle(cornerRadius: fullscreen ? 0 : 10).stroke(p.border))
        }
        .sheet(isPresented: $showTimeline) {
            CanvasTimelineOverlay(history: model.canvasHistory) { index in
                model.viewCanvasSnapshot(index)
                showTimeline = false
            }
        }
        .sheet(item: $actionTarget) { target in ComponentActionSheet(target: target) }
        .onChange(of: actionTarget.map { model.componentActionIsCurrent($0.context) } ?? false) { _, current in
            if !current { actionTarget = nil }
        }
        .onDisappear { actionTarget = nil }
    }
}

struct WorkspaceActionButtons: View {
    @Environment(AppModel.self) var model
    @State private var exportContext: AppModel.WorkspaceActionContext?
    @State private var shareContext: AppModel.WorkspaceActionContext?
    @State private var shareTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(model.chromeMenu?.topbarActions ?? []) { control in
                if let action = control.workspaceAction, model.workspaceActionContext(for: action) != nil {
                    Button {
                        start(action)
                    } label: {
                        Image(systemName: action == .exportCanvas ? "square.and.arrow.down" : "square.and.arrow.up")
                            .frame(width: 40, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        model.workspaceActionInFlight(action) || (action == .exportCanvas && exportContext != nil)
                    )
                    .accessibilityLabel(control.label ?? control.key)
                    .accessibilityIdentifier("workspace-action-\(control.key)")
                }
            }
        }
        .sheet(item: $exportContext) { context in
            if let url = model.workspaceExportURL(context) {
                ExportDownloadSheet(url: url, filename: "astraldeep-canvas.html", workspaceExport: context)
            }
        }
        .onChange(of: exportContext.map(model.workspaceActionIsCurrent) ?? false) { _, current in
            if !current { exportContext = nil }
        }
        .onChange(of: shareContext.map(model.workspaceActionIsCurrent) ?? false) { _, current in
            if !current { shareTask?.cancel() }
        }
        .onDisappear {
            exportContext = nil
            shareTask?.cancel()
        }
    }

    private func start(_ action: WorkspaceAction) {
        guard let context = model.workspaceActionContext(for: action), !model.workspaceActionInFlight(action) else {
            return
        }
        if action == .exportCanvas {
            if exportContext == nil { exportContext = context }
            return
        }
        guard shareContext == nil else { return }
        shareContext = context
        shareTask = Task { @MainActor in
            defer {
                shareContext = nil
                shareTask = nil
            }
            do {
                let url = try await model.shareWorkspaceCanvas(context)
                guard !Task.isCancelled, model.workspaceActionIsCurrent(context) else { return }
                #if os(macOS)
                    NSPasteboard.general.clearContents()
                    let copied = NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    let message = copied ? "Share link copied to clipboard." : "Share link: \(url.absoluteString)"
                #else
                    UIPasteboard.general.string = url.absoluteString
                    let message = "Share link copied to clipboard."
                #endif
                model.bannerIsError = false
                model.errorBanner = message
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, model.workspaceActionIsCurrent(context) else { return }
                model.bannerIsError = true
                model.errorBanner =
                    error as? WorkspaceShareError == .phiBlocked
                    ? "Sharing refused: the content matched the PHI gate." : "Couldn't create the share link."
            }
        }
    }
}

extension AppModel {
    var consoleResultAgent: String {
        let identifiers = workspaceCanvas.compactMap { component in
            component.raw["source_agent"]?.stringValue ?? component.raw["_source_agent"]?.stringValue
                ?? component.raw["agent_id"]?.stringValue ?? component.raw["agent"]?.stringValue
        }
        for identifier in identifiers {
            if let agent = console?.catalog.agents.first(where: { $0.id == identifier }) { return agent.name }
        }
        return ""
    }

    var consoleResultTitle: String {
        workspaceCanvas.lazy.compactMap { $0.title?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? consoleResultAgent
    }

    var consoleResultAccessibilityLabel: String {
        let title = consoleResultTitle
        let agent = consoleResultAgent
        if title.isEmpty { return "Canvas" }
        return agent.isEmpty || agent == title ? title : "\(title), \(agent)"
    }
}
