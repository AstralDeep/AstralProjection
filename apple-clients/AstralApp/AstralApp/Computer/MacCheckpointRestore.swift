// Presents the owner-facing Restore files flow for turn checkpoints: pick a checkpoint per granted root, review
// exactly which files would be overwritten, and run the restore through the host's grant and identity checks.

#if os(macOS)
    import AstralCore
    import SwiftUI

    struct MacCheckpointFilesSection: View {
        @Bindable var host: MacComputerHost
        @Environment(ThemeStore.self) private var theme: ThemeStore?
        @State private var pending: MacCheckpointRestorePreview?
        private var palette: AstralPalette { theme?.palette ?? .graphite }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                SettingsSectionTitle("Restore files")
                Text(
                    "Before the first change in each turn, AstralDeep keeps a private snapshot of every granted "
                        + "folder on this Mac. Restoring overwrites the captured files with their earlier contents."
                )
                .font(ConsoleTypography.caption).foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                ForEach(host.files.roots, id: \.self) { root in
                    MacCheckpointRootRow(host: host, root: root, preview: $pending)
                }
            }
            .sheet(item: $pending) { preview in
                MacCheckpointRestoreSheet(host: host, preview: preview).environment(theme)
            }
        }
    }

    private struct MacCheckpointRootRow: View {
        @Bindable var host: MacComputerHost
        let root: String
        @Binding var preview: MacCheckpointRestorePreview?
        @State private var summaries: [MacCheckpointSummary] = []
        @Environment(ThemeStore.self) private var theme: ThemeStore?
        private var palette: AstralPalette { theme?.palette ?? .graphite }

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text((root as NSString).lastPathComponent).textSelection(.enabled)
                if let latest = summaries.first {
                    HStack {
                        Text(label(latest)).font(ConsoleTypography.caption).foregroundStyle(palette.muted)
                        Spacer()
                        Button("Restore…") {
                            preview = host.checkpointRestorePreview(checkpointId: latest.id)
                        }
                        .disabled(!host.available)
                        .accessibilityIdentifier("mac-checkpoint-restore")
                    }
                } else {
                    Text("No checkpoint yet for this folder.")
                        .font(ConsoleTypography.caption).foregroundStyle(palette.muted)
                }
            }
            .onAppear { reload() }
            .onChange(of: pending) { _, value in
                if value == nil { reload() }
            }
        }

        private func reload() {
            summaries = host.checkpointSummaries(root: root)
        }

        private func label(_ summary: MacCheckpointSummary) -> String {
            let scope = summary.currentTurn ? "This turn" : Self.timestamp(summary.createdAt)
            return "\(scope) · \(summary.fileCount) file\(summary.fileCount == 1 ? "" : "s") checkpointed"
        }

        private static func timestamp(_ interval: Double) -> String {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return formatter.string(from: Date(timeIntervalSince1970: interval))
        }
    }

    struct MacCheckpointRestoreSheet: View {
        @Bindable var host: MacComputerHost
        let preview: MacCheckpointRestorePreview
        @Environment(\.dismiss) private var dismiss
        @Environment(ThemeStore.self) private var theme: ThemeStore?
        @State private var result: String?
        @State private var working = false
        private var palette: AstralPalette { theme?.palette ?? .graphite }

        var body: some View {
            SettingsSheetChrome(
                "Restore files from \(preview.summary.currentTurn ? "this turn" : "the checkpoint")?",
                identifier: "mac-checkpoint-restore", close: { dismiss() }, done: nil
            ) {
                if let result {
                    Text(result).accessibilityIdentifier("mac-checkpoint-restore-result")
                } else {
                    Text(
                        "Restoring overwrites these \(preview.changes.count) file\(preview.changes.count == 1 ? "" : "s") "
                            + "in \(preview.summary.rootPath) with their checkpointed contents. Files created after "
                            + "the checkpoint stay."
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mac-checkpoint-restore-summary")
                    if preview.changes.isEmpty {
                        Text("Nothing differs from the checkpoint right now.")
                            .accessibilityIdentifier("mac-checkpoint-restore-empty")
                    }
                    ForEach(preview.changes, id: \.path) { change in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: change.state == "missing" ? "arrow.uturn.down" : "arrow.uturn.left")
                                .imageScale(.small).foregroundStyle(palette.warning)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(change.path).font(ConsoleTypography.caption).textSelection(.enabled)
                                Text(detail(change)).font(ConsoleTypography.caption2).foregroundStyle(palette.muted)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Restore \(change.path), \(detail(change))")
                        .accessibilityIdentifier("mac-checkpoint-change")
                    }
                    if !preview.extras.isEmpty {
                        Text(
                            "\(preview.extras.count) file\(preview.extras.count == 1 ? "" : "s") created after the "
                                + "checkpoint stay: \(preview.extras.prefix(3).joined(separator: ", "))")
                            .font(ConsoleTypography.caption).foregroundStyle(palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("mac-checkpoint-extras")
                    }
                }
            } footer: {
                if result == nil {
                    Button("Cancel", action: { dismiss() }).accessibilityIdentifier("mac-checkpoint-cancel")
                    Button("Restore files") {
                        working = true
                        host.stop()
                        Task {
                            result = await host.restoreCheckpointFiles(preview.summary.id)
                            working = false
                        }
                    }
                    .buttonStyle(SettingsButtonStyle(palette: palette, danger: true))
                    .disabled(working)
                    .accessibilityIdentifier("mac-checkpoint-confirm")
                }
            }
            .frame(minWidth: 480, idealWidth: 560, minHeight: 360, idealHeight: 480)
        }

        private func detail(_ change: ComputerCheckpointChange) -> String {
            switch change.state {
            case "missing": return "deleted since the checkpoint; it will be recreated"
            case "changed":
                if let added = change.addedLines, let removed = change.removedLines {
                    return "will be overwritten (+\(added) −\(removed) lines)"
                }
                return "will be overwritten with the checkpointed contents"
            default: return "will be overwritten"
            }
        }
    }

#endif
