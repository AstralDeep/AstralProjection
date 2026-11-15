// The recovery path of onboarding: the 24 recovery words with an optional backup file from the system file picker, and the screen that shows the restored mesh and this device.
// The words live only in this view's state, go to the kernel once through MeshRuntime and are cleared as soon as the attempt succeeds or the view goes away.

import SwiftUI
import UniformTypeIdentifiers

struct MeshRestoreView: View {
    let onCancel: () -> Void
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    @State private var words = ""
    @State private var backup: URL?
    @State private var choosingFile = false
    @State private var fileProblem: String?
    private var p: AstralPalette { theme.palette }

    private var wordCount: Int { MeshRecoveryWords.normalize(words).count }
    private var recovering: Bool { mesh.restore == .recovering }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recover my mesh").font(ConsoleTypography.title2).accessibilityAddTraits(.isHeader)
            Text("Enter your 24 recovery words in order. Add a backup file if this device holds no copy of your mesh.")
                .font(ConsoleTypography.footnote).foregroundStyle(p.muted)
            TextField("Recovery words", text: $words, axis: .vertical)
                .lineLimit(4...8)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .privacySensitive()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.asciiCapable)
                #endif
                .disabled(recovering)
                .accessibilityIdentifier("mesh.restore.words")
            HStack {
                Text("\(wordCount) of 24 words")
                    .font(ConsoleTypography.caption)
                    .foregroundStyle(wordCount == MeshRecoveryWords.count ? p.success : p.muted)
                    .accessibilityIdentifier("mesh.restore.count")
                Spacer()
                Button("Paste") { words = MeshPasteboardReader.string() }
                    .disabled(recovering)
                    .accessibilityIdentifier("mesh.restore.paste")
            }
            backupRow
            if case .failed(let message) = mesh.restore {
                Text(message).font(ConsoleTypography.footnote).foregroundStyle(p.error)
                    .accessibilityIdentifier("mesh.restore.error")
            } else if let fileProblem {
                Text(fileProblem).font(ConsoleTypography.footnote).foregroundStyle(p.error)
                    .accessibilityIdentifier("mesh.restore.error")
            }
            if recovering {
                ProgressView("Recovering your mesh").accessibilityIdentifier("mesh.restore.progress")
            }
            Button {
                Task { await recover() }
            } label: {
                Text("Recover").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(wordCount != MeshRecoveryWords.count || recovering)
            .accessibilityIdentifier("mesh.restore.submit")
            Button("Cancel") {
                words = ""
                mesh.dismissRestoreFailure()
                onCancel()
            }
            .disabled(recovering)
            .accessibilityIdentifier("mesh.restore.cancel")
        }
        .onDisappear { words = "" }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url):
                backup = url
                fileProblem = nil
            case .failure:
                fileProblem = "That file could not be opened."
            }
        }
    }

    @ViewBuilder
    private var backupRow: some View {
        if let backup {
            HStack {
                Label(backup.lastPathComponent, systemImage: "doc.fill").lineLimit(1)
                    .accessibilityIdentifier("mesh.restore.file")
                Spacer()
                Button("Remove") { self.backup = nil }
                    .disabled(recovering)
                    .accessibilityIdentifier("mesh.restore.file.remove")
            }
        } else {
            Button {
                choosingFile = true
            } label: {
                Label("Choose a backup file", systemImage: "doc.badge.plus")
            }
            .disabled(recovering)
            .accessibilityIdentifier("mesh.restore.file.choose")
        }
    }

    private func recover() async {
        fileProblem = nil
        await mesh.recoverMesh(words: words, backup: backup)
        if case .restored = mesh.restore { words = "" }
    }
}

struct MeshRestoredView: View {
    let restored: MeshRestoredMesh
    @Environment(MeshRuntime.self) private var mesh
    @Environment(ThemeStore.self) private var theme
    private var p: AstralPalette { theme.palette }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("Your mesh is back", systemImage: "checkmark.circle.fill")
                    .font(ConsoleTypography.title2)
                    .foregroundStyle(p.success)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("mesh.restored.title")
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Mesh") {
                        Text(restored.meshId.suffix(12)).font(.system(.footnote, design: .monospaced))
                    }
                    .accessibilityIdentifier("mesh.restored.mesh")
                    LabeledContent("This device", value: restored.deviceLabel)
                        .accessibilityIdentifier("mesh.restored.device")
                    LabeledContent("Device key") {
                        Text(restored.deviceId.suffix(12)).font(.system(.footnote, design: .monospaced))
                    }
                    LabeledContent("Devices in the mesh", value: "\(restored.memberCount)")
                        .accessibilityIdentifier("mesh.restored.members")
                    if restored.eventsImported > 0 {
                        LabeledContent("Restored from the backup", value: "\(restored.eventsImported) items")
                            .accessibilityIdentifier("mesh.restored.imported")
                    }
                }
                Text("This device has its own new keys. Your other devices will see it as a new member.")
                    .font(ConsoleTypography.footnote).foregroundStyle(p.muted)
                Button {
                    mesh.finishRestore()
                } label: {
                    Text("Continue").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("mesh.restored.continue")
            }
            .frame(maxWidth: 520)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(p.bg)
    }
}
