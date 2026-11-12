// Builds host-owned consent displays from strict canonical action or roster signing inputs.
// MeshHostSigner accepts only factory-bound prompts whose entire signing input still matches.

import AstralKernel
import CryptoKit
import Foundation

nonisolated enum ConsentPromptError: Error {
    case invalidInput
}

nonisolated struct ConsentPrompt: Equatable, Sendable {
    let actionTitle: String
    let effect: String
    let target: String
    let arguments: String
    let untrustedSource: String?
    let labels: [String]
    let digest: String
    let requiresBiometry: Bool
    private var signingInputHash: Data?

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
        signingInputHash = nil
    }

    static func action(canonicalAction: Data, canonicalArguments: Data, signingInput: Data) throws -> ConsentPrompt {
        _ = try object(
            canonicalAction,
            fields: [
                "v", "mesh", "device", "turn", "agent", "tool", "tool_def", "args_digest", "influence",
            ])
        let action = try JSONDecoder().decode(Action.self, from: canonicalAction)
        let consentData = try payload(signingInput, context: "astral.consent/v1")
        let consentObject = try object(consentData, fields: ["v", "kind", "digest", "device", "clock"])
        let consent = try JSONDecoder().decode(ActionConsent.self, from: consentData)
        guard try KernelCanonicalJSON.canonicalize(canonicalArguments) == canonicalArguments else {
            throw ConsentPromptError.invalidInput
        }
        try checkClock(consentObject["clock"], value: consent.clock)
        guard action.v == 1, consent.v == 1, consent.kind == "action",
            isID(action.mesh), isID(action.device), isID(action.turn), isID(action.toolDef),
            !action.agent.isEmpty, !action.tool.isEmpty,
            action.influence == Array(Set(action.influence)).sorted(), action.influence.allSatisfy(isID),
            action.argsDigest == hashID(canonicalArguments), consent.digest == hashID(canonicalAction),
            consent.device == action.device
        else { throw ConsentPromptError.invalidInput }
        var prompt = ConsentPrompt(
            actionTitle: "Approve " + action.tool, effect: action.tool,
            target: action.mesh + " / " + action.agent,
            arguments: "Action: " + String(decoding: canonicalAction, as: UTF8.self)
                + "\nArguments: " + String(decoding: canonicalArguments, as: UTF8.self),
            untrustedSource: action.influence.isEmpty ? nil : action.influence.joined(separator: ", "),
            digest: consent.digest)
        prompt.signingInputHash = hash(signingInput)
        return prompt
    }

    static func roster(signingInput: Data) throws -> ConsentPrompt {
        let data = try payload(signingInput, context: "astral.roster/v1")
        let entry = try object(data, fields: ["v", "type", "mesh", "author", "follows", "clock", "body"])
        let header = try JSONDecoder().decode(RosterHeader.self, from: data)
        try checkClock(entry["clock"], value: header.clock)
        guard header.v == 1, isID(header.mesh), isID(header.author), !header.follows.isEmpty,
            header.follows == Array(Set(header.follows)).sorted(), header.follows.allSatisfy(isID),
            let body = entry["body"] as? [String: Any]
        else { throw ConsentPromptError.invalidInput }
        let target: String
        switch header.type {
        case "add":
            guard Set(body.keys) == ["device", "attestation"],
                body["attestation"] is NSNull || body["attestation"] is [String: Any],
                let record = body["device"] as? [String: Any],
                Set(record.keys) == ["identity", "presence", "ops", "wrap", "kind", "label", "cert"],
                let kind = record["kind"] as? String, ["desktop", "pocket", "satellite", "node"].contains(kind),
                let label = record["label"] as? String, (1...64).contains(label.unicodeScalars.count)
            else { throw ConsentPromptError.invalidInput }
            let identity = try keyBytes(record["identity"], count: 65)
            let presence = try keyBytes(record["presence"], count: 65)
            guard identity.first == 4, presence.first == 4 else { throw ConsentPromptError.invalidInput }
            _ = try keyBytes(record["ops"], count: 32)
            _ = try keyBytes(record["wrap"], count: 32)
            _ = try keyBytes(record["cert"], count: 64)
            target = label + " (" + hashID(identity) + ")"
        case "remove":
            guard Set(body.keys) == ["device", "cutoff"] else { throw ConsentPromptError.invalidInput }
            let removal = try JSONDecoder().decode(Removal.self, from: data)
            guard isID(removal.body.device), removal.body.cutoff.values.allSatisfy({ $0 >= 0 }) else {
                throw ConsentPromptError.invalidInput
            }
            for feed in removal.body.cutoff.keys { _ = try keyBytes(feed, count: 32) }
            target = removal.body.device
        default:
            throw ConsentPromptError.invalidInput
        }
        var prompt = ConsentPrompt(
            actionTitle: header.type == "add" ? "Add device" : "Remove device",
            effect: "roster." + header.type, target: target,
            arguments: String(decoding: data, as: UTF8.self), digest: hashID(data), requiresBiometry: true)
        prompt.signingInputHash = hash(signingInput)
        return prompt
    }

    var digestHex: String {
        digest.hasPrefix("sha256:") ? String(digest.dropFirst("sha256:".count)) : digest
    }

    var shortDigest: String { String(digestHex.prefix(12)) }

    func isBound(to message: Data) -> Bool {
        guard let signingInputHash else { return false }
        return signingInputHash == Self.hash(message)
    }

    private static func payload(_ input: Data, context: String) throws -> Data {
        let prefix = Data((context + "\n").utf8)
        guard input.starts(with: prefix) else { throw ConsentPromptError.invalidInput }
        return Data(input.dropFirst(prefix.count))
    }

    private static func object(_ data: Data, fields: Set<String>? = nil) throws -> [String: Any] {
        guard try KernelCanonicalJSON.canonicalize(data) == data,
            let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            fields == nil || Set(value.keys) == fields
        else { throw ConsentPromptError.invalidInput }
        return value
    }

    private static func checkClock(_ object: Any?, value: Clock) throws {
        guard let clock = object as? [String: Any], Set(clock.keys) == ["ms", "n"], value.ms >= 0, value.n >= 0 else {
            throw ConsentPromptError.invalidInput
        }
    }

    private static func keyBytes(_ value: Any?, count: Int) throws -> Data {
        guard let text = value as? String else { throw ConsentPromptError.invalidInput }
        let padded =
            text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let bytes = Data(base64Encoded: padded), bytes.count == count,
            bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") == text
        else { throw ConsentPromptError.invalidInput }
        return bytes
    }

    private static func isID(_ text: String) -> Bool {
        text.hasPrefix("sha256:") && text.utf8.count == 71
            && text.utf8.dropFirst(7).allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func hash(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    private static func hashID(_ data: Data) -> String {
        "sha256:" + hash(data).map { String(format: "%02x", $0) }.joined()
    }
}

private nonisolated struct Action: Decodable {
    let v: Int64
    let mesh, device, turn, agent, tool, toolDef, argsDigest: String
    let influence: [String]

    enum CodingKeys: String, CodingKey {
        case v, mesh, device, turn, agent, tool, influence
        case toolDef = "tool_def"
        case argsDigest = "args_digest"
    }
}

private nonisolated struct Clock: Decodable {
    let ms, n: Int64
}

private nonisolated struct ActionConsent: Decodable {
    let v: Int64
    let kind, digest, device: String
    let clock: Clock
}

private nonisolated struct RosterHeader: Decodable {
    let v: Int64
    let type, mesh, author: String
    let follows: [String]
    let clock: Clock
}

private nonisolated struct Removal: Decodable {
    struct Body: Decodable {
        let device: String
        let cutoff: [String: Int64]
    }
    let body: Body
}
