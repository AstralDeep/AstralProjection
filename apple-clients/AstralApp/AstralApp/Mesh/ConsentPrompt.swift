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
    private(set) var summary: String?
    private var signingInputHash: Data?

    init(
        actionTitle: String, effect: String, target: String, arguments: String,
        untrustedSource: String? = nil, labels: [String] = [], digest: String,
        requiresBiometry: Bool = false, summary: String? = nil
    ) {
        self.actionTitle = actionTitle
        self.effect = effect
        self.target = target
        self.arguments = arguments
        self.untrustedSource = untrustedSource
        self.labels = labels
        self.digest = digest
        self.requiresBiometry = requiresBiometry
        self.summary = summary
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

    static func takeover(canonicalAction: Data, signingInput: Data) throws -> ConsentPrompt {
        _ = try object(canonicalAction, fields: ["executor", "kind", "run", "supersedes", "v"])
        let action = try JSONDecoder().decode(Takeover.self, from: canonicalAction)
        let consentData = try payload(signingInput, context: "astral.consent/v1")
        let consentObject = try object(consentData, fields: ["v", "kind", "digest", "device", "clock"])
        let consent = try JSONDecoder().decode(ActionConsent.self, from: consentData)
        try checkClock(consentObject["clock"], value: consent.clock)
        guard action.v == 1, action.kind == "run.takeover", consent.v == 1, consent.kind == "action",
            isID(action.executor), isID(consent.device), consent.device == action.executor,
            !action.run.isEmpty, action.supersedes == Array(Set(action.supersedes)).sorted(),
            consent.digest == hashID(canonicalAction)
        else { throw ConsentPromptError.invalidInput }
        var prompt = ConsentPrompt(
            actionTitle: "Take over this run", effect: action.kind, target: action.run,
            arguments: "Action: " + String(decoding: canonicalAction, as: UTF8.self), digest: consent.digest,
            requiresBiometry: true)
        prompt.signingInputHash = hash(signingInput)
        return prompt
    }

    static func connection(canonicalRecord: Data, signingInput: Data) throws -> ConsentPrompt {
        let record = try object(
            canonicalRecord,
            fields: ["auth", "device", "egress", "endpoint", "flow", "id", "kind", "local", "name", "tools", "v"])
        let consentData = try payload(signingInput, context: "astral.consent/v1")
        let consentObject = try object(consentData, fields: ["v", "kind", "digest", "device", "clock"])
        let consent = try JSONDecoder().decode(ActionConsent.self, from: consentData)
        try checkClock(consentObject["clock"], value: consent.clock)
        guard record["v"] as? Int == 1, let name = record["name"] as? String, !name.isEmpty,
            let endpoint = record["endpoint"] as? String, !endpoint.isEmpty,
            let flow = record["flow"] as? String, ["private", "phi"].contains(flow),
            let auth = record["auth"] as? [String: Any],
            Set(auth.keys) == ["client_id", "issuer", "resource", "scheme", "scopes"],
            let scheme = auth["scheme"] as? String, ["oauth", "none"].contains(scheme),
            let scopes = auth["scopes"] as? [String], let tools = record["tools"] as? [[String: Any]],
            let egress = record["egress"] as? [String], consent.v == 1, consent.kind == "connection",
            isID(consent.device), consent.digest == hashID(canonicalRecord)
        else { throw ConsentPromptError.invalidInput }
        let names = try tools.map { tool -> String in
            guard Set(tool.keys) == ["hash", "name"], let name = tool["name"] as? String else {
                throw ConsentPromptError.invalidInput
            }
            return name
        }
        var lines = ["Server: " + endpoint, "Sign-in: " + (scheme == "oauth" ? "OAuth" : "none")]
        if let issuer = auth["issuer"] as? String { lines.append("Issuer: " + issuer) }
        if !scopes.isEmpty { lines.append("Scopes: " + scopes.joined(separator: ", ")) }
        lines.append("Data class: " + flow)
        lines.append("Reaches: " + egress.joined(separator: ", "))
        lines.append("Tools: " + (names.isEmpty ? "none listed" : names.joined(separator: ", ")))
        var prompt = ConsentPrompt(
            actionTitle: "Connect " + name, effect: "connection.approve", target: name + " at " + endpoint,
            arguments: lines.joined(separator: "\n") + "\nRecord: " + String(decoding: canonicalRecord, as: UTF8.self),
            digest: consent.digest, requiresBiometry: true)
        prompt.signingInputHash = hash(signingInput)
        return prompt
    }

    static func contact(canonicalRecord: Data, signingInput: Data) throws -> ConsentPrompt {
        let record = try object(canonicalRecord, fields: ["count", "heads", "mesh", "ms", "name", "state", "v"])
        let consent = try recordConsent(signingInput, kind: "contact", record: canonicalRecord)
        guard record["v"] as? Int == 1, let mesh = record["mesh"] as? String, isID(mesh),
            let name = record["name"] as? String, !name.isEmpty, record["state"] as? String == "verified",
            let heads = record["heads"] as? [String], !heads.isEmpty, heads.allSatisfy(isID),
            let count = record["count"] as? Int, count >= heads.count
        else { throw ConsentPromptError.invalidInput }
        let lines = ["Name: " + name, "Mesh: " + fingerprint(mesh)]
        var prompt = ConsentPrompt(
            actionTitle: "Verify contact", effect: "contact.verify", target: name + ", mesh " + fingerprint(mesh),
            arguments: lines.joined(separator: "\n") + "\nRecord: " + String(decoding: canonicalRecord, as: UTF8.self),
            digest: consent.digest, requiresBiometry: true)
        prompt.signingInputHash = hash(signingInput)
        return prompt
    }

    static func share(canonicalRecord: Data, signingInput: Data, label: String) throws -> ConsentPrompt {
        let record = try object(
            canonicalRecord, fields: ["contact", "id", "item", "kind", "ms", "phi", "supersedes", "v"])
        let consent = try recordConsent(signingInput, kind: "share", record: canonicalRecord)
        guard record["v"] as? Int == 1, record["kind"] as? String == "view", let contact = record["contact"] as? String,
            isID(contact), let phi = record["phi"] as? Bool,
            let item = record["item"] as? [String: Any], Set(item.keys) == ["chat", "kind"],
            item["kind"] as? String == "chat", let chat = item["chat"] as? String, isID(chat)
        else { throw ConsentPromptError.invalidInput }
        var lines = ["Chat: " + String(label.prefix(200)), "With mesh: " + fingerprint(contact)]
        lines.append(phi ? "This chat holds PHI and PHI is included." : "Read only. PHI isn't included.")
        var prompt = ConsentPrompt(
            actionTitle: phi ? "Share chat with PHI" : "Share chat", effect: "share.grant",
            target: "Chat " + String(chat.dropFirst("sha256:".count).prefix(8)) + " with mesh " + fingerprint(contact),
            arguments: lines.joined(separator: "\n") + "\nRecord: " + String(decoding: canonicalRecord, as: UTF8.self),
            digest: consent.digest, requiresBiometry: true,
            summary: phi ? "Share this chat and its PHI with another mesh" : "Share this chat with another mesh")
        prompt.signingInputHash = hash(signingInput)
        return prompt
    }

    private static func recordConsent(_ signingInput: Data, kind: String, record: Data) throws -> ActionConsent {
        let consentData = try payload(signingInput, context: "astral.consent/v1")
        let consentObject = try object(consentData, fields: ["v", "kind", "digest", "device", "clock"])
        let consent = try JSONDecoder().decode(ActionConsent.self, from: consentData)
        try checkClock(consentObject["clock"], value: consent.clock)
        guard consent.v == 1, consent.kind == kind, isID(consent.device), consent.digest == hashID(record) else {
            throw ConsentPromptError.invalidInput
        }
        return consent
    }

    static func fingerprint(_ mesh: String) -> String {
        let digits = Array(mesh.dropFirst("sha256:".count).prefix(16))
        return stride(from: 0, to: digits.count, by: 4).map { String(digits[$0..<min($0 + 4, digits.count)]) }
            .joined(separator: " ")
    }

    static func isGrant(canonicalAction: Data) -> Bool {
        guard let value = try? JSONSerialization.jsonObject(with: canonicalAction) as? [String: Any] else {
            return false
        }
        return value["kind"] as? String == "auth.grant"
    }

    static func grant(canonicalAction: Data, canonicalArguments: Data, signingInput: Data) throws -> ConsentPrompt {
        _ = try object(canonicalAction, fields: ["agent", "grant", "kind", "scope", "tool"])
        let action = try JSONDecoder().decode(Grant.self, from: canonicalAction)
        let consentData = try payload(signingInput, context: "astral.consent/v1")
        let consentObject = try object(consentData, fields: ["v", "kind", "digest", "device", "clock"])
        let consent = try JSONDecoder().decode(ActionConsent.self, from: consentData)
        try checkClock(consentObject["clock"], value: consent.clock)
        guard canonicalArguments == canonicalAction, action.kind == "auth.grant", consent.v == 1,
            consent.kind == "grant", isID(action.grant), consent.digest == action.grant, isID(consent.device),
            !action.agent.isEmpty, !action.tool.isEmpty, !action.scope.isEmpty
        else { throw ConsentPromptError.invalidInput }
        var prompt = ConsentPrompt(
            actionTitle: "Allow " + action.tool, effect: action.tool,
            target: "Permission: " + MeshToolScope.description(action.scope) + ", for " + action.agent,
            arguments: "Action: " + String(decoding: canonicalAction, as: UTF8.self), digest: consent.digest,
            requiresBiometry: true, summary: "Let " + action.agent + " use " + action.tool)
        prompt.signingInputHash = hash(signingInput)
        return prompt
    }

    static func pending(canonicalAction: Data, canonicalArguments: Data) throws -> ConsentPrompt {
        _ = try object(
            canonicalAction,
            fields: ["v", "mesh", "device", "turn", "agent", "tool", "tool_def", "args_digest", "influence"])
        let action = try JSONDecoder().decode(Action.self, from: canonicalAction)
        guard try KernelCanonicalJSON.canonicalize(canonicalArguments) == canonicalArguments,
            action.v == 1, !action.agent.isEmpty, !action.tool.isEmpty,
            action.argsDigest == hashID(canonicalArguments)
        else { throw ConsentPromptError.invalidInput }
        return ConsentPrompt(
            actionTitle: "Approve " + action.tool, effect: action.tool, target: action.mesh + " / " + action.agent,
            arguments: "Action: " + String(decoding: canonicalAction, as: UTF8.self)
                + "\nArguments: " + String(decoding: canonicalArguments, as: UTF8.self),
            untrustedSource: action.influence.isEmpty ? nil : action.influence.joined(separator: ", "),
            digest: hashID(canonicalAction))
    }

    static func roster(signingInput: Data) throws -> ConsentPrompt {
        let data = try payload(signingInput, context: "astral.roster/v2")
        let entry = try object(data, fields: ["v", "type", "mesh", "author", "follows", "clock", "body"])
        if entry["type"] as? String == "genesis" { return try genesis(data, entry: entry, signingInput: signingInput) }
        let header = try JSONDecoder().decode(RosterHeader.self, from: data)
        try checkClock(entry["clock"], value: header.clock)
        guard header.v == 2, isID(header.mesh), isID(header.author), !header.follows.isEmpty,
            header.follows == Array(Set(header.follows)).sorted(), header.follows.allSatisfy(isID),
            let body = entry["body"] as? [String: Any]
        else { throw ConsentPromptError.invalidInput }
        let target: String
        var summary: String?
        switch header.type {
        case "add":
            guard Set(body.keys) == ["device"] else { throw ConsentPromptError.invalidInput }
            let device = try deviceRecord(body["device"])
            target = device.label + " (" + hashID(device.identity) + ")"
            summary = "Add " + device.label + " to your mesh"
        case "remove":
            guard Set(body.keys) == ["device", "cutoff"] else { throw ConsentPromptError.invalidInput }
            let removal = try JSONDecoder().decode(Removal.self, from: data)
            guard isID(removal.body.device), removal.body.cutoff.values.allSatisfy({ $0 >= 0 }) else {
                throw ConsentPromptError.invalidInput
            }
            for feed in removal.body.cutoff.keys { _ = try keyBytes(feed, count: 32) }
            target = removal.body.device
            summary = "Remove a device from your mesh"
        case "stop", "resume":
            guard Set(body.keys) == ["counter"], let counter = body["counter"] as? Int, counter >= 1 else {
                throw ConsentPromptError.invalidInput
            }
            target = (header.type == "stop" ? "Stop counter " : "Resume counter ") + String(counter)
            summary = header.type == "stop" ? "Stop your mesh on every device" : "Resume your mesh on every device"
        case "phi_authority", "phi_approval":
            let described = try phi(header.type, body: body)
            return try phiPrompt(described, data: data, signingInput: signingInput)
        default:
            throw ConsentPromptError.invalidInput
        }
        let titles = [
            "add": "Add device", "remove": "Remove device", "stop": "Stop the mesh", "resume": "Resume the mesh",
        ]
        var prompt = ConsentPrompt(
            actionTitle: titles[header.type] ?? "Roster change",
            effect: "roster." + header.type, target: target,
            arguments: String(decoding: data, as: UTF8.self), digest: hashID(data), requiresBiometry: true,
            summary: summary)
        prompt.signingInputHash = hash(signingInput)
        return prompt
    }

    private struct PhiChange {
        let effect: String
        let title: String
        let target: String
        let summary: String
    }

    private static let approvalFields: Set<String> = [
        "kind", "institution", "subject_kind", "subject", "issued_s", "not_after_s", "sig",
    ]

    private static func phi(_ type: String, body: [String: Any]) throws -> PhiChange {
        if type == "phi_authority" {
            guard Set(body.keys) == ["action", "institution"], body["action"] as? String == "add",
                let institution = body["institution"] as? [String: Any], Set(institution.keys) == ["key", "name"],
                let name = institution["name"] as? String, name.hasPrefix(approverPrefix),
                isID(String(name.dropFirst(approverPrefix.count)))
            else { throw ConsentPromptError.invalidInput }
            _ = try keyBytes(institution["key"], count: 65)
            return PhiChange(
                effect: "roster.phi_register_approver", title: "Let this device approve PHI places",
                target: String(name.dropFirst(approverPrefix.count)),
                summary: "Let this device approve places that can receive PHI")
        }
        guard let action = body["action"] as? String else { throw ConsentPromptError.invalidInput }
        if action == "revoke" {
            guard Set(body.keys) == ["action", "subject"], let subject = body["subject"] as? String, !subject.isEmpty
            else { throw ConsentPromptError.invalidInput }
            return PhiChange(
                effect: "roster.phi_revoke", title: "Take back a PHI approval", target: subject,
                summary: "Take back a PHI approval")
        }
        guard action == "grant", Set(body.keys) == ["action", "attestation"],
            let statement = body["attestation"] as? [String: Any], Set(statement.keys) == approvalFields,
            statement["kind"] as? String == "phi", let kind = statement["subject_kind"] as? String,
            let subject = statement["subject"] as? String, !subject.isEmpty
        else { throw ConsentPromptError.invalidInput }
        switch kind {
        case "device", "node":
            return PhiChange(effect: "roster.phi_grant", title: "Let a device read PHI", target: subject,
                summary: "Let a device on your mesh read PHI")
        case "endpoint":
            return PhiChange(
                effect: "roster.phi_approve_destination", title: "Let a place receive PHI", target: subject,
                summary: "Let " + subject + " receive PHI")
        default: throw ConsentPromptError.invalidInput
        }
    }

    private static func phiPrompt(_ change: PhiChange, data: Data, signingInput: Data) throws -> ConsentPrompt {
        var prompt = ConsentPrompt(
            actionTitle: change.title, effect: change.effect, target: change.target,
            arguments: String(decoding: data, as: UTF8.self), digest: hashID(data), requiresBiometry: true,
            summary: change.summary)
        prompt.signingInputHash = hash(signingInput)
        return prompt
    }

    private static let approverPrefix = "astral-device:"

    func requiringBiometry(_ required: Bool) -> ConsentPrompt {
        guard required, !requiresBiometry else { return self }
        var copy = ConsentPrompt(
            actionTitle: actionTitle, effect: effect, target: target, arguments: arguments,
            untrustedSource: untrustedSource, labels: labels, digest: digest, requiresBiometry: true,
            summary: summary)
        copy.signingInputHash = signingInputHash
        return copy
    }

    private static func genesis(_ data: Data, entry: [String: Any], signingInput: Data) throws -> ConsentPrompt {
        let header = try JSONDecoder().decode(GenesisHeader.self, from: data)
        try checkClock(entry["clock"], value: header.clock)
        guard header.v == 2, entry["mesh"] is NSNull, header.follows.isEmpty, isID(header.author),
            let body = entry["body"] as? [String: Any], Set(body.keys) == ["device", "epoch", "recovery"],
            let recovery = body["recovery"] as? [String: Any], Set(recovery.keys) == ["sign", "wrap"]
        else { throw ConsentPromptError.invalidInput }
        let device = try deviceRecord(body["device"])
        guard hashID(device.identity) == header.author else { throw ConsentPromptError.invalidInput }
        try genesisEpoch(body["epoch"])
        _ = try keyBytes(recovery["sign"], count: 32)
        _ = try keyBytes(recovery["wrap"], count: 32)
        var prompt = ConsentPrompt(
            actionTitle: "Create your mesh", effect: "roster.genesis",
            target: device.label + " (" + header.author + ")",
            arguments: String(decoding: data, as: UTF8.self), digest: hashID(data), requiresBiometry: true,
            summary: "Create your mesh on " + device.label)
        prompt.signingInputHash = hash(signingInput)
        return prompt
    }

    static func recovery(action: String, signingInput: Data) throws -> ConsentPrompt {
        let domain: String
        let title: String
        switch action {
        case "reveal_recovery":
            domain = "astral.recovery.export/v2\n"
            title = "Show your recovery words"
        case "confirm_recovery":
            domain = "astral.recovery.confirm/v2\n"
            title = "Confirm your recovery words are saved"
        default: throw ConsentPromptError.invalidInput
        }
        guard let input = String(data: signingInput, encoding: .utf8), input.hasPrefix(domain) else {
            throw ConsentPromptError.invalidInput
        }
        let mesh = String(input.dropFirst(domain.count))
        guard isID(mesh) else { throw ConsentPromptError.invalidInput }
        var prompt = ConsentPrompt(
            actionTitle: title, effect: action, target: mesh, arguments: "", digest: hashID(signingInput),
            requiresBiometry: true)
        prompt.signingInputHash = hash(signingInput)
        return prompt
    }

    var summaryLine: String { summary ?? "Review the details before you approve." }

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

    private static func deviceRecord(_ value: Any?) throws -> (identity: Data, label: String) {
        guard let record = value as? [String: Any],
            Set(record.keys) == ["identity", "presence", "ops", "wrap", "kind", "label", "cert"],
            let kind = record["kind"] as? String, ["desktop", "pocket", "satellite", "node"].contains(kind),
            let label = record["label"] as? String, (1...64).contains(label.unicodeScalars.count)
        else { throw ConsentPromptError.invalidInput }
        let identity = try keyBytes(record["identity"], count: 65)
        let presence = try keyBytes(record["presence"], count: 65)
        _ = try P256.Signing.PublicKey(x963Representation: identity)
        _ = try P256.Signing.PublicKey(x963Representation: presence)
        _ = try keyBytes(record["ops"], count: 32)
        _ = try keyBytes(record["wrap"], count: 32)
        _ = try keyBytes(record["cert"], count: 64)
        return (identity, label)
    }

    private static func genesisEpoch(_ value: Any?) throws {
        guard let epoch = value as? [String: Any], Set(epoch.keys) == ["group", "recovery_wrap", "wraps"],
            epoch["group"] as? String == "personal", let wraps = epoch["wraps"] as? [[String: Any]], !wraps.isEmpty
        else { throw ConsentPromptError.invalidInput }
        var devices: Set<String> = []
        for recipient in wraps {
            guard Set(recipient.keys) == ["device", "wrap"], let device = recipient["device"] as? String,
                isID(device), devices.insert(device).inserted
            else { throw ConsentPromptError.invalidInput }
            try sealed(recipient["wrap"])
        }
        try sealed(epoch["recovery_wrap"])
    }

    private static func sealed(_ value: Any?) throws {
        guard let wrap = value as? [String: Any], Set(wrap.keys) == ["ct", "epk", "nonce"] else {
            throw ConsentPromptError.invalidInput
        }
        _ = try keyBytes(wrap["epk"], count: 32)
        _ = try keyBytes(wrap["nonce"], count: 24)
        _ = try keyBytes(wrap["ct"], count: 48)
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

private nonisolated struct Grant: Decodable {
    let agent, grant, kind, scope, tool: String
}

private nonisolated struct GenesisHeader: Decodable {
    let v: Int64
    let author: String
    let follows: [String]
    let clock: Clock
}

private nonisolated struct Takeover: Decodable {
    let v: Int64
    let executor, kind, run: String
    let supersedes: [String]
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
