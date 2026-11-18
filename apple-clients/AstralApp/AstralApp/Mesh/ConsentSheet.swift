// The SwiftUI sheet that shows one ConsentPrompt and lets the person approve with biometrics or passcode, or deny.
// It reads only ConsentPrompt fields from ConsentCoordinator, so model text and component trees never reach this screen.

import SwiftUI

#if os(macOS)
    import AppKit
#endif

struct ConsentSheet: View {
    let prompt: ConsentPrompt
    let isAuthenticating: Bool
    let message: String?
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(prompt.actionTitle)
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("consent.title")
                    Text(prompt.summaryLine)
                        .font(.body)
                        .accessibilityIdentifier("consent.summary")
                    untrustedNotice
                    if !prompt.labels.isEmpty {
                        field("Labels", prompt.labels.joined(separator: ", "), id: "consent.labels")
                    }
                    detailsDisclosure
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("consent.message")
                }
                HStack {
                    Button(role: .cancel, action: onDeny) { Text("Deny").frame(maxWidth: .infinity) }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel("Deny this action")
                        .accessibilityIdentifier("consent.deny")
                    Button(action: onApprove) {
                        if isAuthenticating {
                            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                        } else {
                            Text("Approve").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isAuthenticating)
                    .accessibilityLabel(
                        prompt.requiresBiometry
                            ? "Approve this action with biometrics" : "Approve this action with biometrics or passcode"
                    )
                    .accessibilityIdentifier("consent.approve")
                }
                .controlSize(.large)
            }
            .padding(20)
        }
        #if os(macOS)
            .frame(minWidth: 440, minHeight: 360)
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("consent.sheet")
    }

    @ViewBuilder
    private var untrustedNotice: some View {
        if let source = prompt.untrustedSource {
            Label {
                Text("Influenced by untrusted content: \(source)")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("consent.untrusted")
        }
    }

    private var detailsDisclosure: some View {
        DisclosureGroup("Details") {
            VStack(alignment: .leading, spacing: 12) {
                field("Tool", prompt.effect, id: "consent.effect")
                field("Target", prompt.target, id: "consent.target")
                argumentsField
                field("Digest", prompt.shortDigest, id: "consent.digest", monospaced: true)
            }
            .padding(.top, 8)
        }
        .accessibilityIdentifier("consent.details")
    }

    private var argumentsField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Arguments").font(.subheadline).foregroundStyle(.secondary)
            Text(prompt.arguments.isEmpty ? "None" : prompt.arguments)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("consent.arguments")
    }

    private func field(_ name: String, _ value: String, id: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.subheadline).foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }
}

private struct ConsentPresentationDepthKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    fileprivate var consentPresentationDepth: Int {
        get { self[ConsentPresentationDepthKey.self] }
        set { self[ConsentPresentationDepthKey.self] = newValue }
    }
}

private struct ConsentSheetPresenter: ViewModifier {
    let coordinator: ConsentCoordinator
    @Environment(\.consentPresentationDepth) private var depth
    @State private var presenter = UUID()

    func body(content: Content) -> some View {
        let presentation = coordinator.presentation(for: presenter)
        content.environment(\.consentPresentationDepth, depth + 1).sheet(
            isPresented: Binding(
                get: { presentation != nil },
                set: { presented in
                    if !presented, let presentation { coordinator.deny(presentation) }
                })
        ) {
            if let presentation {
                ConsentSheet(
                    prompt: presentation.prompt, isAuthenticating: coordinator.isAuthenticating,
                    message: coordinator.authenticationMessage,
                    onApprove: { Task { await coordinator.approve(presentation) } },
                    onDeny: { coordinator.deny(presentation) })
            }
        }
        #if os(macOS)
            .background { ConsentHostSheetWatcher { coordinator.releasePresenter(presenter) } }
        #endif
        .onAppear { coordinator.registerPresenter(presenter, depth: depth) }
        .onDisappear { coordinator.releasePresenter(presenter) }
    }
}

#if os(macOS)
    // AppKit can end a parent sheet while SwiftUI keeps its content alive behind an attached consent sheet.
    private struct ConsentHostSheetWatcher: NSViewRepresentable {
        let onSheetEnded: () -> Void

        func makeNSView(context: Context) -> WatcherView { WatcherView() }

        func updateNSView(_ view: WatcherView, context: Context) { view.onSheetEnded = onSheetEnded }

        final class WatcherView: NSView {
            var onSheetEnded: (() -> Void)?

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                NotificationCenter.default.removeObserver(self, name: NSWindow.didEndSheetNotification, object: nil)
                guard window != nil else { return }
                NotificationCenter.default.addObserver(
                    self, selector: #selector(sheetEnded), name: NSWindow.didEndSheetNotification, object: nil)
            }

            @objc private func sheetEnded(_ notification: Notification) {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let window = self.window, window.isSheet, window.sheetParent == nil else { return }
                    self.onSheetEnded?()
                }
            }
        }
    }
#endif

extension View {
    func consentSheet(_ coordinator: ConsentCoordinator) -> some View {
        modifier(ConsentSheetPresenter(coordinator: coordinator))
    }
}
