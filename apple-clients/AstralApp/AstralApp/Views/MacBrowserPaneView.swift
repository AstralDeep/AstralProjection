// Shows the Mac browser pane with its address bar, back and forward, the "Astral is driving" chip, Take over,
// any waiting page dialog and the pane's web view. MacBrowserDriver supplies the state; the workbench decides
// where the view appears through the driver's isPresented flag.

#if os(macOS)
    import AppKit
    import SwiftUI
    import WebKit

    struct MacBrowserPaneView: View {
        @Bindable var driver: MacBrowserDriver
        @State private var address = ""
        @FocusState private var editingAddress: Bool

        var body: some View {
            VStack(spacing: 0) {
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
                MacBrowserWebViewHost(pane: driver.pane)
            }
            .onAppear { address = driver.pane.url?.absoluteString ?? "" }
            .onChange(of: driver.pane.url) { _, url in
                if !editingAddress { address = url?.absoluteString ?? "" }
            }
        }
    }

    struct MacBrowserWebViewHost: NSViewRepresentable {
        let pane: MacBrowserPane

        func makeNSView(context: Context) -> NSView {
            let container = NSView()
            attach(to: container)
            return container
        }

        func updateNSView(_ view: NSView, context: Context) {
            if pane.webView.superview !== view { attach(to: view) }
        }

        static func dismantleNSView(_ view: NSView, coordinator: ()) {
            for subview in view.subviews where subview is WKWebView { subview.removeFromSuperview() }
        }

        private func attach(to container: NSView) {
            let webView = pane.webView
            webView.removeFromSuperview()
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            container.addSubview(webView)
        }
    }
#endif
