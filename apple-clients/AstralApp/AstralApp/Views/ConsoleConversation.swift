// Presents the console transcript and one persistent result renderer across preview and full screen.
// Existing component and workspace action contexts continue to authorize all result interactions.

import AstralCore
import SwiftUI

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
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(model.consoleResultAgent).font(ConsoleTypography.subheadline.weight(.semibold))
                                    Text(model.consoleLabel("result_agent_role")).font(ConsoleTypography.sans(11))
                                        .foregroundStyle(p.muted)
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
                                .frame(width: 40, height: 44)
                        }
                        .accessibilityLabel(model.consoleLabel(model.consoleResultCollapsed ? "expand" : "collapse"))
                    }
                    if !fullscreen {
                        Button {
                            model.consoleFullscreen = true
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 40, height: 44)
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
                                    p.error.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
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
                            Label(
                                model.consoleLabel("result_preview_action"),
                                systemImage: "arrow.up.left.and.arrow.down.right"
                            )
                            .font(ConsoleTypography.caption).padding(10)
                            .background(p.surface, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.muted.opacity(0.4)))
                        }
                        .buttonStyle(.plain).padding(.bottom, 14)
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
                            .frame(width: 40, height: 44)
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
        return consoleLabel("result_default_agent")
    }

    var consoleResultTitle: String {
        consoleLabel("result_title").replacingOccurrences(of: "{agent}", with: consoleResultAgent)
    }
}
