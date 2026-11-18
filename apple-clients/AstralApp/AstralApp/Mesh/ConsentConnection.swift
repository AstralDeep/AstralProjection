// Builds the consent display for every connection record kind the kernel signs: MCP over HTTP, A2A agents, MCP over stdio, HTTP APIs and model providers.
// ConsentPrompt.connection accepts only each kind's exact field set and shows the plain summary and the security details from the record itself.

import Foundation

private nonisolated struct ConnectionDisplay {
    let title: String
    let summary: String
    let target: String
    let lines: [String]
}

private nonisolated struct ConnectionLimits {
    static let egress = 16
    static let tools = 128
    static let name = 80
    static let args = 64
    static let env = 32
}

extension ConsentPrompt {
    private static let connectionFields: [String: Set<String>] = [
        "mcp-http": ["auth", "device", "egress", "endpoint", "flow", "id", "kind", "local", "name", "tools", "v"],
        "a2a": ["auth", "card", "card_url", "egress", "flow", "id", "kind", "name", "tools", "v"],
        "mcp-stdio": ["args", "command", "device", "egress", "env", "flow", "id", "kind", "name", "tools", "v"],
        "http-api": ["egress", "endpoint", "flow", "id", "key", "kind", "name", "tools", "v"],
        "model": ["egress", "endpoint", "flow", "id", "key", "kind", "name", "v"],
    ]

    private static let authFields: Set<String> = ["client_id", "issuer", "resource", "scheme", "scopes"]

    static func connection(canonicalRecord: Data, signingInput: Data) throws -> ConsentPrompt {
        let record = try object(canonicalRecord)
        guard let kind = record["kind"] as? String, let fields = connectionFields[kind], Set(record.keys) == fields,
            isNumberOne(record["v"]), let id = record["id"] as? String, isConnectionID(id),
            let name = record["name"] as? String, (1...ConnectionLimits.name).contains(name.count)
        else { throw ConsentPromptError.invalidInput }
        let consent = try recordConsent(signingInput, kind: "connection", record: canonicalRecord)
        let flow = try dataClass(record["flow"])
        let reaches = try egressList(record["egress"], allowEmpty: kind == "mcp-stdio")
        let shown: ConnectionDisplay
        switch kind {
        case "mcp-http": shown = try mcpHTTP(record, name: name)
        case "a2a": shown = try a2a(record, name: name)
        case "mcp-stdio": shown = try stdio(record, name: name, approver: consent.device)
        case "http-api": shown = try httpAPI(record, name: name, id: id)
        default: shown = try modelProvider(record, name: name)
        }
        var lines = shown.lines + ["Data class: " + flow, "Reaches: " + (reaches.isEmpty ? "nothing" : reaches)]
        if kind != "model" {
            let tools = try toolNames(record["tools"], limit: kind == "a2a" ? 1 : ConnectionLimits.tools)
            lines.append("Tools: " + (tools.isEmpty ? "none listed" : tools.joined(separator: ", ")))
        }
        let raw = "\nRecord: " + String(decoding: canonicalRecord, as: UTF8.self)
        let prompt = ConsentPrompt(
            actionTitle: shown.title, effect: "connection.approve", target: shown.target,
            arguments: lines.joined(separator: "\n") + raw, digest: consent.digest, requiresBiometry: true,
            summary: shown.summary)
        return prompt.bound(to: signingInput)
    }

    private static func mcpHTTP(_ record: [String: Any], name: String) throws -> ConnectionDisplay {
        guard let local = flag(record["local"]), let endpoint = record["endpoint"] as? String else {
            throw ConsentPromptError.invalidInput
        }
        let device = record["device"]
        if local {
            guard let holder = device as? String, isID(holder) else { throw ConsentPromptError.invalidInput }
        } else if !(device is NSNull) {
            throw ConsentPromptError.invalidInput
        }
        let host = try hostName(endpoint, loopback: local)
        let auth = try authLines(record["auth"], schemes: ["oauth", "none", "key"], resource: endpoint)
        let place = local ? "on this device" : "at " + host
        return ConnectionDisplay(
            title: "Connect " + name, summary: "Connect " + name + ", a tool server " + place,
            target: name + " at " + endpoint, lines: ["Server: " + endpoint] + auth)
    }

    private static func a2a(_ record: [String: Any], name: String) throws -> ConnectionDisplay {
        guard let url = record["card_url"] as? String, let card = record["card"] as? [String: Any],
            Set(card.keys) == ["extended_hash", "hash", "origin", "signer"], let hash = card["hash"] as? String,
            isID(hash), let origin = card["origin"] as? String, origin.hasPrefix("https://"), url.hasPrefix(origin)
        else { throw ConsentPromptError.invalidInput }
        let host = try hostName(url, loopback: false)
        let auth = try authLines(record["auth"], schemes: ["none", "key", "oauth"], resource: nil)
        var lines = ["Agent card: " + url] + auth
        lines.append("Card hash: " + hash)
        lines.append(try signerLine(card["signer"]))
        let extended = card["extended_hash"]
        if let value = extended as? String, isID(value) {
            lines.append("Extended card hash: " + value)
        } else if !(extended is NSNull) {
            throw ConsentPromptError.invalidInput
        }
        return ConnectionDisplay(
            title: "Connect " + name, summary: "Connect " + name + ", an agent at " + host,
            target: name + " at " + url, lines: lines)
    }

    private static func stdio(_ record: [String: Any], name: String, approver: String) throws -> ConnectionDisplay {
        guard let command = record["command"] as? String, (1...1024).contains(command.count),
            let args = record["args"] as? [String], args.count <= ConnectionLimits.args,
            args.allSatisfy({ $0.count <= 4096 }), let env = record["env"] as? [String],
            env.count <= ConnectionLimits.env, env.allSatisfy({ !$0.isEmpty && $0.count <= 64 }),
            let device = record["device"] as? String, isID(device)
        else { throw ConsentPromptError.invalidInput }
        let here = device == approver
        var lines = ["Command: " + ([command] + args).joined(separator: " ")]
        lines.append("Runs on: " + (here ? "this device" : device))
        let secrets = env.isEmpty ? "none" : env.joined(separator: ", ") + " (values never shown)"
        lines.append("Secrets passed: " + secrets)
        let place = here ? "on this Mac" : "on another device in your mesh"
        return ConnectionDisplay(
            title: "Run " + name, summary: "Run " + name + " " + place, target: name + " " + place, lines: lines)
    }

    private static func httpAPI(_ record: [String: Any], name: String, id: String) throws -> ConnectionDisplay {
        guard let endpoint = record["endpoint"] as? String, let key = record["key"] as? [String: Any],
            Set(key.keys) == ["format", "header", "item"], key["item"] as? String == "connection.key." + id,
            let header = key["header"] as? String, (1...64).contains(header.count),
            let format = key["format"] as? String, (1...64).contains(format.count),
            format.components(separatedBy: "{key}").count == 2
        else { throw ConsentPromptError.invalidInput }
        let host = try hostName(endpoint, loopback: false)
        let lines = ["Server: " + endpoint, "Key sent as: " + header + ": " + format, "Key: sealed, never shown here"]
        return ConnectionDisplay(
            title: "Connect " + name, summary: "Connect " + name + ", an API at " + host,
            target: name + " at " + endpoint, lines: lines)
    }

    private static func modelProvider(_ record: [String: Any], name: String) throws -> ConnectionDisplay {
        guard let endpoint = record["endpoint"] as? String, let key = record["key"] as? [String: Any],
            Set(key.keys) == ["item"], let item = key["item"] as? String, item.hasPrefix("model.provider."),
            item.count > "model.provider.".count, item.count <= 128
        else { throw ConsentPromptError.invalidInput }
        let host = try hostName(endpoint, loopback: false)
        let lines = ["Server: " + endpoint, "Key: sealed, never shown here"]
        return ConnectionDisplay(
            title: "Connect " + name, summary: "Connect " + name + ", a model at " + host,
            target: name + " at " + endpoint, lines: lines)
    }

    private static func authLines(_ value: Any?, schemes: Set<String>, resource: String?) throws -> [String] {
        guard let auth = value as? [String: Any], Set(auth.keys) == authFields, let scheme = auth["scheme"] as? String,
            schemes.contains(scheme), let scopes = auth["scopes"] as? [String], scopes.count <= 32,
            auth["client_id"] is NSNull || auth["client_id"] is String
        else { throw ConsentPromptError.invalidInput }
        let words = ["oauth": "OAuth", "none": "none", "key": "pasted key"]
        var lines = ["Sign-in: " + (words[scheme] ?? scheme)]
        if scheme == "oauth" {
            guard let issuer = auth["issuer"] as? String, !issuer.isEmpty else { throw ConsentPromptError.invalidInput }
            if let resource {
                guard auth["resource"] as? String == resource else { throw ConsentPromptError.invalidInput }
            } else if !(auth["resource"] is NSNull) {
                throw ConsentPromptError.invalidInput
            }
            lines.append("Issuer: " + issuer)
            if !scopes.isEmpty { lines.append("Scopes: " + scopes.joined(separator: ", ")) }
        } else {
            let bare = auth["issuer"] is NSNull && auth["resource"] is NSNull && scopes.isEmpty
            guard bare, auth["client_id"] is NSNull else { throw ConsentPromptError.invalidInput }
        }
        return lines
    }

    private static func signerLine(_ value: Any?) throws -> String {
        if value is NSNull { return "Card signer: none, the card is unsigned" }
        guard let pin = value as? String, pin.count == 43 else { throw ConsentPromptError.invalidInput }
        return "Card signer pin: " + pin
    }

    private static func hostName(_ text: String, loopback: Bool) throws -> String {
        guard let parts = URLComponents(string: text), let host = parts.host, !host.isEmpty, parts.user == nil,
            parts.query == nil, parts.fragment == nil,
            parts.scheme == "https" || (loopback && parts.scheme == "http")
        else { throw ConsentPromptError.invalidInput }
        return parts.port.map { host + ":" + String($0) } ?? host
    }

    private static func dataClass(_ value: Any?) throws -> String {
        guard let flow = value as? String, flow == "private" || flow == "phi" else {
            throw ConsentPromptError.invalidInput
        }
        return flow
    }

    private static func egressList(_ value: Any?, allowEmpty: Bool) throws -> String {
        guard let entries = value as? [String], entries.count <= ConnectionLimits.egress,
            allowEmpty || !entries.isEmpty, entries.allSatisfy({ !$0.isEmpty }), Set(entries).count == entries.count
        else { throw ConsentPromptError.invalidInput }
        return entries.joined(separator: ", ")
    }

    private static func toolNames(_ value: Any?, limit: Int) throws -> [String] {
        guard let tools = value as? [[String: Any]], tools.count <= limit else { throw ConsentPromptError.invalidInput }
        return try tools.map { tool in
            guard Set(tool.keys) == ["hash", "name"], let hash = tool["hash"] as? String, isID(hash),
                let name = tool["name"] as? String, (1...128).contains(name.count)
            else { throw ConsentPromptError.invalidInput }
            return name
        }
    }

    private static func isConnectionID(_ text: String) -> Bool {
        text.utf8.count == 32 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isNumberOne(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.intValue == 1
    }

    private static func flag(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
