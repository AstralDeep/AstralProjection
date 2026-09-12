import AstralCore
// Feature 051 — the adaptive chat shell, a 1:1 match to the Android AdaptiveShell:
// a canvas-dominant area (skeleton while a replacing turn is in flight, empty-
// state hint, live working bar, read-only timeline banner + snapshot overlay), a
// collapsible "Messages" panel with reasoning snippets, the execution step trail,
// and an input bar (mic · attachment chips · rounded field · paperclip · send).
// Compact widths stack; regular widths (iPad/landscape/macOS) split into a rail.
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
    import PhotosUI
#endif

// 066 layout contract (specs/066-canvas-first-uiux/apple-handoff.md): the
// canvas is the primary surface on every device class. Three width-driven
// modes mirror the web reference — `stacked` < 700pt, `collapsed` 700–1023pt
// (canvas full width, floating composer, conversation as a drawer with an
// unread badge), `split` ≥ 1024pt (canvas LEADING, rail trailing). The stored
// per-device preference can force `collapsed` at any width ≥ 700, but the
// width bound always beats the preference so the rail can never crush the
// composer below ~20 visible characters (FR-004). pt ≈ CSS px keeps the
// breakpoints in parity with the web client's 700/1024.

struct ChatShell: View {
    @Environment(AppModel.self) var model
    // FR-002: the collapse/expand choice persists per device across launches
    // ("" = automatic, "open" pins the split rail, "closed" collapses it).
    @AppStorage("astralChatPref") private var chatPref = ""
    // The composer draft and the canvas sheets live HERE, above the mode
    // switch: a resize across a breakpoint swaps the shell (new structural
    // identity), and view-local state would silently discard typed-but-unsent
    // text or dismiss an open timeline/refine sheet mid-edit.
    private var draft: Binding<String> {
        Binding(get: { model.composerDraft }, set: { model.composerDraft = $0 })
    }
    @State private var showTimeline = false
    @State private var componentActionTarget: ComponentActionTarget?
    var body: some View {
        // The outer GeometryReader is itself a layout firewall (063 class): it
        // answers the parent's proposal in O(1) and hands every shell a
        // CONCRETE size, so no flexible sibling ever asks a transcript/canvas
        // ScrollView for its ideal height.
        GeometryReader { geo in
            shell(size: geo.size)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .sheet(isPresented: $showTimeline) {
            CanvasTimelineOverlay(history: model.canvasHistory) { idx in
                model.viewCanvasSnapshot(idx)
                showTimeline = false
            }
        }
        .sheet(item: $componentActionTarget) { target in
            ComponentActionSheet(target: target)
        }
        .onChange(of: componentActionTarget.map { model.componentActionIsCurrent($0.context) } ?? false) { _, current in
            if !current { componentActionTarget = nil }
        }
        .onDisappear { componentActionTarget = nil }
        #if os(macOS)
            // T033/FR-017: Finder drag-and-drop stages chips exactly like the
            // file dialog (Windows-client parity).
            .dropDestination(for: URL.self) { urls, _ in
                guard !model.mutationsLocked, !urls.isEmpty else { return false }
                for url in urls {
                    model.stageFile(url: url)
                }
                return true
            }
        #endif
    }

    @ViewBuilder
    private func shell(size: CGSize) -> some View {
        if !model.workspaceStarted {
            StartShell(containerSize: size, draft: draft)
        } else {
            switch WorkspaceLayout.forWidth(Double(size.width), preference: chatPref) {
            case .stacked:
                StackedShell(
                    draft: draft, showTimeline: $showTimeline,
                    componentActionTarget: $componentActionTarget)
            case .collapsed:
                CollapsedShell(
                    containerSize: size, draft: draft,
                    showTimeline: $showTimeline, componentActionTarget: $componentActionTarget,
                    onPinRail: { chatPref = "open" })
            case .split:
                SplitShell(
                    containerSize: size, draft: draft,
                    showTimeline: $showTimeline, componentActionTarget: $componentActionTarget,
                    onCollapseRail: { chatPref = "closed" })
            }
        }
    }
}

// MARK: - Layouts

/// The same server-authored welcome components surround the one composer.
/// Width only changes their arrangement; no native copy or example catalog exists.
private struct StartShell: View {
    @Environment(AppModel.self) var model
    let containerSize: CGSize
    @Binding var draft: String

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                welcome(.intro)
                welcome(.permission)
                InputBar(input: $draft)
                welcome(.examples)
                welcome(.more)
            }
            .frame(maxWidth: 704)
            .padding(.horizontal, 20).padding(.vertical, 32)
            .frame(maxWidth: .infinity, minHeight: containerSize.height)
        }
        .accessibilityIdentifier("workspace-start")
    }

    private func welcome(_ role: WorkspaceWelcome.Role) -> some View {
        ForEach(Array(WorkspaceWelcome.components(model.visibleCanvas, for: role).enumerated()), id: \.offset) {
            _, component in
            ComponentView(component: component)
        }
    }
}

private struct StackedShell: View {
    @Environment(AppModel.self) var model
    @Binding var draft: String
    @Binding var showTimeline: Bool
    @Binding var componentActionTarget: ComponentActionTarget?
    var body: some View {
        VStack(spacing: 0) {
            CanvasArea(showTimeline: $showTimeline, componentActionTarget: $componentActionTarget)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.turnActive { StepTrailView(lines: model.stepTrail) }
            MessagesPanel()
            InputBar(input: $draft)
        }
    }
}

/// 066 `collapsed` mode: the canvas takes the FULL width and the composer
/// floats as a centered bar (max 760pt) over its bottom edge; the transcript
/// opens as a drawer inside that bar, with an unread badge on the toggle
/// (FR-001/FR-003). `safeAreaInset` keeps the canvas's own scroll content
/// clear of the bar while the bar visually overlays it — and, like every
/// other transcript host, the drawer's ChatList gets a CONCRETE height so
/// flexible-space rounds stay O(1) (063 livelock class).
private struct CollapsedShell: View {
    @Environment(AppModel.self) var model
    @Environment(ThemeStore.self) var theme
    let containerSize: CGSize
    @Binding var draft: String
    @Binding var showTimeline: Bool
    @Binding var componentActionTarget: ComponentActionTarget?
    let onPinRail: () -> Void
    @State private var drawerOpen = false
    @State private var unread = 0
    private var p: AstralPalette { theme.palette }

    private var assistantCount: Int {
        model.visibleTurns.filter {
            $0.role != "user" && (!$0.text.isEmpty || !$0.components.isEmpty)
        }.count
    }
    private var drawerHeight: CGFloat {
        min(420, max(220, containerSize.height * 0.46))
    }

    var body: some View {
        CanvasArea(showTimeline: $showTimeline, componentActionTarget: $componentActionTarget)
            .safeAreaInset(edge: .bottom) {
                floatingBar
                    .frame(maxWidth: 760)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(p.border))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
            .onChange(of: assistantCount) { oldCount, newCount in
                // FR-003: new assistant activity while the conversation is
                // hidden surfaces as a badge, never an auto-reveal. Status
                // updates ride setStatus paths, not turns, so they can't trip
                // this counter. HEURISTIC: +1 deltas are treated as live
                // turns, larger jumps as hydration (chat restore/switch).
                // Known miscounts (recorded in the 066 follow-ups register):
                // a multi-doc-card ui_upsert lands >1 in one transaction
                // (under-counts), and a reasoning row + narrative in one
                // reply can badge twice (over-counts). A structural fix needs
                // reducer-level live-vs-hydration provenance, not a view-side
                // delta guess.
                if !drawerOpen, newCount == oldCount + 1 {
                    unread = min(unread + 1, 10)
                }
            }
    }

    private var floatingBar: some View {
        VStack(spacing: 0) {
            if drawerOpen {
                HStack(spacing: 6) {
                    Text("CONVERSATION")
                        .font(AstralTypography.caption2.bold()).foregroundStyle(p.muted)
                    Spacer()
                    // The pin can only take effect where split is reachable
                    // (≥1024pt — width bound beats preference); below that it
                    // would be an inert affordance, so it is not offered.
                    if containerSize.width >= 1024 {
                        Button(action: onPinRail) {
                            Image(systemName: "sidebar.trailing")
                                .font(AstralTypography.caption.weight(.semibold)).foregroundStyle(p.muted)
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Pin conversation rail")
                        .help("Pin conversation rail")
                    }
                }
                .padding(.horizontal, 14).padding(.top, 8)
                ChatList().frame(height: drawerHeight)
                Divider().overlay(p.border)
            }
            if containerSize.width >= 1024, !drawerOpen {
                HStack {
                    Spacer()
                    Button(action: onPinRail) {
                        Label("Show conversation sidebar", systemImage: "sidebar.trailing")
                            .font(AstralTypography.caption).foregroundStyle(p.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("workspace-restore-rail")
                }
                .padding(.horizontal, 14).padding(.top, 10)
            }
            if model.turnActive { StepTrailView(lines: model.stepTrail) }
            HStack(alignment: .bottom, spacing: 2) {
                ChatDrawerToggle(unread: unread, open: drawerOpen) {
                    drawerOpen.toggle()
                    if drawerOpen { unread = 0 }
                }
                .padding(.leading, 8).padding(.bottom, 12)
                InputBar(input: $draft, framed: false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

/// 066 `split` mode: canvas LEADS (left, stretching), the conversation rail
/// TRAILS (right, clamped 320–420pt) — the same structural flip Windows'
/// QSplitter and Android's SplitShell received (parity row P1).
private struct SplitShell: View {
    @Environment(AppModel.self) var model
    @Environment(ThemeStore.self) var theme
    let containerSize: CGSize
    @Binding var draft: String
    @Binding var showTimeline: Bool
    @Binding var componentActionTarget: ComponentActionTarget?
    let onCollapseRail: () -> Void

    // Web reference: clamp(320px, 28vw, 420px).
    private var railWidth: CGFloat {
        max(320, min(420, containerSize.width * 0.28))
    }

    var body: some View {
        HStack(spacing: 0) {
            CanvasArea(showTimeline: $showTimeline, componentActionTarget: $componentActionTarget)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().overlay(theme.palette.border)
            VStack(spacing: 0) {
                RailHeader(onCollapse: onCollapseRail)
                // Same layout firewall as CanvasArea: without it the rail
                // VStack's flexible rounds measure the full transcript per
                // proposal (063 livelock class — this is the macOS/iPad shape).
                GeometryReader { geo in
                    ChatList().frame(width: geo.size.width, height: geo.size.height)
                }
                if model.turnActive { StepTrailView(lines: model.stepTrail) }
                InputBar(input: $draft)
            }
            .frame(width: railWidth)
        }
    }
}

private struct RailHeader: View {
    @Environment(ThemeStore.self) var theme
    let onCollapse: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Text("CONVERSATION")
                .font(AstralTypography.caption2.bold()).foregroundStyle(theme.palette.muted)
            Spacer()
            Button(action: onCollapse) {
                Image(systemName: "chevron.right.2")
                    .font(AstralTypography.caption.weight(.semibold))
                    .foregroundStyle(theme.palette.muted)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Collapse conversation rail")
            .help("Collapse conversation rail")
        }
        .padding(.horizontal, 14).padding(.vertical, 4)
        .background(theme.palette.surface)
    }
}

private struct ChatDrawerToggle: View {
    @Environment(ThemeStore.self) var theme
    let unread: Int
    let open: Bool
    let action: () -> Void
    private var p: AstralPalette { theme.palette }
    var body: some View {
        Button(action: action) {
            Image(systemName: open ? "chevron.down" : "bubble.left.and.bubble.right")
                .font(.system(size: 16)).foregroundStyle(p.muted)
                .frame(width: 38, height: 38)
                .background(p.surface2, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if unread > 0, !open {
                Text(unread > 9 ? "9+" : "\(unread)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(p.primary, in: Capsule())
                    .offset(x: 5, y: -5)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityIdentifier("collapsed-chat-toggle")
        .accessibilityLabel(open ? "Hide conversation" : "Show conversation")
        .accessibilityValue(unread > 0 && !open ? "\(unread) unread" : "")
        .help(open ? "Hide conversation" : "Show conversation")
    }
}

// MARK: - Canvas

private struct CanvasArea: View {
    @Environment(AppModel.self) var model
    @Environment(ThemeStore.self) var theme
    @Environment(\.astralViewportWidth) private var viewportWidth
    // Owned by ChatShell (the sheets are attached there too) so a layout-mode
    // switch cannot dismiss an open timeline or refine sheet mid-edit.
    @Binding var showTimeline: Bool
    @Binding var componentActionTarget: ComponentActionTarget?
    private var p: AstralPalette { theme.palette }

    private func retainCanvasGeometry(_ size: CGSize, palette: AstralPalette) {
        model.canvasCapture.setCanvas(
            CGSize(width: size.width - 2 * AstralWebStyle.canvasInset(viewportWidth), height: size.height),
            palette: palette)
    }

    private var canvasItems: [(key: String, index: Int, comp: AstralComponent)] {
        model.workspaceCanvas.enumerated().map { index, comp in
            (comp.componentId ?? "anon-\(index)", index, comp)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.isViewingHistory {
                ReadOnlyBanner(label: model.viewingIndex.flatMap { model.canvasHistory[safe: $0]?.label }) {
                    model.backToLiveCanvas()
                }
            } else if model.turnActive && model.statusShowsActivity && !model.showSkeleton {
                if ContinuousActivityPresentation.allowsAnimatedIndicators {
                    ProgressView().progressViewStyle(.linear).tint(p.secondary)
                } else {
                    Rectangle()
                        .fill(p.secondary.opacity(0.65))
                        .frame(height: 2)
                        .accessibilityHidden(true)
                }
            }
            ZStack(alignment: .topTrailing) {
                // GeometryReader is a layout firewall: it answers every parent
                // proposal in O(1) and lays the scroll content out ONCE at the
                // final concrete size. Without it, the shell VStack's flexible-
                // space rounds ask this subtree for its ideal height, and a
                // vertical ScrollView answers that by realizing + measuring its
                // ENTIRE LazyVStack — one component of the combinatorial layout
                // pass behind the 063 stuck-canvas livelock (same class as the
                // shimmer trigger fixed earlier; see StepTrailView/MessagesPanel).
                GeometryReader { geo in
                    Group {
                        if model.showSkeleton && model.workspaceCanvas.isEmpty {
                            SkeletonCanvas()
                        } else if model.workspaceCanvas.isEmpty {
                            EmptyCanvasHint()
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 12) {
                                    // Keyed by component identity so a `remove` op
                                    // doesn't shift every later component onto a new
                                    // SwiftUI identity (resetting tabs/collapsibles
                                    // and scroll anchors — FR-013).
                                    ForEach(canvasItems, id: \.key) { item in
                                        // 055 US4/US5 chrome: provenance badge +
                                        // refine/export context menu (top-level only).
                                        ComponentChrome(
                                            component: item.comp,
                                            onAction: { componentActionTarget = $0 }
                                        )
                                        .environment(\.canvasCapturePath, "/components/\(item.index)")
                                    }
                                    if model.showSkeleton { SkeletonCanvas() }
                                }
                                .padding(AstralWebStyle.canvasInset(viewportWidth))
                            }
                            .accessibilityIdentifier("workspace-canvas-scroll")
                            .scrollDismissesKeyboard(.immediately)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .onAppear { retainCanvasGeometry(geo.size, palette: p) }
                    .onChange(of: geo.size) { _, size in retainCanvasGeometry(size, palette: p) }
                    .onChange(of: viewportWidth) { _, _ in retainCanvasGeometry(geo.size, palette: p) }
                    .onChange(of: p) { _, palette in retainCanvasGeometry(geo.size, palette: palette) }
                }

                if !model.isViewingHistory {
                    HStack(spacing: 8) {
                        if !model.canvasHistory.isEmpty {
                            TimelinePill(count: model.canvasHistory.count) { showTimeline = true }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(p.bg)
    }
}

private struct SkeletonCanvas: View {
    @Environment(ThemeStore.self) var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: AstralRadius.md)
                    .fill(theme.palette.surface.opacity(0.5))
                    .frame(height: i == 0 ? 90 : 60)
                    .frame(maxWidth: .infinity)
                    .activityShimmer()
            }
            Spacer()
        }
        .padding(16)
    }
}

private struct EmptyCanvasHint: View {
    @Environment(ThemeStore.self) var theme
    private var p: AstralPalette { theme.palette }
    var body: some View {
        VStack(spacing: 8) {
            Text("Your generated interface appears here")
                .font(AstralTypography.headline).foregroundStyle(p.text).multilineTextAlignment(.center)
            Text("Ask something below and AstralDeep will build a live interface for it.")
                .font(AstralTypography.subheadline).foregroundStyle(p.muted).multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ReadOnlyBanner: View {
    @Environment(ThemeStore.self) var theme
    let label: String?
    let onBackToLive: () -> Void
    private var p: AstralPalette { theme.palette }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(p.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Viewing a previous canvas").font(AstralTypography.footnote.weight(.semibold)).foregroundStyle(
                    p.text)
                if let label, !label.isEmpty {
                    Text(label).font(AstralTypography.caption).foregroundStyle(p.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button("Back to live", action: onBackToLive)
                .font(AstralTypography.caption.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(p.primary, in: Capsule())
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(p.primary.opacity(0.16))
    }
}

private struct TimelinePill: View {
    @Environment(ThemeStore.self) var theme
    let count: Int
    let onClick: () -> Void
    private var p: AstralPalette { theme.palette }
    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath").font(AstralTypography.caption2)
                Text("History (\(count))").font(AstralTypography.caption.weight(.medium))
            }
            .foregroundStyle(p.text)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(p.surface.opacity(0.92), in: Capsule())
            .overlay(Capsule().stroke(p.border))
        }
        .buttonStyle(.plain)
    }
}

private struct CanvasTimelineOverlay: View {
    @Environment(ThemeStore.self) var theme
    let history: [AppModel.CanvasSnapshot]
    let onSelect: (Int) -> Void
    private var p: AstralPalette { theme.palette }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Previous canvases").font(AstralTypography.headline).foregroundStyle(p.text)
            Text("Read-only snapshots from earlier turns in this chat.")
                .font(AstralTypography.caption).foregroundStyle(p.muted)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(history.enumerated()).reversed(), id: \.offset) { idx, snap in
                        Button {
                            onSelect(idx)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(snap.label.isEmpty ? "Canvas \(idx + 1)" : snap.label)
                                        .foregroundStyle(p.text).lineLimit(1)
                                    Text("\(snap.components.count) component\(snap.components.count == 1 ? "" : "s")")
                                        .font(AstralTypography.caption).foregroundStyle(p.muted)
                                }
                                Spacer()
                                Text("›").foregroundStyle(p.muted)
                            }
                            .padding(14)
                            .background(p.surface2, in: RoundedRectangle(cornerRadius: AstralRadius.md))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .background(p.bg.ignoresSafeArea())
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Messages / rail

private struct StepTrailView: View {
    @Environment(ThemeStore.self) var theme
    let lines: [String]
    var body: some View {
        if lines.isEmpty {
            EmptyView()
        } else {
            // One Text, not a ForEach of rows: the trail updates on every
            // chat_step during a live turn, and per-row flexible layout fed the
            // shell's flexible-space rounds (063 livelock). A single bounded
            // Text is one cheap measure — and it can't hit the duplicate-
            // identity hazard `ForEach(id: \.self)` had when a step repeats
            // (two `✗ run_job` lines in one turn).
            Text(lines.suffix(4).joined(separator: "\n"))
                .font(AstralTypography.caption2).foregroundStyle(theme.palette.muted)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 4)
        }
    }
}

private struct MessagesPanel: View {
    @Environment(AppModel.self) var model
    @Environment(ThemeStore.self) var theme
    @State private var expanded = true
    private var p: AstralPalette { theme.palette }
    private var visible: [AppModel.ChatTurn] {
        model.visibleTurns.filter { !$0.text.isEmpty || !$0.components.isEmpty }
    }

    var body: some View {
        if visible.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                if expanded {
                    Divider().overlay(p.border)
                    // A CONCRETE height, not maxHeight: shrink-to-fit required
                    // measuring the whole transcript (a vertical ScrollView's
                    // ideal height realizes every LazyVStack row, including the
                    // long markdown bubbles) on every flexible-space round of
                    // the shell VStack — the core multiplier of the 063
                    // stuck-canvas layout livelock. Fixed height = O(1) answer.
                    ChatList().frame(height: 320).background(p.bg)
                }
                Button {
                    // Removing the lazy transcript in an animated layout
                    // transaction can leave UIKit repeatedly placing its
                    // departing rows while the canvas grows. Complete this
                    // structural change before the next scroll interaction.
                    expanded.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Text(expanded ? "▼" : "▲").font(AstralTypography.caption2).foregroundStyle(p.muted)
                        Text("Messages").font(AstralTypography.subheadline.weight(.medium)).foregroundStyle(p.text)
                        Text("(\(visible.count))").font(AstralTypography.caption).foregroundStyle(p.muted)
                        Spacer()
                        if !expanded, let status = model.statusText {
                            Text(status).font(AstralTypography.caption).foregroundStyle(p.muted).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(p.surface)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("workspace-messages-toggle")
            }
        }
    }
}

private struct ChatList: View {
    @Environment(AppModel.self) var model
    private var visible: [AppModel.ChatTurn] {
        model.visibleTurns.filter { !$0.text.isEmpty || !$0.components.isEmpty }
    }

    @ViewBuilder
    private var rows: some View {
        ForEach(visible) { turn in ChatBubble(turn: turn) }
        if let status = model.statusText {
            StatusLine(text: status, showsActivity: model.statusShowsActivity)
                .id("status")
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if TranscriptLayoutPresentation.usesLazyRows {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        rows
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                } else {
                    // AppKit's lazy placement engine can fail to converge when
                    // a voice turn replaces pending rows with committed rows
                    // while the status row disappears. An eager stack has a
                    // deterministic content height and avoids that graph loop.
                    VStack(alignment: .leading, spacing: 8) {
                        rows
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
            .accessibilityIdentifier("conversation-message-scroll")
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: visible.count) { oldCount, newCount in
                guard newCount > oldCount, let lastID = visible.last?.id else { return }
                // Do not mutate scroll geometry inside the same AttributeGraph
                // transaction that inserted the row. Even an unanimated
                // synchronous scroll can feed AppKit's anchor translation back
                // into lazy placement before that transaction settles.
                Task { @MainActor in
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }
}

private struct StatusLine: View {
    @Environment(ThemeStore.self) var theme
    let text: String
    let showsActivity: Bool
    var body: some View {
        HStack(spacing: 6) {
            if showsActivity {
                if ContinuousActivityPresentation.allowsAnimatedIndicators {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "ellipsis")
                        .font(AstralTypography.caption2.weight(.semibold))
                        .accessibilityHidden(true)
                }
            }
            Text(text).font(AstralTypography.caption).foregroundStyle(theme.palette.muted)
        }
    }
}

private struct ChatBubble: View {
    @Environment(ThemeStore.self) var theme
    let turn: AppModel.ChatTurn
    private var p: AstralPalette { theme.palette }
    var body: some View {
        if turn.role == "reasoning" {
            ReasoningSnippet(text: turn.text)
        } else {
            let isUser = turn.role == "user"
            HStack {
                if isUser { Spacer(minLength: 40) }
                VStack(alignment: .leading, spacing: 8) {
                    if !turn.text.isEmpty {
                        if isUser {
                            Text(turn.text).foregroundStyle(p.text)
                        }
                        // Assistant narrative (incl. doc cards diverted into the
                        // transcript) carries block markdown — headings, fences,
                        // lists and tables must render, not show their syntax.
                        else {
                            MarkdownBlockView(source: turn.text).foregroundStyle(p.text)
                        }
                    }
                    ForEach(Array(turn.components.enumerated()), id: \.offset) { _, component in
                        ComponentView(component: component)
                    }
                }
                .font(AstralTypography.subheadline)
                .padding(.horizontal, 14).padding(.vertical, 10)
                // User turns are the web's 20% primary tint + 30% border —
                // not a saturated pill (cross-client bubble convention).
                .background(
                    isUser ? AnyShapeStyle(p.primary.opacity(0.20)) : AnyShapeStyle(p.surface2),
                    in: RoundedRectangle(cornerRadius: AstralRadius.md)
                )
                .astralChartBackdrop(p, color: isUser ? p.primary : p.surface2, opacity: isUser ? 0.20 : 1)
                .overlay(
                    RoundedRectangle(cornerRadius: AstralRadius.md)
                        .stroke(isUser ? p.primary.opacity(0.30) : .clear)
                )
                .frame(maxWidth: isUser ? 300 : .infinity, alignment: isUser ? .trailing : .leading)
                if !isUser { Spacer(minLength: 20) }
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        }
    }
}

private struct ReasoningSnippet: View {
    @Environment(ThemeStore.self) var theme
    let text: String
    @State private var expanded = false
    private var p: AstralPalette { theme.palette }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(expanded ? "▼" : "▶").font(AstralTypography.caption2).foregroundStyle(p.muted)
                    Text("Reasoning").font(AstralTypography.caption.weight(.medium)).foregroundStyle(p.muted)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            if expanded {
                Text(text).font(AstralTypography.caption).foregroundStyle(p.text)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface2.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Input bar

private struct InputBar: View {
    @Environment(AppModel.self) var model
    @Environment(ThemeStore.self) var theme
    // Owned by ChatShell so the draft survives layout-mode switches
    // (stacked/collapsed/split give this view a new structural identity).
    @Binding var input: String
    var framed = true
    @State private var showImporter = false
    #if os(iOS)
        @State private var showPhotoPicker = false
        @State private var photoItem: PhotosPickerItem?
    #endif
    @FocusState private var focused: Bool
    private var p: AstralPalette { theme.palette }
    private let slashCommands = ["/help", "/agents", "/summarize", "/research", "/weather"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.mutationsLocked {
                Text("Viewing history — messaging is paused. Return to the live view to continue.")
                    .font(AstralTypography.caption).foregroundStyle(p.muted)
                    .padding(.horizontal, 6)
            }
            if !model.staged.isEmpty {
                AttachmentChips(staged: model.staged) { model.removeAttachment($0) }
            }
            if input.hasPrefix("/") && !input.contains(" ") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(slashCommands.filter { $0.hasPrefix(input) }, id: \.self) { cmd in
                            Button(cmd) { input = cmd + " " }
                                .font(AstralTypography.mono(12)).foregroundStyle(p.primary)
                        }
                    }
                }
            }
            VoiceComposerNotices()
            TextField("Ask anything…", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("chat-composer-input")
                .accessibilityLabel("Message AstralDeep")
                .lineLimit(2...8)
                .submitLabel(.send)
                .onSubmit(send)
                .disabled(model.mutationsLocked)
                .focused($focused)
                .padding(.horizontal, 4).padding(.vertical, 8)
            ComposerControlsLayout(spacing: 6) {
                Menu {
                    Button("Upload a file") { showImporter = true }
                    #if os(iOS)
                        Button("Choose a photo") { showPhotoPicker = true }
                    #endif
                    Button("Choose from your files") { model.openSurface("attachments") }
                } label: {
                    Image(systemName: "paperclip").font(.system(size: 18)).foregroundStyle(p.muted)
                        .frame(width: 44, height: 44)
                }
                .disabled(model.mutationsLocked)
                .accessibilityLabel("Attach files")
                Button {
                    model.runInBackground.toggle()
                } label: {
                    Image(systemName: "clock")
                        .font(.system(size: 18))
                        .foregroundStyle(model.runInBackground ? p.primary : p.muted)
                        .frame(width: 44, height: 44)
                        .background(
                            model.runInBackground ? p.primary.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(model.mutationsLocked)
                .accessibilityLabel("Run in background")
                .accessibilityValue(model.runInBackground ? "On" : "Off")
                .help("Run the next message in the background")
                VoiceComposerControls()
                SendButton(enabled: canSend) { send() }
            }
        }
        .padding(12)
        .background(framed ? p.surface : .clear, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(framed ? p.border : .clear))
        .padding(8)
        .fileImporter(
            isPresented: $showImporter, allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                model.stageFile(url: url)
            }
        }
        #if os(iOS)
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                        let mime = item.supportedContentTypes.first?.preferredMIMEType
                        model.stageAttachment(
                            filename: "photo-\(UUID().uuidString.prefix(8)).\(ext)",
                            mimeType: mime, data: data)
                    }
                    photoItem = nil
                }
            }
        #endif
    }

    private var canSend: Bool {
        !model.mutationsLocked
            && (!input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || model.staged.contains { $0.state == "ready" })
    }

    private func send() {
        guard canSend else { return }
        let submittedInput = input
        focused = false  // resign native keyboard focus before model-driven re-rendering
        input = ""
        model.sendChat(submittedInput)
    }
}

/// The order, visibility, labels, pressed state, and enabled state all come
/// from the server-owned composer model. This view contributes presentation
/// only; it cannot invent a local voice mutation or bypass REST authorization.
/// The slim rows ABOVE the input: the durable terminal notice and the voice
/// status line. Renders nothing when there is nothing to say.
private struct VoiceComposerNotices: View {
    @Environment(AppModel.self) var model
    @Environment(ThemeStore.self) var theme
    private var p: AstralPalette { theme.palette }

    /// 066/P5+P11: the feedback line renders for every live status and every
    /// unavailability reason, and hides ONLY the at-rest boilerplate
    /// (off/ready — "Voice is available."), so the composer is quiet at rest
    /// without ever showing a disabled mic with no explanation. This is the
    /// Windows quiet-set rule (`state=="off" && message in {"", "off",
    /// "ready"}`); Apple's local fallback fabricates a message for every
    /// state, so gating on off/ready is the equivalent predicate.
    private var statusMessage: String? {
        guard let message = model.voice.message, !message.isEmpty else { return nil }
        if model.voice.phase == "off", model.voice.reason == "ready" { return nil }
        return message
    }

    var body: some View {
        if let notice = model.voice.terminalNotice {
            VoiceTerminalNoticeView(notice: notice)
        }
        if let message = statusMessage {
            HStack(spacing: 5) {
                Image(systemName: model.voice.mediaConnected ? "waveform" : "waveform.slash")
                Text(message).lineLimit(2)
                if model.voice.awaitingAcceptance > 0 {
                    if ContinuousActivityPresentation.allowsAnimatedIndicators {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "ellipsis")
                            .font(AstralTypography.caption2.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                }
            }
            .font(AstralTypography.caption)
            .foregroundStyle(p.muted)
            .padding(.horizontal, 6)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("voice-conversation-status")
        }
    }
}

/// The voice controls themselves, rendered INSIDE the input row at its
/// leading edge — the same composer icon language as the paperclip and Send,
/// matching Android (mic · input · paperclip · send) and Windows (ghost
/// buttons beside the field). Server model drives order/visibility/state.
private struct VoiceComposerControls: View {
    @Environment(AppModel.self) var model
    @Environment(ThemeStore.self) var theme
    private var p: AstralPalette { theme.palette }

    /// 066/P5: before the first `composer_state` of a connection (and after a
    /// teardown clears it) the server model is absent — render a disabled
    /// default mic instead of nothing, the native twin of the web client's
    /// pre-rendered voice-start control. The first real frame replaces it.
    private var showsDefaultControl: Bool {
        model.voice.composer == nil && !model.voice.active
            && model.voice.terminalNotice == nil
    }

    var body: some View {
        let controls = model.voice.composer?.controls.filter(\.visible) ?? []
        if showsDefaultControl {
            inlineIcon(icon: "mic.fill", busy: false, pressed: false)
                .opacity(0.45)
                .accessibilityIdentifier("voice-control-voice-start")
                .accessibilityLabel("Start voice conversation")
                .accessibilityValue("Checking voice availability")
                .help("Checking voice availability…")
        } else if !controls.isEmpty {
            HStack(spacing: 2) {
                ForEach(controls) { control in
                    Button {
                        Task { await model.performVoiceControl(control.action) }
                    } label: {
                        // P11 shared control style: composer controls are
                        // ICONS with the server label as the tooltip +
                        // accessible name — never a text chip.
                        inlineIcon(
                            icon: symbol(control.icon),
                            busy: control.busy,
                            pressed: control.pressed
                        )
                        .opacity(control.enabled ? 1 : 0.45)
                    }
                    .buttonStyle(.plain)
                    .disabled(!control.enabled || control.busy)
                    .accessibilityIdentifier("voice-control-\(control.key)")
                    .accessibilityLabel(control.label)
                    .accessibilityValue(
                        control.busy ? "In progress" : (control.pressed ? "On" : "Off")
                    )
                    .help(control.label)
                }
            }
        }
    }

    @ViewBuilder
    private func inlineIcon(icon: String, busy: Bool, pressed: Bool) -> some View {
        Group {
            if busy {
                if ContinuousActivityPresentation.allowsAnimatedIndicators {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "ellipsis").accessibilityHidden(true)
                }
            } else {
                Image(systemName: icon).font(.system(size: 18))
            }
        }
        .frame(width: 32, height: 32)
        .foregroundStyle(pressed ? Color.white : p.muted)
        .background(
            pressed ? AnyShapeStyle(p.primary) : AnyShapeStyle(.clear),
            in: Circle()
        )
    }

    private func symbol(_ serverIcon: String) -> String {
        switch serverIcon {
        case "microphone": "mic.fill"
        case "device-transfer": "arrow.triangle.2.circlepath"
        case "stop": "stop.fill"
        case "speaker-stop": "speaker.slash.fill"
        case "speaker-muted": "speaker.slash"
        case "speaker-consent": "speaker.wave.2.bubble"
        case "chat": "bubble.left.and.bubble.right"
        default: "waveform"
        }
    }
}

/// A visible and VoiceOver-readable alert anchored to the chat composer. Its
/// icon and explicit title preserve meaning independently of theme color, and
/// all server text is rendered by `Text` as inert plain content.
private struct VoiceTerminalNoticeView: View {
    @Environment(ThemeStore.self) var theme
    let notice: VoiceTerminalNotice
    private var p: AstralPalette { theme.palette }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(AstralTypography.body.weight(.semibold))
                .foregroundStyle(p.error)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(AstralTypography.caption.weight(.bold))
                    .foregroundStyle(p.text)
                Text(notice.serverMessage)
                    .font(AstralTypography.caption)
                    .foregroundStyle(p.text)
                if let guidance = notice.guidance {
                    Text(guidance)
                        .font(AstralTypography.caption)
                        .foregroundStyle(p.text)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.error.opacity(0.14), in: RoundedRectangle(cornerRadius: AstralRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: AstralRadius.md)
                .stroke(p.error.opacity(0.75), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("voice-request-terminal-notice")
        .accessibilityLabel("Voice request alert")
        .accessibilityValue(notice.accessibilityLabel)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

private struct AttachmentChips: View {
    @Environment(ThemeStore.self) var theme
    let staged: [AppModel.StagedAttachment]
    let onRemove: (Int) -> Void
    private var p: AstralPalette { theme.palette }
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(staged) { att in
                    HStack(spacing: 6) {
                        Text(marker(att.state)).font(AstralTypography.caption2)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(att.filename).font(AstralTypography.caption).foregroundStyle(p.text)
                                .lineLimit(1).frame(maxWidth: 160, alignment: .leading)
                            if let note = att.note, !note.isEmpty {
                                Text(note).font(AstralTypography.caption2).foregroundStyle(p.muted).lineLimit(1)
                            }
                        }
                        Button {
                            onRemove(att.uid)
                        } label: {
                            Image(systemName: "xmark").font(AstralTypography.caption2).foregroundStyle(p.muted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(att.filename)")
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(p.surface2, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }
    private func marker(_ state: String) -> String {
        switch state {
        case "uploading": return "…"
        case "failed": return "⚠"
        default: return "📄"
        }
    }
}

private struct GlyphButton: View {
    @Environment(ThemeStore.self) var theme
    let system: String
    var enabled: Bool = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 18))
                .foregroundStyle(theme.palette.muted.opacity(enabled ? 1 : 0.4))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Wrap controls at their intrinsic widths instead of squeezing the text
/// editor. The final Send control aligns to the trailing edge of its row.
private struct ComposerControlsLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        return CGSize(width: width, height: positions(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = positions(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(
                    x: bounds.minX + result.points[index].x,
                    y: bounds.minY + result.points[index].y),
                proposal: .unspecified)
        }
    }

    private func positions(width: CGFloat, subviews: Subviews) -> (points: [CGPoint], height: CGFloat) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var points: [CGPoint] = []
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            if index == subviews.count - 1 { x = max(x, width - size.width) }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (points, y + rowHeight)
    }
}

private struct SendButton: View {
    @Environment(ThemeStore.self) var theme
    let enabled: Bool
    let action: () -> Void
    private var p: AstralPalette { theme.palette }
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(enabled ? AnyShapeStyle(p.primary) : AnyShapeStyle(p.surface2), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel("Send message")
    }
}

// MARK: - shimmer + safe index

enum TranscriptLayoutPresentation {
    /// AppKit's `LazyVStack` placement can remain inside one AttributeGraph
    /// transaction when transcript identities and heights change together.
    /// iOS keeps lazy rows for long mobile transcripts; macOS uses bounded,
    /// eager placement inside the rail's concrete viewport.
    static var usesLazyRows: Bool {
        #if os(macOS)
            false
        #else
            true
        #endif
    }
}

enum ContinuousActivityPresentation {
    /// AppKit's indeterminate progress views and animation timelines can feed
    /// their ticks back through the transcript LazyVStack. On macOS that can
    /// keep the main view graph permanently dirty, starving websocket/media
    /// work and growing memory without bound. Static busy affordances retain
    /// the visible state while limiting layout to real model changes.
    static var allowsAnimatedIndicators: Bool {
        #if os(macOS)
            false
        #else
            true
        #endif
    }
}

extension View {
    func shimmer() -> some View { modifier(ShimmerModifier()) }

    @ViewBuilder
    func activityShimmer() -> some View {
        if ContinuousActivityPresentation.allowsAnimatedIndicators {
            shimmer()
        } else {
            self
        }
    }
}

struct ShimmerModifier: ViewModifier {
    /// The moving highlight must never dirty the view graph outside this
    /// overlay. The previous `repeatForever` animation on an `@State` phase
    /// forced a FULL layout pass of the hosting view on every animation
    /// frame; once the chat screen's layout cost exceeded one frame
    /// interval, the main thread livelocked in back-to-back layout and the
    /// @MainActor frame reducer starved — delivered `conversation_snapshot`
    /// / `chat_status done` frames were never reduced and the skeleton
    /// latched forever (the 063 stuck-canvas defect; same class as the 061
    /// grid-clamp hang). `TimelineView` scopes each tick's invalidation to
    /// the gradient subtree, so outer layout runs only when real state
    /// changes.
    func body(content: Content) -> some View {
        content.overlay(
            GeometryReader { geo in
                TimelineView(.animation) { context in
                    let cycle =
                        context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 1.3) / 1.3
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.18), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.6)
                    .offset(x: geo.size.width * ShimmerModifier.phase(cycle: cycle))
                }
            }
            .allowsHitTesting(false)
        )
        .clipped()
    }

    /// Pure sweep curve: cycle ∈ [0, 1) → offset multiplier in [-1, 1.6),
    /// the same left-to-right pass the animated @State produced.
    static func phase(cycle: Double) -> CGFloat {
        CGFloat(-1 + cycle * 2.6)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

#Preview("Chat shell") {
    let model = AppModel()
    model.turns = [
        .init(id: "u0", role: "user", text: "Show me Q3 sales"),
        .init(id: "a0", role: "assistant", text: "Here's a **live summary** of Q3."),
    ]
    // Authored with AstralPrims (the Swift astralprims mirror) — the same
    // wire dicts a Python agent would produce.
    model.canvas = [
        AstralPrims.Hero(
            title: "Q3 Sales",
            subtitle: "Revenue up 12% quarter over quarter",
            variant: "gradient"),
        AstralPrims.Grid(columns: 2).add(
            AstralPrims.MetricCard(title: "Revenue", value: "$1.2M", subtitle: "+12%"),
            AstralPrims.MetricCard(title: "New users", value: "3,401", variant: "success")),
    ].compactMap { AstralComponent(json: $0.toDict()) }
    return ChatShell()
        .environment(model)
        .environment(model.themeStore)
        .preferredColorScheme(.dark)
}
