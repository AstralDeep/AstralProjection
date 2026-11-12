// Presents the local voice model's size, consent, progress, failures and removal controls.
// The chat microphone opens this sheet and all downloads go through VoiceModelStore.

import SwiftUI

struct VoiceModelSetupView: View {
    @Bindable var controller: OnDeviceVoiceController
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false

    var body: some View {
        NavigationStack {
            Form {
                if let store = controller.store {
                    if case .unsupported(let reason) = store.state {
                        Text(reason.message).accessibilityIdentifier("voice-model-unsupported")
                    } else {
                        Section {
                            Text(store.manifest.displayName)
                            Text(
                                "Download \(store.manifest.sizeDescription) to recognize speech and speak on this device."
                            )
                            .foregroundStyle(.secondary)
                            modelState(store)
                        }
                        if let message = controller.message,
                            !(store.state == .installed && !controller.conversationReady)
                        {
                            Text(message).accessibilityIdentifier("voice-model-message")
                        }
                        if store.state == .installed {
                            Button("Delete voice model", role: .destructive) { confirmingDelete = true }
                                .accessibilityIdentifier("voice-model-delete")
                        }
                        Section {
                            Text(store.manifest.license).font(.footnote)
                        }
                    }
                } else {
                    Text(VoiceModelFailure.manifestUnavailable.message)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Voice")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .frame(minWidth: 320, minHeight: 300)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice-model-setup")
        .alert("Download on this connection?", isPresented: $controller.showingMeteredConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Download") { Task { await controller.confirmDownload(allowMetered: true) } }
        } message: {
            Text("This downloads \(controller.downloadSize ?? "the voice model") using your current connection.")
        }
        .confirmationDialog("Delete the voice model?", isPresented: $confirmingDelete) {
            Button("Delete voice model", role: .destructive) { Task { await controller.deleteModel() } }
        } message: {
            Text("You can download it again when you need voice.")
        }
        .task { await controller.store?.attach() }
    }

    @ViewBuilder
    private func modelState(_ store: VoiceModelStore) -> some View {
        switch store.state {
        case .unsupported(let reason):
            Text(reason.message).accessibilityIdentifier("voice-model-unsupported")
        case .notInstalled:
            downloadButton("Download \(store.manifest.sizeDescription)")
        case .downloading(let progress):
            ProgressView(value: progress.fraction) {
                Text(progress.verifying ? "Verifying download…" : "Downloading voice model…")
            }
            .accessibilityIdentifier("voice-model-progress")
            Button("Cancel download", role: .cancel) { Task { await controller.cancelDownload() } }
                .accessibilityIdentifier("voice-model-cancel")
        case .failed(let failure):
            Text(failure.message).accessibilityIdentifier("voice-model-failure")
            downloadButton("Retry download")
        case .installed:
            Text("Installed").accessibilityIdentifier("voice-model-installed")
            if controller.conversationReady {
                Button("Start voice") { Task { await controller.activate() } }
                    .disabled(controller.isPreparing || controller.isRunning)
                    .accessibilityIdentifier("voice-model-start")
            } else {
                Text("Voice is not ready in this conversation yet.").foregroundStyle(.secondary)
            }
        }
    }

    private func downloadButton(_ title: String) -> some View {
        Button(title) { Task { await controller.confirmDownload() } }
            .accessibilityIdentifier("voice-model-download")
    }
}
