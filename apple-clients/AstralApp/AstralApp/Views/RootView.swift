import AstralCore
// Feature 051 — the app shell, a 1:1 match to the Android RootScaffold: a
// minimal top bar (square brand mark · New pill · Recent · server-owned chrome
// actions · Settings gear whose dropdown is built ENTIRELY from the server
// `chrome_menu` model), a connection strip + dismissible banner, and the
// navigable surfaces (Chat / Agents / History / Audit / Surface).
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

struct RootView: View {
    @Environment(AppModel.self) var model
    @Environment(ThemeStore.self) var theme

    @State private var viewportWidth: CGFloat = 1024
    private var p: AstralPalette { theme.palette }

    var body: some View {
        Group {
            if !model.signedIn {
                SignInView()
            } else {
                signedIn
            }
        }
        .background(rootBackground.ignoresSafeArea())
    }

    private var rootBackground: some View { p.bg }

    private var signedIn: some View {
        VStack(spacing: 0) {
            AstralTopBar()
            if let label = model.connectionStripLabel {
                ConnectionStrip(label: label)
            }
            if let banner = model.errorBanner {
                BannerBar(text: banner, isError: model.bannerIsError) { model.dismissBanner() }
            }
            surface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(\.astralViewportWidth, viewportWidth)
        .background(p.bg.ignoresSafeArea())
        // T030: rotation / iPad Split View / macOS resize → update_device so
        // ROTE re-derives the layout for this socket.
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        viewportWidth = geo.size.width
                        model.viewportChanged(
                            width: Int(geo.size.width),
                            height: Int(geo.size.height))
                    }
                    .onChange(of: geo.size) { _, size in
                        viewportWidth = size.width
                        model.viewportChanged(
                            width: Int(size.width),
                            height: Int(size.height))
                    }
            }
        )
    }

    @ViewBuilder
    private var surface: some View {
        switch model.screen {
        case .chat: ChatShell()
        case .agents: AgentsView()
        case .history: HistoryView()
        case .audit: AuditView()
        case .surface: SurfaceView()
        }
    }
}

// MARK: - Top bar

/// Keep the web's compact outline inside a native 44-point interaction target.
struct AstralNewChatButton: View {
    let viewportWidth: CGFloat
    let palette: AstralPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 18, weight: .regular))
                if viewportWidth >= 640 {
                    Text("New chat").font(AstralTypography.subheadline)
                        .accessibilityIdentifier("new-chat-visible-label")
                }
            }
            .foregroundStyle(palette.text)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .frame(minHeight: 38)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.text.opacity(0.13)))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New chat")
        .accessibilityIdentifier("new-chat-button")
    }
}

struct AstralTopBar: View {
    @Environment(AppModel.self) var model
    @Environment(ThemeStore.self) var theme
    @Environment(\.astralViewportWidth) private var viewportWidth
    @State private var exportContext: AppModel.WorkspaceActionContext?
    @State private var shareContext: AppModel.WorkspaceActionContext?
    @State private var shareTask: Task<Void, Never>?
    private var p: AstralPalette { theme.palette }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image("AstralIcon")
                .resizable().scaledToFit()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: AstralRadius.sm))
                .frame(height: 44)

            AstralToolbarLayout(wraps: viewportWidth < 700) {
                // 054 first-run gate: while the server pins a mandatory surface,
                // every navigation control is hidden — only the Settings gear
                // stays, reduced to its sign-out affordance (FR-013).
                if !model.mandatorySurface {
                    newButton

                    Button {
                        model.goTo(.history)
                    } label: {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 18)).foregroundStyle(p.text)
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Recent chats")

                    // Server-owned top-bar actions (pulse / timeline), rendered from the model.
                    ForEach(model.chromeMenu?.topbarActions ?? []) { control in
                        if let workspaceAction = control.workspaceAction {
                            if model.workspaceActionContext(for: workspaceAction) != nil {
                                Button {
                                    startWorkspaceAction(workspaceAction)
                                } label: {
                                    Image(systemName: topBarIcon(control.icon))
                                        .font(.system(size: 18)).foregroundStyle(p.text)
                                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(
                                    model.workspaceActionInFlight(workspaceAction)
                                        || (workspaceAction == .exportCanvas && exportContext != nil)
                                )
                                .accessibilityLabel(control.label ?? control.key)
                                .accessibilityIdentifier("workspace-action-\(control.key)")
                            }
                        } else if let action = control.action, !action.surface.isEmpty {
                            Button {
                                model.openSurface(action.surface, params: action.params)
                            } label: {
                                Image(systemName: topBarIcon(control.icon))
                                    .font(.system(size: 18)).foregroundStyle(p.text)
                                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(control.label ?? action.surface)
                        }
                    }
                }

                settingsMenu
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(p.surface)
        .sheet(item: $exportContext) { context in
            if let url = model.workspaceExportURL(context) {
                ExportDownloadSheet(url: url, filename: "astraldeep-canvas.html", workspaceExport: context)
            }
        }
        .onChange(of: exportIsCurrent) { _, current in
            if !current { exportContext = nil }
        }
        .onChange(of: shareIsCurrent) { _, current in
            if !current { shareTask?.cancel() }
        }
        .onDisappear {
            exportContext = nil
            shareTask?.cancel()
        }
    }

    private var exportIsCurrent: Bool { exportContext.map(model.workspaceActionIsCurrent) ?? false }
    private var shareIsCurrent: Bool { shareContext.map(model.workspaceActionIsCurrent) ?? false }

    private func startWorkspaceAction(_ action: WorkspaceAction) {
        guard let context = model.workspaceActionContext(for: action),
            !model.workspaceActionInFlight(action)
        else { return }
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
                    ? "Sharing refused: the content matched the PHI gate."
                    : "Couldn't create the share link."
            }
        }
    }

    private var newButton: some View {
        AstralNewChatButton(viewportWidth: viewportWidth, palette: p) { model.newChat() }
    }

    private var settingsMenu: some View {
        Menu {
            // 054: server menu items are navigation — suppressed while the
            // mandatory surface is pinned; sign-out below always remains.
            if !model.mandatorySurface {
                ForEach(model.chromeMenu?.menu ?? []) { group in
                    Section(group.label) {
                        ForEach(group.items) { item in
                            Button(item.label) { model.openMenuItem(item) }
                        }
                    }
                }
                Divider()
            }
            if !model.accountName.isEmpty {
                Text(model.accountName)
            }
            Button(role: .destructive) {
                Task { await model.signOut() }
            } label: {
                Label(
                    model.chromeMenu?.signout.label ?? "Sign out",
                    systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: {
            Image(systemName: "gearshape").font(.system(size: 18)).foregroundStyle(p.text)
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .accessibilityLabel("Settings")
    }

    // P11: keyed on the server model's own icon names (sparkle/history/gear —
    // menu_model.py), the same rule the Windows fix pinned after its map was
    // keyed on names the server never sends.
    private func topBarIcon(_ icon: String?) -> String {
        switch icon {
        case "sparkle": return "sparkles"
        case "history": return "clock.arrow.circlepath"
        case "gear": return "gearshape"
        case "download": return "arrow.down.to.line"
        case "share": return "square.and.arrow.up"
        default: return "ellipsis.circle"
        }
    }
}

/// The server's compact chrome contract preserves order and wraps the action
/// cluster at its natural touch-target sizes. The brand is laid out separately.
struct AstralToolbarLayout: Layout {
    var wraps: Bool
    var spacing: CGFloat = 6

    static func frames(sizes: [CGSize], width: CGFloat, spacing: CGFloat, wraps: Bool) -> [CGRect] {
        var rows: [[CGRect]] = [[]]
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for size in sizes {
            if wraps, x > 0, x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
                rows.append([])
            }
            rows[rows.count - 1].append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return rows.flatMap { row in
            let offset = max(0, width - (row.last?.maxX ?? 0))
            return row.map { $0.offsetBy(dx: offset, dy: 0) }
        }
    }

    private func frames(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        Self.frames(sizes: subviews.map { $0.sizeThatFits(.unspecified) }, width: width, spacing: spacing, wraps: wraps)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width + spacing }
        let positions = frames(subviews, width: width)
        return CGSize(width: width, height: positions.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, frames(subviews, width: bounds.width)) {
            view.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}

// MARK: - Strips

struct ConnectionStrip: View {
    @Environment(ThemeStore.self) var theme
    let label: String
    var body: some View {
        Text(label)
            .font(AstralTypography.caption)
            .foregroundStyle(theme.palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 5)
            .background(theme.palette.surface2)
    }
}

struct BannerBar: View {
    @Environment(ThemeStore.self) var theme
    let text: String
    let isError: Bool
    let onDismiss: () -> Void

    var body: some View {
        let color = isError ? theme.palette.error : theme.palette.info
        HStack(spacing: 8) {
            Text(text).font(AstralTypography.footnote).foregroundStyle(theme.palette.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(AstralTypography.caption).foregroundStyle(theme.palette.muted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(color.opacity(0.16))
    }
}

// MARK: - Sign in (logo + SSO only; server/realm come from AstralConfig)

struct SignInView: View {
    @Environment(AppModel.self) var model

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image("AstralDeepLogo")
                .resizable().scaledToFit()
                .frame(maxWidth: 320)
                .accessibilityLabel("AstralDeep")
            Spacer()
            Button {
                model.signIn()
            } label: {
                Label("Sign in with SSO", systemImage: "person.badge.key")
                    .font(AstralTypography.headline)
                    .frame(maxWidth: 320)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Sign in with single sign-on")
            if let error = model.signInError {
                Text(error).font(AstralTypography.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Spacer().frame(height: 48)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private func previewTopBarAction(_ key: String, _ icon: String, _ label: String, _ surface: String) -> JSONValue {
    var o: [String: JSONValue] = [:]
    o["key"] = .string(key)
    o["kind"] = .string("action")
    o["icon"] = .string(icon)
    o["label"] = .string(label)
    o["action"] = .object(["surface": .string(surface)])
    return .object(o)
}

private func previewMenuItem(_ key: String, _ label: String, _ surface: String) -> JSONValue {
    .object(["key": .string(key), "label": .string(label), "surface": .string(surface)])
}

private func previewChrome() -> ChromeMenuModel? {
    let topbar: [JSONValue] = [
        previewTopBarAction("pulse", "sparkle", "Pulse", "pulse"),
        previewTopBarAction("timeline", "history", "Timeline", "workspace_timeline"),
        .object(["key": .string("settings"), "kind": .string("menu")]),
    ]
    let account: JSONValue = .object([
        "key": .string("account"), "label": .string("Account"),
        "items": .array([
            previewMenuItem("agents", "Agents & permissions", "agents"),
            previewMenuItem("llm", "Model settings", "llm"),
            previewMenuItem("theme", "Appearance", "theme"),
        ]),
    ])
    let help: JSONValue = .object([
        "key": .string("help"), "label": .string("Help"),
        "items": .array([previewMenuItem("audit", "Activity log", "audit")]),
    ])
    var root: [String: JSONValue] = [:]
    root["version"] = .number(1)
    root["topbar"] = .array(topbar)
    root["menu"] = .array([account, help])
    root["signout"] = .object(["label": .string("Sign out")])
    return ChromeMenuModel.fromJSON(.object(root))
}

private func previewCanvas() -> [AstralComponent] {
    // Authored with AstralPrims (the Swift astralprims mirror).
    [
        AstralPrims.Hero(
            title: "Q3 Sales",
            subtitle: "Revenue up 12% quarter over quarter",
            variant: "gradient"),
        AstralPrims.MetricCard(title: "Revenue", value: "$1.2M", subtitle: "+12%"),
    ].compactMap { AstralComponent(json: $0.toDict()) }
}

#Preview("Signed-in shell") {
    let model = AppModel()
    model.signedIn = true
    model.connected = true
    model.everConnected = true
    model.accountName = "Sam"
    model.turns = [.init(id: "u0", role: "user", text: "Show me Q3 sales")]
    model.canvas = previewCanvas()
    model.chromeMenu = previewChrome()
    return RootView()
        .environment(model)
        .environment(model.themeStore)
        .preferredColorScheme(.dark)
}
