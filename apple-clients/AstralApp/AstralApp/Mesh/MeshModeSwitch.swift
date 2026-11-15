// Exposes the personal mesh from a signed-in server's native account controls without retiring that server session.
// Mode changes wait until approvals, turns, voice and local computer work are idle.

import SwiftUI

extension AppModeStore {
    func canEnterPersonalMesh(from model: AppModel) -> Bool {
        guard !usesMesh, !model.mandatorySurface, !model.turnActive, model.waitingApprovals == 0,
            !model.onDeviceVoice.isRunning, !model.onDeviceVoice.isPreparing
        else { return false }
        #if os(macOS)
            guard model.macComputerHost.session == nil else { return false }
        #endif
        return true
    }

    @discardableResult
    func enterPersonalMesh(from model: AppModel) -> Bool {
        guard canEnterPersonalMesh(from: model) else { return false }
        choose(.mesh)
        return true
    }
}

struct PersonalMeshModeButton: View {
    @Environment(AppModeStore.self) private var mode: AppModeStore?
    @Environment(AppModel.self) private var model
    var padded = false

    var body: some View {
        if let mode, !mode.usesMesh {
            Button("Use a personal mesh instead") { mode.enterPersonalMesh(from: model) }
                .buttonStyle(.plain)
                .foregroundStyle(model.themeStore.palette.accent)
                .disabled(!mode.canEnterPersonalMesh(from: model))
                .accessibilityIdentifier("settings.personal-mesh")
                .padding(padded ? 12 : 0)
        }
    }
}
