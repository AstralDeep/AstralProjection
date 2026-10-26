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
                } else {
                    let isUser = turn.role == "user"
                    HStack {
                        if isUser { Spacer(minLength: 24) }
                        VStack(alignment: .leading, spacing: 10) {
                            if !turn.text.isEmpty {
                                if isUser {
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
                            isUser ? p.primary.opacity(0.17) : p.surface.opacity(0.55),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .astralChartBackdrop(
                            p, color: isUser ? p.primary : p.surface, opacity: isUser ? 0.17 : 0.55
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12).stroke(
                                isUser ? p.primary.opacity(0.35) : p.border))
                        if !isUser { Spacer(minLength: 24) }
                    }
                    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(isUser ? "You" : "AstralDeep")
                    .accessibilityIdentifier("conversation-turn-\(turn.id)")
                    .id(turn.id)
                }
            }
        }

        private func scrollToLatest(_ proxy: ScrollViewProxy) {
            Task { @MainActor in
                await Task.yield()
                proxy.scrollTo("workbench-latest", anchor: .bottom)
            }
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
            .accessibilityLabel(row.accessibilityLabel)
            .accessibilityValue(row.accessibilityValue)
        }

        @ViewBuilder private var trailing: some View {
            HStack(spacing: 6) {
                if let approval = row.approvalLabel {
                    Text(approval).font(ConsoleTypography.caption2.weight(.semibold))
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
                            HStack {
                                if turn.role == "user" { Spacer(minLength: 24) }
                                VStack(alignment: .leading, spacing: 10) {
                                    if turn.role == "user" {
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
                                    turn.role == "user" ? p.primary.opacity(0.17) : p.surface.opacity(0.55),
                                    in: RoundedRectangle(cornerRadius: 12)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12).stroke(
                                        turn.role == "user" ? p.primary.opacity(0.35) : p.border))
                                if turn.role != "user" { Spacer(minLength: 0) }
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
