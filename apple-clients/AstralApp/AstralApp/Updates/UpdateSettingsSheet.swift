// Native update controls for the Mac app: the Updates sheet, the app-menu items and the update-required screen.
// All three read UpdateCoordinator, which owns the Sparkle updater and the signed minimum-build outcome.

#if os(macOS)
    import SwiftUI

    struct UpdateMenuItems: View {
        @ObservedObject var coordinator: UpdateCoordinator

        var body: some View {
            if coordinator.isEnabled {
                Button("Check for Updates…") { coordinator.checkForUpdates() }
                    .disabled(!coordinator.canCheckForUpdates)
                Button("Updates…") { coordinator.settingsPresented = true }
            }
        }
    }

    struct UpdateSettingsSheet: View {
        @ObservedObject var coordinator: UpdateCoordinator
        @Environment(ThemeStore.self) private var themeStore: ThemeStore?
        @Environment(\.dismiss) private var dismiss

        static func lastCheckText(_ date: Date?) -> String {
            date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never"
        }

        private var palette: AstralPalette { themeStore?.palette ?? .graphite }

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                Text("Updates").font(.headline)
                Toggle(
                    "Check automatically",
                    isOn: Binding(get: { coordinator.automaticChecks }, set: { coordinator.setAutomaticChecks($0) }))
                Toggle(
                    "Install automatically",
                    isOn: Binding(get: { coordinator.automaticInstall }, set: { coordinator.setAutomaticInstall($0) })
                )
                .disabled(!coordinator.automaticInstallAvailable)
                Toggle(
                    "Include preview releases",
                    isOn: Binding(get: { coordinator.previewChannel }, set: { coordinator.setPreviewChannel($0) }))
                Divider()
                LabeledContent("Version", value: UpdateCoordinator.installedVersion())
                LabeledContent("Last checked", value: Self.lastCheckText(coordinator.lastCheck))
                if let status = coordinator.status {
                    Label(UpdateStatusChip.title(for: status), systemImage: UpdateStatusChip.symbol(for: status))
                        .foregroundStyle(palette.warning)
                    if case .failed(let reason) = status {
                        Text(reason).font(.caption).foregroundStyle(palette.muted)
                    }
                }
                HStack {
                    Button("Check now") { coordinator.checkForUpdates() }
                        .disabled(!coordinator.isEnabled || !coordinator.canCheckForUpdates)
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 380)
        }
    }

    struct UpdateRequiredView: View {
        let requirement: UpdateRequirement
        @ObservedObject var coordinator: UpdateCoordinator
        @Environment(ThemeStore.self) private var themeStore: ThemeStore?

        private var palette: AstralPalette { themeStore?.palette ?? .graphite }

        var body: some View {
            VStack(spacing: 14) {
                Image(systemName: "arrow.down.circle").font(.system(size: 40)).foregroundStyle(palette.primary)
                Text(requirement.message).font(.title3.weight(.semibold)).foregroundStyle(palette.text)
                Text("\(UpdateCoordinator.installedVersion()), build \(requirement.minimumBuild) or later required")
                    .font(.callout).foregroundStyle(palette.muted)
                Button("Check for Updates") { coordinator.checkForUpdates() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!coordinator.isEnabled || !coordinator.canCheckForUpdates)
                if let reason = coordinator.lastError {
                    Text(reason).font(.caption).foregroundStyle(palette.warning)
                }
            }
            .multilineTextAlignment(.center)
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.bg)
            .accessibilityElement(children: .contain)
        }
    }
#endif
