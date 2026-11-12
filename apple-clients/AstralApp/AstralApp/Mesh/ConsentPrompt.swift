// The fields of one consent request, built by the host from the canonical action and never from model text.
// ConsentSheet draws only these fields, ConsentCoordinator queues them, and MeshHostSigner checks the digest against the signed message.

import Foundation

nonisolated struct ConsentPrompt: Equatable, Sendable {
    let actionTitle: String
    let effect: String
    let target: String
    let arguments: String
    let untrustedSource: String?
    let labels: [String]
    let digest: String
    let requiresBiometry: Bool

    init(
        actionTitle: String, effect: String, target: String, arguments: String,
        untrustedSource: String? = nil, labels: [String] = [], digest: String,
        requiresBiometry: Bool = false
    ) {
        self.actionTitle = actionTitle
        self.effect = effect
        self.target = target
        self.arguments = arguments
        self.untrustedSource = untrustedSource
        self.labels = labels
        self.digest = digest
        self.requiresBiometry = requiresBiometry
    }

    var digestHex: String {
        digest.hasPrefix("sha256:") ? String(digest.dropFirst("sha256:".count)) : digest
    }

    var shortDigest: String {
        String(digestHex.prefix(12))
    }

    func isBound(to message: Data) -> Bool {
        guard !digestHex.isEmpty else { return false }
        return message.range(of: Data(digestHex.utf8)) != nil
    }
}
