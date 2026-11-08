// Gives macOS a small menu bar control surface for the shared app model and its server-owned Work entry.
// Local computer controls retain the same host authorization and physical resume checks as the main window.

#if os(macOS)
    import AstralCore
    import AppKit
    import SwiftUI

    /// `openWindow(id:)` on a `WindowGroup` always adds a window, so reuse the one already open.
    enum MacMainWindow {
        static func reusable(in windows: [NSWindow]) -> NSWindow? {
            windows.first {
                $0.title == "AstralDeep" && $0.styleMask.contains(.titled) && ($0.isVisible || $0.isMiniaturized)
            }
        }

        @MainActor static func show(using openWindow: OpenWindowAction) {
            if let window = reusable(in: NSApp.windows) {
                window.makeKeyAndOrderFront(nil)
            } else {
                openWindow(id: "main")
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    struct MacMenuBarPresentation {
        let signedIn: Bool
        let connected: Bool
        let navigationLocked: Bool
        let updateRequired: Bool
        let turnActive: Bool
        let waitingApprovals: Int
        let workAvailable: Bool
        let computerAvailable: Bool
        let computerTaskActive: Bool
        let computerPaused: Bool
        let computerCanResume: Bool

        var status: String {
            if updateRequired { return "Update required" }
            if !signedIn { return "Sign in required" }
            if !connected { return "Disconnected" }
            if computerTaskActive { return computerPaused ? "Computer task paused" : "Computer task active" }
            return turnActive ? "Working" : "Ready"
        }

        var canStartChat: Bool { signedIn && connected && !navigationLocked && !updateRequired }
        var canOpenWork: Bool { canStartChat && workAvailable }
        var canOpenSchedule: Bool { signedIn && connected && !updateRequired }
        var canOpenComputerControls: Bool { computerAvailable }
        var canPauseComputer: Bool { computerAvailable && computerTaskActive && !computerPaused }
        var canReviewResume: Bool { signedIn && connected && !updateRequired && computerCanResume }
        var canStopComputer: Bool { computerAvailable && computerTaskActive }
    }

    struct MacMenuBarContent: View {
        let model: AppModel
        let updateRequired: Bool
        @Environment(\.openWindow) private var openWindow
        @Environment(\.openSettings) private var openSettings

        private var workAction: SurfaceRef? {
            WorkReadRequest.watchControls(in: model.chromeMenu).first?.action
        }

        private var presentation: MacMenuBarPresentation {
            let host = model.macComputerHost
            return MacMenuBarPresentation(
                signedIn: model.signedIn, connected: model.connected,
                navigationLocked: model.mandatorySurface || model.mutationsLocked,
                updateRequired: updateRequired, turnActive: model.turnActive,
                waitingApprovals: model.waitingApprovals, workAvailable: workAction != nil,
                computerAvailable: host.available, computerTaskActive: host.taskActive,
                computerPaused: host.session?.state == "paused", computerCanResume: host.canResume)
        }

        var body: some View {
            let state = presentation
            Text(state.status)
                .accessibilityIdentifier("mac-menu-status")
            if state.waitingApprovals > 0 {
                Text(state.waitingApprovals == 1 ? "1 approval waiting" : "\(state.waitingApprovals) approvals waiting")
                    .accessibilityIdentifier("mac-menu-approvals")
            }
            Divider()
            Button("Open AstralDeep") { showMainWindow() }
                .accessibilityIdentifier("mac-menu-open")
            Button("Quick Entry…") {
                openWindow(id: "quick-entry")
                NSApp.activate(ignoringOtherApps: true)
            }
            .accessibilityIdentifier("mac-menu-quick-entry")
            Button("New chat") {
                guard presentation.canStartChat else { return }
                model.newChat()
                showMainWindow()
            }
            .disabled(!state.canStartChat)
            .accessibilityIdentifier("mac-menu-new-chat")
            Button("Recent work") {
                guard presentation.canOpenWork, let workAction else { return }
                showMainWindow()
                model.openSurface(workAction.surface, params: workAction.params)
            }
            .disabled(!state.canOpenWork)
            .accessibilityIdentifier("mac-menu-work")
            Button("Scheduled work…") {
                guard presentation.canOpenSchedule else { return }
                openWindow(id: "scheduled-work")
                NSApp.activate(ignoringOtherApps: true)
            }
            .disabled(!state.canOpenSchedule)
            .accessibilityIdentifier("mac-menu-scheduled-work")
            if state.computerAvailable {
                Divider()
                Text(model.macComputerHost.statusLabel)
                    .accessibilityIdentifier("mac-menu-computer-status")
                Button("Computer controls…") {
                    guard presentation.canOpenComputerControls else { return }
                    showMainWindow()
                    model.macComputerHost.showControls()
                }
                .disabled(!state.canOpenComputerControls)
                .accessibilityIdentifier("mac-menu-computer-controls")
                if state.computerTaskActive {
                    Button("Pause computer task") {
                        guard presentation.canPauseComputer else { return }
                        model.macComputerHost.pause()
                    }
                    .disabled(!state.canPauseComputer)
                    .accessibilityIdentifier("mac-menu-computer-pause")
                    Button("Stop computer task") {
                        guard presentation.canStopComputer else { return }
                        model.stopComputerTask()
                    }
                    .disabled(!state.canStopComputer)
                    .accessibilityIdentifier("mac-menu-computer-stop")
                }
                if state.computerPaused {
                    Button("Review and resume…") {
                        guard presentation.canReviewResume else { return }
                        showMainWindow()
                        model.macComputerHost.showControls()
                    }
                    .disabled(!state.canReviewResume)
                    .accessibilityIdentifier("mac-menu-computer-resume")
                }
            }
            Divider()
            Button("Settings…") { openSettings() }
                .accessibilityIdentifier("mac-menu-settings")
        }

        private func showMainWindow() { MacMainWindow.show(using: openWindow) }
    }
#endif
