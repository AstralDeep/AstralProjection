// The SwiftUI sheet that shows one ConsentPrompt and lets the person approve with biometrics or passcode, or deny.
// It reads only ConsentPrompt fields from ConsentCoordinator, so model text and component trees never reach this screen.

import SwiftUI

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
                    field("Tool", prompt.effect, id: "consent.effect")
                    field("Target", prompt.target, id: "consent.target")
                    argumentsField
                    if let source = prompt.untrustedSource {
                        Label {
                            Text("Influenced by untrusted content: \(source)")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("consent.untrusted")
                    }
                    if !prompt.labels.isEmpty {
                        field("Labels", prompt.labels.joined(separator: ", "), id: "consent.labels")
                    }
                    field("Digest", prompt.shortDigest, id: "consent.digest", monospaced: true)
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
                        if isAuthenticating { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
                        else { Text("Approve").frame(maxWidth: .infinity) }
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

private struct ConsentSheetPresenter: ViewModifier {
    let coordinator: ConsentCoordinator

    func body(content: Content) -> some View {
        content.sheet(
            isPresented: Binding(
                get: { coordinator.current != nil },
                set: { presented in if !presented { coordinator.deny() } })
        ) {
            if let prompt = coordinator.current {
                ConsentSheet(
                    prompt: prompt, isAuthenticating: coordinator.isAuthenticating,
                    message: coordinator.authenticationMessage,
                    onApprove: { Task { await coordinator.approve() } },
                    onDeny: { coordinator.deny() })
            }
        }
    }
}

extension View {
    func consentSheet(_ coordinator: ConsentCoordinator) -> some View {
        modifier(ConsentSheetPresenter(coordinator: coordinator))
    }
}
