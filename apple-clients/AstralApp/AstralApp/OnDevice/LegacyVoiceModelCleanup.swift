// Deletes the retired voice model's weights, staging files and install markers from Application Support, once, on the first launch of this version.
// AstralApp starts it at launch; it removes only the old model folder, never touches the voice pack folder beside it and never follows a symbolic link out of the folder.

import Foundation

nonisolated enum LegacyVoiceModelCleanup {
    static let completedKey = "astral.voice.legacy-model-removed"

    static func legacyRoot(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("AstralDeep", isDirectory: true)
            .appendingPathComponent("VoiceModel", isDirectory: true)
    }

    @discardableResult
    static func runOnce(root: URL = legacyRoot(), defaults: UserDefaults = .standard) -> Task<Void, Never>? {
        guard !defaults.bool(forKey: completedKey) else { return nil }
        return Task.detached(priority: .utility) {
            if remove(root) { defaults.set(true, forKey: completedKey) }
        }
    }

    static func remove(_ root: URL, fileManager: FileManager = .default) -> Bool {
        guard (try? fileManager.attributesOfItem(atPath: root.path)) != nil else { return true }
        do {
            try fileManager.removeItem(at: root)
            return true
        } catch {
            return false
        }
    }
}
