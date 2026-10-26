// Small workbench chip that appears while an update waits for the app to go idle or after an update check failed.
// Choosing it opens the Updates sheet owned by UpdateCoordinator; the workbench decides where the chip sits.

#if os(macOS)
    import SwiftUI

    struct UpdateStatusChip: View {
        @ObservedObject var coordinator: UpdateCoordinator
        @Environment(ThemeStore.self) private var theme

        static func title(for status: UpdateStatus) -> String {
            switch status {
            case .restartPending: return "Update ready, restart when idle"
            case .failed: return "Update check failed"
            }
        }

        static func symbol(for status: UpdateStatus) -> String {
            switch status {
            case .restartPending: return "arrow.triangle.2.circlepath"
            case .failed: return "exclamationmark.triangle"
            }
        }

        var body: some View {
            if let status = coordinator.status {
                let tint = status == .restartPending ? theme.palette.primary : theme.palette.warning
                Button {
                    coordinator.settingsPresented = true
                } label: {
                    Label(Self.title(for: status), systemImage: Self.symbol(for: status))
                        .font(.caption)
                        .foregroundStyle(theme.palette.text)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(tint.opacity(0.18)))
                        .overlay(Capsule().strokeBorder(tint.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .help(detail(for: status))
                .accessibilityLabel(Self.title(for: status))
                .accessibilityHint(detail(for: status))
            }
        }

        private func detail(for status: UpdateStatus) -> String {
            switch status {
            case .restartPending: return "Astral restarts to finish updating when the current task ends."
            case .failed(let reason): return reason
            }
        }
    }
#endif
