// Presents the local voice model's size, consent, progress, failures and removal controls.
// The chat microphone opens this sheet and all downloads go through VoiceModelStore.

import SwiftUI

struct VoiceModelSetupView: View {
    @Bindable var controller: OnDeviceVoiceController
    let onStart: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false

    var body: some View {
        NavigationStack {
            Form {
                if let store = controller.store {
                    if case .unsupported(let reason) = store.state {
                        Section {
                            Label(reason.message, systemImage: "exclamationmark.circle")
                                .accessibilityIdentifier("voice-model-unsupported")
                        }
                    } else {
                        Section {
                            VStack(spacing: 10) {
                                Image(systemName: "waveform.circle.fill").font(.system(size: 48))
                                    .foregroundStyle(.tint).accessibilityHidden(true)
                                Text("Talk to your assistant").font(.title3.weight(.semibold))
                                Text(
                                    "The voice model runs on this device, so speech stays here. Download it once, \(store.manifest.sizeDescription), to speak and listen."
                                )
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .accessibilityElement(children: .combine)
                        }
                        Section {
                            LabeledContent("Model", value: store.manifest.displayName)
                            LabeledContent("Size", value: store.manifest.sizeDescription)
                            modelState(store)
                        }
                        if let message = controller.message,
                            !(store.state == .installed && !controller.conversationReady)
                        {
                            Section { Text(message).accessibilityIdentifier("voice-model-message") }
                        }
                        if store.state == .installed {
                            Section {
                                Button("Remove Voice Model", role: .destructive) { confirmingDelete = true }
                                    .accessibilityIdentifier("voice-model-delete")
                            }
                        }
                        Section {
                            Text(store.manifest.license).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section { Text(VoiceModelFailure.manifestUnavailable.message) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Voice")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .frame(minWidth: 380, minHeight: 440)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice-model-setup")
        .alert("Download on this connection?", isPresented: $controller.showingMeteredConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Download") { Task { await controller.confirmDownload(allowMetered: true) } }
        } message: {
            Text("This downloads \(controller.downloadSize ?? "the voice model") using your current connection.")
        }
        .confirmationDialog("Delete the voice model?", isPresented: $confirmingDelete) {
            Button("Remove Voice Model", role: .destructive) { Task { await controller.deleteModel() } }
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
            downloadButton("Download \(store.manifest.sizeDescription)", prominent: true)
        case .downloading(let progress):
            ProgressView(value: progress.fraction) {
                Text(progress.verifying ? "Verifying download…" : "Downloading voice model…")
            }
            .accessibilityIdentifier("voice-model-progress")
            Button("Cancel download", role: .cancel) { Task { await controller.cancelDownload() } }
                .accessibilityIdentifier("voice-model-cancel")
        case .failed(let failure):
            Text(failure.message).accessibilityIdentifier("voice-model-failure")
            downloadButton("Retry Download", prominent: true)
        case .installed:
            Text("Installed").accessibilityIdentifier("voice-model-installed")
            if controller.conversationReady {
                Button("Start Voice", action: onStart)
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.isPreparing || controller.isRunning)
                    .accessibilityIdentifier("voice-model-start")
            } else {
                Text("Voice is not ready in this conversation yet.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func downloadButton(_ title: String, prominent: Bool) -> some View {
        let button = Button(title) { Task { await controller.confirmDownload() } }
        if prominent {
            button.buttonStyle(.borderedProminent).accessibilityIdentifier("voice-model-download")
        } else {
            button.accessibilityIdentifier("voice-model-download")
        }
    }
}
