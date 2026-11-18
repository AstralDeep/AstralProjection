// Keeps the shares this device ended so the Shares list still shows them as Revoked after a relaunch.
// MeshRuntime reads it when it starts and writes it when the owner revokes a share, in the mesh data directory.

import Foundation

nonisolated struct MeshEndedShareStore: Sendable {
    let file: URL

    init(directory: URL) {
        file = directory.appendingPathComponent("ended-shares.json", isDirectory: false)
    }

    func load() -> [String: MeshShareInfo] {
        guard let data = try? Data(contentsOf: file),
            let rows = try? JSONDecoder().decode([Row].self, from: data)
        else { return [:] }
        return Dictionary(rows.map { ($0.id, $0.info) }, uniquingKeysWith: { _, latest in latest })
    }

    func save(_ shares: [String: MeshShareInfo]) {
        let rows = shares.values.sorted { $0.id < $1.id }.map(Row.init)
        guard let data = try? JSONEncoder().encode(rows) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private struct Row: Codable {
        let id: String
        let chat: String
        let title: String
        let contact: String
        let contactName: String
        let phi: Bool
        let phiWithheld: Bool

        init(_ info: MeshShareInfo) {
            id = info.id
            chat = info.chat
            title = info.title
            contact = info.contact
            contactName = info.contactName
            phi = info.phi
            phiWithheld = info.phiWithheld
        }

        var info: MeshShareInfo {
            MeshShareInfo(
                id: id, chat: chat, title: title, contact: contact, contactName: contactName, phi: phi,
                phiWithheld: phiWithheld, state: .revoked)
        }
    }
}
