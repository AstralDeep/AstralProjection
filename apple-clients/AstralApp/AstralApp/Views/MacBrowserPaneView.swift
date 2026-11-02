// Shows the Mac browser pane: a tab strip, the address bar with back, forward and reload, the viewport and appearance
// menu, the "Astral is driving" chip, Take over, any waiting page dialog, the letterboxed web view and a read-only
// console drawer. MacBrowserDriver supplies the state; the workbench places the view through driver.isPresented.

#if os(macOS)
    import AppKit
    import AstralCore
    import SwiftUI
    import WebKit

    struct MacBrowserPaneView: View {
        @Bindable var driver: MacBrowserDriver
        @State private var address = ""
        @State private var consoleShown = false
        @FocusState private var editingAddress: Bool

        var body: some View {
            VStack(spacing: 0) {
                MacBrowserTabStrip(driver: driver)
                HStack(spacing: 8) {
                    Button(action: { driver.userHistory("back") }) { Image(systemName: "chevron.backward") }
                        .disabled(!driver.pane.canGoBack).help("Back").accessibilityLabel("Back")
                    Button(action: { driver.userHistory("forward") }) { Image(systemName: "chevron.forward") }
                        .disabled(!driver.pane.canGoForward).help("Forward").accessibilityLabel("Forward")
                    Button(action: { driver.userHistory("reload") }) { Image(systemName: "arrow.clockwise") }
                        .disabled(driver.pane.url == nil).help("Reload").accessibilityLabel("Reload")
                    TextField("Address", text: $address)
                        .textFieldStyle(.roundedBorder).focused($editingAddress)
                        .onSubmit { driver.userNavigate(address) }
                        .accessibilityIdentifier("mac-browser-address")
                    if let size = driver.emulation {
                        Text(verbatim: "\(size.width)×\(size.height)")
                            .font(.caption.monospacedDigit()).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().strokeBorder(Color.secondary.opacity(0.4)))
                            .accessibilityLabel("Viewport \(size.width) by \(size.height)")
                            .accessibilityIdentifier("mac-browser-viewport-size")
                    }
                    MacBrowserViewportMenu(driver: driver)
                    Button(action: { consoleShown.toggle() }) {
                        Image(systemName: "terminal")
                            .overlay(alignment: .topTrailing) {
                                if driver.pane.console.contains(where: { $0.level == "error" }) {
                                    Circle().fill(Color.red).frame(width: 6, height: 6).offset(x: 3, y: -3)
                                }
                            }
                    }
                    .help(consoleShown ? "Hide console" : "Show console")
                    .accessibilityLabel("Console").accessibilityValue(consoleShown ? "Shown" : "Hidden")
                    .accessibilityIdentifier("mac-browser-console-toggle")
                    if driver.driving {
                        Label("Astral is driving", systemImage: "cursorarrow.motionlines")
                            .font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                            .accessibilityIdentifier("mac-browser-driving")
                    }
                    if driver.agentActive() {
                        Button("Take over", action: driver.requestTakeover)
                            .accessibilityIdentifier("mac-browser-take-over")
                    }
                }
                .padding(8)
                if let dialog = driver.pane.dialogs.first {
                    HStack(spacing: 8) {
                        Text(dialog.message).lineLimit(3).textSelection(.enabled)
                        Spacer()
                        if dialog.type != "alert" {
                            Button("Cancel") { driver.userAnswerDialog(accept: false) }
                        }
                        Button("OK") { driver.userAnswerDialog(accept: true) }.keyboardShortcut(.defaultAction)
                    }
                    .padding(8).background(.bar).accessibilityIdentifier("mac-browser-dialog")
                }
                if let error = driver.lastError {
                    Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("mac-browser-error")
                }
                Divider()
                MacBrowserWebViewHost(pane: driver.pane, emulation: driver.emulation)
                if consoleShown {
                    Divider()
                    MacBrowserConsoleDrawer(entries: driver.pane.console)
                }
            }
            .onAppear { address = driver.pane.url?.absoluteString ?? "" }
            .onChange(of: driver.pane.url) { _, url in
                if !editingAddress { address = url?.absoluteString ?? "" }
            }
            .onChange(of: driver.activeTabId) { _, _ in
                if !editingAddress { address = driver.pane.url?.absoluteString ?? "" }
            }
        }
    }

    struct MacBrowserTabStrip: View {
        @Bindable var driver: MacBrowserDriver

        var body: some View {
            HStack(spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(driver.tabs) { tab in
                            MacBrowserTabButton(
                                pane: tab.pane, active: tab.id == driver.activeTabId, closable: driver.tabs.count > 1,
                                select: { driver.userSelectTab(tab.id) }, close: { driver.userCloseTab(tab.id) }
                            )
                            .accessibilityIdentifier("mac-browser-tab-\(tab.id)")
                        }
                    }
                }
                Button(action: driver.userNewTab) { Image(systemName: "plus") }
                    .buttonStyle(.borderless).disabled(driver.tabs.count >= MacBrowserDriver.maximumTabs)
                    .help("New tab").accessibilityLabel("New tab").accessibilityIdentifier("mac-browser-new-tab")
            }
            .padding(.horizontal, 8).padding(.top, 6)
            .accessibilityElement(children: .contain).accessibilityLabel("Tabs")
        }
    }

    struct MacBrowserTabButton: View {
        let pane: MacBrowserPane
        let active: Bool
        let closable: Bool
        let select: () -> Void
        let close: () -> Void

        private var label: String {
            if !pane.title.isEmpty { return pane.title }
            return pane.url?.host ?? "New tab"
        }

        var body: some View {
            HStack(spacing: 4) {
                Button(action: select) {
                    Text(verbatim: label).lineLimit(1).truncationMode(.tail).frame(maxWidth: 160, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label).accessibilityAddTraits(active ? .isSelected : [])
                if closable {
                    Button(action: close) { Image(systemName: "xmark").font(.caption2) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Close tab").accessibilityLabel("Close \(label)")
                }
            }
            .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(active ? Color.accentColor.opacity(0.18) : Color.clear)
            )
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(active ? 0.35 : 0.2)))
        }
    }

    struct MacBrowserViewportMenu: View {
        @Bindable var driver: MacBrowserDriver

        var body: some View {
            Menu {
                Button("Desktop") { driver.userResize(preset: "desktop") }
                ForEach(["tablet", "mobile"], id: \.self) { name in
                    if let size = ComputerBrowserViewport.presets[name] {
                        Button(name.capitalized + " \(size.width)×\(size.height)") { driver.userResize(preset: name) }
                    }
                }
                Divider()
                Button("Light appearance") { driver.userColorScheme("light") }
                Button("Dark appearance") { driver.userColorScheme("dark") }
                Button("System appearance") { driver.userColorScheme(nil) }
            } label: {
                Image(systemName: driver.emulation == nil ? "macwindow" : "iphone")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Viewport").accessibilityLabel("Viewport").accessibilityIdentifier("mac-browser-viewport")
        }
    }

    struct MacBrowserConsoleDrawer: View {
        let entries: [MacBrowserConsoleEntry]

        var body: some View {
            ScrollViewReader { proxy in
                List(entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: Self.symbol(entry.level))
                            .foregroundStyle(
                                entry.level == "error" ? .red : entry.level == "warn" ? .orange : .secondary
                            )
                            .accessibilityLabel(entry.level)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: entry.text).font(.caption.monospaced()).lineLimit(4).textSelection(.enabled)
                            if !entry.url.isEmpty {
                                Text(verbatim: entry.line > 0 ? "\(entry.url):\(entry.line)" : entry.url)
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                    .id(entry.id)
                }
                .listStyle(.plain)
                .overlay {
                    if entries.isEmpty {
                        Text("No console messages").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onChange(of: entries.last?.id) { _, last in
                    if let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            .frame(height: 170)
            .accessibilityElement(children: .contain).accessibilityLabel("Console")
            .accessibilityIdentifier("mac-browser-console")
        }

        static func symbol(_ level: String) -> String {
            switch level {
            case "error": return "xmark.octagon"
            case "warn": return "exclamationmark.triangle"
            default: return "info.circle"
            }
        }
    }

    final class MacBrowserViewportView: NSView {
        var emulation: ComputerBrowserViewport? {
            didSet { if emulation != oldValue { needsLayout = true } }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }

        required init?(coder: NSCoder) { nil }

        func show(_ webView: WKWebView) {
            for case let other as WKWebView in subviews where other !== webView { other.removeFromSuperview() }
            if webView.superview !== self {
                webView.removeFromSuperview()
                webView.autoresizingMask = []
                addSubview(webView)
            }
            needsLayout = true
        }

        override func layout() {
            super.layout()
            for case let webView as WKWebView in subviews {
                Self.place(webView, emulation: emulation, in: bounds)
            }
        }

        static func place(_ webView: WKWebView, emulation: ComputerBrowserViewport?, in slot: CGRect?) {
            let frame: CGRect
            let zoom: CGFloat
            if let emulation {
                let fitted = emulation.letterbox(in: slot?.size ?? .zero)
                frame = fitted.frame.offsetBy(
                    dx: slot?.minX ?? webView.frame.minX, dy: slot?.minY ?? webView.frame.minY)
                zoom = fitted.scale
            } else {
                frame = slot ?? webView.frame
                zoom = 1
            }
            if webView.frame != frame { webView.frame = frame }
            if abs(webView.pageZoom - zoom) > 0.0001 { webView.pageZoom = zoom }
        }
    }

    struct MacBrowserWebViewHost: NSViewRepresentable {
        let pane: MacBrowserPane
        let emulation: ComputerBrowserViewport?

        func makeNSView(context: Context) -> MacBrowserViewportView {
            let container = MacBrowserViewportView()
            container.emulation = emulation
            container.show(pane.webView)
            return container
        }

        func updateNSView(_ view: MacBrowserViewportView, context: Context) {
            view.emulation = emulation
            view.show(pane.webView)
        }

        static func dismantleNSView(_ view: MacBrowserViewportView, coordinator: ()) {
            for subview in view.subviews where subview is WKWebView { subview.removeFromSuperview() }
        }
    }
#endif
