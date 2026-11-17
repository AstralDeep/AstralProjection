// The connection book behind InMemoryMeshKernel: it applies the real kernel's refusals to proposals, approvals, sign-in flows, states and step-up.
// Servers are scripted by endpoint, credentials stay in a dictionary standing in for the keystore, and codes match the kernel's.

import Foundation

nonisolated final class InMemoryConnections: @unchecked Sendable {
    struct Server: Sendable {
        var issuer: String?
        var scopes: [String] = []
        var tools: [MeshConnectionTool] = []
        var refreshRefused = false
        var refreshable = true

        var open: Bool { issuer == nil }
    }

    struct Card: Sendable {
        var hash = "sha256:" + String(repeating: "a", count: 64)
        var origin = ""
        var signed = false
        var signer: String?
        var skills: [String] = ["Answer questions"]
        var scheme = "none"
        var issuer: String?
        var scopes: [String] = []
        var interfaceHosts: [String] = []
        var extendedHash: String?
    }

    private struct Held {
        var proposal: MeshConnectionProposal
        var base: Int?
        var keys: [String: Data] = [:]
        var recipients: [String]?
    }

    private struct Flow {
        let id: String
        let connection: String
        let redirect: MeshSignInRedirect
        let redirectURI: String
        let state: String
        let expiresMs: UInt64
        var polls = 0
    }

    private struct Record {
        var proposal: MeshConnectionProposal
        var flow: String
        var tools: [MeshConnectionTool]
        var scopes: [String]
        var revision: Int
        var states: [String: MeshConnectionDeviceState] = [:]
        var pendingTools: [MeshConnectionTool]?
        var requiredScopes: [String]?
        var stepUpUsed = false
        var keyRecipients: [String]?
    }

    static let maxProposals = 8
    static let maxFlows = 4
    static let proposalTTLMs: UInt64 = 600_000
    static let appLinkRedirect = "https://astraldeep.github.io/oauth/callback"

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private let deviceId: String
    private let deviceLabel: String
    private var servers: [String: Server] = [:]
    private var held: [Held] = []
    private var records: [String: Record] = [:]
    private var flows: [String: Flow] = [:]
    private var secrets: [String: Data] = [:]
    private var cards: [String: Card] = [:]
    private var counter = 0

    var isNode = false
    var hasKeystore = true
    var presenceDenied = false
    var devicePollsBeforeDone = 1

    init(deviceId: String, deviceLabel: String, now: @escaping @Sendable () -> Date) {
        self.deviceId = deviceId
        self.deviceLabel = deviceLabel
        self.now = now
    }

    var credentialAccounts: [String] { lock.withLock { secrets.keys.sorted() } }

    func registerServer(_ endpoint: String, _ server: Server) { lock.withLock { servers[endpoint] = server } }

    func modelFacts(of id: String) -> (models: [String], recipients: [String]?)? {
        lock.withLock {
            guard let proposal = records[id]?.proposal, proposal.kind == "model" else { return nil }
            return (proposal.models, records[id]?.keyRecipients)
        }
    }

    func registerCard(_ url: String, _ card: Card) { lock.withLock { cards[url] = card } }

    func changeCard(_ url: String, _ change: (inout Card) -> Void) {
        lock.withLock {
            guard var card = cards[url] else { return }
            change(&card)
            cards[url] = card
            for (id, record) in records where record.proposal.endpoint == url {
                _ = state(id, "needs_attention", "refused")
            }
        }
    }

    func seedDeviceState(_ id: String, _ state: MeshConnectionDeviceState) {
        lock.withLock { records[id]?.states[state.device] = state }
    }

    func propose(endpoint: String, name: String, local: Bool) throws -> MeshConnectionProposal {
        try Self.checkName(name)
        let server = try discover(endpoint: endpoint, local: local)
        return lock.withLock {
            counter += 1
            let id = String(format: "%032x", counter)
            return hold(draft(id, name, endpoint, local, server, replaces: nil, record: nil), base: nil)
        }
    }

    func proposeKey(endpoint: String, name: String, local: Bool, key: String, recipients: [String]?) throws
        -> MeshConnectionProposal
    {
        try Self.checkName(name)
        try Self.checkKey(key)
        try Self.checkRecipients(recipients)
        let server = try discover(endpoint: endpoint, local: local)
        return lock.withLock {
            counter += 1
            let id = String(format: "%032x", counter)
            var base = draft(id, name, endpoint, local, Server(issuer: nil, scopes: [], tools: server.tools),
                replaces: nil, record: nil)
            base.scheme = "key"
            base.redirectHost = nil
            base.resource = nil
            base.keyRecipients = recipients
            return hold(base, base: nil, keys: ["key": Data(key.utf8)], recipients: recipients)
        }
    }

    func proposeHttpApi(_ draft: MeshHttpApiDraft) throws -> MeshConnectionProposal {
        try Self.checkName(draft.name)
        try Self.checkKey(draft.key)
        try Self.checkRecipients(draft.recipients)
        guard let url = URLComponents(string: draft.endpoint), url.scheme == "https", let host = url.host,
            !host.isEmpty
        else { throw Self.refused("connection.egress_refused") }
        let formatOK: Bool = draft.format.components(separatedBy: "{key}").count == 2
        let headerOK: Bool = MeshConnectionKeyModel.validHeader(draft.header)
        guard formatOK, headerOK else { throw Self.refused("connection.malformed") }
        return lock.withLock {
            counter += 1
            let id = String(format: "%032x", counter)
            let found = MeshConnectionProposal(
                proposal: "proposal-\(id)-\(counter)", connection: id, name: draft.name, endpoint: draft.endpoint,
                local: false, device: nil, scheme: "key", issuer: nil, issuerHost: nil, redirectHost: nil,
                scopes: [], resource: nil, clientId: nil, tools: [], egress: [host], flowHint: "private",
                replaces: nil, expiresMs: nowMs + Self.proposalTTLMs, kind: "http-api", keyHeader: draft.header,
                keyFormat: draft.format, keyItem: "astral.connection.key/" + id, keyRecipients: draft.recipients)
            return hold(found, base: nil, keys: ["key": Data(draft.key.utf8)], recipients: draft.recipients)
        }
    }

    func proposeModel(_ draft: MeshModelConnectionDraft) throws -> MeshConnectionProposal {
        try Self.checkName(draft.name)
        try Self.checkRecipients(draft.recipients)
        guard !draft.models.isEmpty, !draft.apiKeys.isEmpty else { throw Self.refused("connection.key_required") }
        try draft.apiKeys.forEach(Self.checkKey)
        guard let url = URLComponents(string: draft.endpoint), let host = url.host, !host.isEmpty,
            url.scheme == "https" || ["127.0.0.1", "::1", "localhost"].contains(host)
        else { throw Self.refused("connection.egress_refused") }
        return lock.withLock {
            counter += 1
            let id = String(format: "%032x", counter)
            let found = MeshConnectionProposal(
                proposal: "proposal-\(id)-\(counter)", connection: id, name: draft.name, endpoint: draft.endpoint,
                local: false, device: nil, scheme: "key", issuer: nil, issuerHost: nil, redirectHost: nil,
                scopes: [], resource: nil, clientId: nil, tools: [], egress: [host], flowHint: "private",
                replaces: nil, expiresMs: nowMs + Self.proposalTTLMs, kind: "model",
                keyItem: "astral.provider/" + draft.provider, models: draft.models, keyRecipients: draft.recipients)
            return hold(found, base: nil, keys: ["key": Data(draft.apiKeys.joined(separator: "\n").utf8)],
                recipients: draft.recipients)
        }
    }

    func proposeA2A(cardURL: String, name: String, key: String?, recipients: [String]?) throws
        -> MeshConnectionProposal
    {
        try Self.checkName(name)
        try Self.checkRecipients(recipients)
        guard let url = URLComponents(string: cardURL), url.scheme == "https", url.host != nil else {
            throw Self.refused("a2a.insecure_url")
        }
        guard let card = lock.withLock({ cards[cardURL] }) else { throw Self.refused("net.unreachable") }
        if card.scheme == "key" { try Self.checkKey(key ?? "") }
        return lock.withLock {
            counter += 1
            let id = String(format: "%032x", counter)
            var found = a2aDraft(id, name, cardURL, card, replaces: nil, flow: "private")
            found.keyRecipients = recipients
            let keys: [String: Data] = card.scheme == "key" ? ["key": Data((key ?? "").utf8)] : [:]
            return hold(found, base: nil, keys: keys, recipients: recipients)
        }
    }

    func setKey(id: String, secrets entries: [MeshConnectionSecret], recipients: [String]?) throws {
        try Self.checkRecipients(recipients)
        try entries.forEach { try Self.checkKey($0.value) }
        try lock.withLock {
            guard let record = records[id] else { throw Self.refused("connection.unknown") }
            guard record.proposal.scheme == "key" else { throw Self.refused("connection.no_key") }
            for entry in entries {
                secrets["astral.connection/v1/\(id)/\(entry.name)"] = Data(entry.value.utf8)
            }
            records[id]?.keyRecipients = recipients
            let here: Bool = recipients?.contains(deviceId) ?? true
            _ = state(id, here ? "signed_in" : "not_signed_in", nil)
        }
    }

    func review(id: String) throws -> MeshConnectionProposal {
        let (record, server) = try lock.withLock { () -> (Record, Server) in
            guard let record = records[id] else { throw Self.refused("connection.unknown") }
            return (record, servers[record.proposal.endpoint] ?? Server())
        }
        if record.proposal.kind == "a2a" {
            return try lock.withLock {
                guard let card = cards[record.proposal.endpoint] else { throw Self.refused("net.unreachable") }
                let found = a2aDraft(
                    id, record.proposal.name, record.proposal.endpoint, card, replaces: id, flow: record.flow)
                return hold(found, base: record.revision, keys: [:], recipients: nil)
            }
        }
        var scopes = server.scopes
        if let required = record.requiredScopes { scopes = Array(Set(scopes).union(required)).sorted() }
        let base = record.proposal
        let found = Server(issuer: server.issuer, scopes: scopes, tools: record.tools)
        return lock.withLock {
            hold(
                draft(base.connection, base.name, base.endpoint, base.local, found, replaces: id, record: record),
                base: record.revision)
        }
    }

    func approve(proposal: String, flow: String, toolNames: [String], clientId: String?) throws -> MeshConnection {
        let current = nowMs
        let value = try lock.withLock { () -> MeshConnection in
            if isNode { throw Self.refused("connection.consent_node_device") }
            guard let index = held.firstIndex(where: { $0.proposal.proposal == proposal }) else {
                throw Self.refused("connection.proposal_unknown")
            }
            let entry = held[index]
            guard current < entry.proposal.expiresMs else {
                held.remove(at: index)
                throw Self.refused("connection.proposal_expired")
            }
            let offered = Dictionary(uniqueKeysWithValues: entry.proposal.tools.map { ($0.name, $0) })
            guard toolNames.allSatisfy({ offered[$0] != nil }) else { throw Self.refused("connection.tool_unknown") }
            guard ["private", "phi"].contains(flow) else { throw Self.refused("connection.record_unsupported") }
            if presenceDenied { throw MeshKernelError.consentDenied }
            held.remove(at: index)
            let id = entry.proposal.connection
            guard records[id]?.revision == entry.base else { throw Self.refused("connection.changed") }
            let tools = Set(toolNames).sorted().compactMap { offered[$0] }
            var record =
                records[id]
                ?? Record(
                    proposal: entry.proposal, flow: flow, tools: tools, scopes: entry.proposal.scopes, revision: 0)
            record.proposal = entry.proposal
            record.flow = flow
            record.tools = tools
            record.scopes = entry.proposal.scopes
            record.revision += 1
            record.pendingTools = nil
            record.keyRecipients = entry.recipients ?? record.keyRecipients
            records[id] = record
            for (name, value) in entry.keys { secrets["astral.connection/v1/\(id)/\(name)"] = value }
            let here: Bool = record.keyRecipients?.contains(deviceId) ?? true
            if entry.proposal.scheme == "key", !entry.keys.isEmpty, here { _ = state(id, "signed_in", nil) }
            if entry.proposal.replaces != nil, record.states[deviceId]?.reason == "refused" {
                let held: Bool = secrets.keys.contains { $0.hasPrefix("astral.connection/v1/\(id)/") }
                _ = state(id, held ? "signed_in" : "not_signed_in", nil)
            }
            return info(id, records[id] ?? record, clientId: clientId)
        }
        return value
    }

    func remove(id: String) throws {
        try lock.withLock {
            guard Self.isID(id) else { throw Self.refused("connection.malformed") }
            guard records.removeValue(forKey: id) != nil else { throw Self.refused("connection.unknown") }
            flows = flows.filter { $0.value.connection != id }
            secrets = secrets.filter { !$0.key.hasPrefix("astral.connection/v1/\(id)/") }
        }
    }

    func list() -> [MeshConnection] {
        lock.withLock { records.sorted { $0.key < $1.key }.map { info($0.key, $0.value, clientId: nil) } }
    }

    func begin(id: String, redirect: MeshSignInRedirect) throws -> MeshSignInStart {
        let current = nowMs
        return try lock.withLock {
            guard let record = records[id] else { throw Self.refused("connection.unknown") }
            guard record.proposal.scheme == "oauth" else { throw Self.refused("connection.no_sign_in") }
            if redirect == .deviceCode, !isNode { throw Self.refused("connection.device_code_unavailable") }
            if !isNode, !hasKeystore { throw Self.refused("connection.keystore_unavailable") }
            if let required = record.requiredScopes, !Set(required).isSubset(of: record.scopes) {
                throw Self.refused("connection.step_up_unreviewed")
            }
            flows = flows.filter { $0.value.expiresMs > current }
            guard flows.count < Self.maxFlows else { throw Self.refused("connection.too_many_flows") }
            let uri = try Self.redirectURI(redirect)
            counter += 1
            let flow = Flow(
                id: "flow-\(counter)", connection: id, redirect: redirect, redirectURI: uri, state: "state-\(counter)",
                expiresMs: current + Self.proposalTTLMs)
            flows[flow.id] = flow
            let issuer: String = record.proposal.issuer ?? ""
            guard redirect == .deviceCode else {
                let authorization: String = issuer + "/authorize?state=" + flow.state
                return MeshSignInStart(
                    flow: flow.id, authorizationURL: authorization, redirectURI: uri, userCode: nil,
                    verificationURI: nil, verificationURIComplete: nil, intervalSeconds: nil, expiresMs: flow.expiresMs)
            }
            let verification: String = issuer + "/device"
            return MeshSignInStart(
                flow: flow.id, authorizationURL: nil, redirectURI: uri, userCode: "WDJB-MJHT",
                verificationURI: verification, verificationURIComplete: nil, intervalSeconds: 5,
                expiresMs: flow.expiresMs)
        }
    }

    func complete(flow: String, redirectURL: String) throws -> MeshConnectionState {
        try lock.withLock {
            let open = try openFlow(flow)
            guard open.redirect != .deviceCode else { throw Self.refused("connection.flow_kind") }
            guard let url = URLComponents(string: redirectURL), redirectURL.hasPrefix(open.redirectURI) else {
                throw Self.refused("connection.redirect_invalid")
            }
            let query = Dictionary(
                (url.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
            guard query["state"] == open.state else { throw Self.refused("oauth.state_mismatch") }
            if query["error"] != nil {
                flows[flow] = nil
                throw Self.refused("oauth.access_denied")
            }
            flows[flow] = nil
            return try signedIn(open.connection)
        }
    }

    func poll(flow: String) throws -> MeshSignInPoll {
        try lock.withLock {
            var open = try openFlow(flow)
            guard open.redirect == .deviceCode else { throw Self.refused("connection.flow_kind") }
            guard open.polls >= devicePollsBeforeDone else {
                open.polls += 1
                flows[flow] = open
                return .pending(intervalSeconds: 5)
            }
            flows[flow] = nil
            return .done(try signedIn(open.connection))
        }
    }

    func cancel(flow: String) { lock.withLock { flows[flow] = nil } }

    func refresh(id: String) throws -> MeshConnectionState {
        try lock.withLock {
            guard let record = records[id] else { throw Self.refused("connection.unknown") }
            guard secrets.keys.contains(where: { $0.hasPrefix("astral.connection/v1/\(id)/") }) else {
                throw Self.refused("connection.not_signed_in")
            }
            let server = servers[record.proposal.endpoint] ?? Server()
            if !server.refreshable { return attention(id, "expired") }
            if server.refreshRefused { return attention(id, "refresh_refused") }
            return state(id, "signed_in", nil)
        }
    }

    func stepUp(id: String, challenge: [String]) throws -> MeshStepUpPlan {
        try lock.withLock {
            guard var record = records[id] else { throw Self.refused("connection.unknown") }
            guard record.proposal.scheme == "oauth" else { throw Self.refused("connection.no_sign_in") }
            guard !record.stepUpUsed else { throw Self.refused("connection.step_up_limit") }
            let union = Array(Set(record.scopes).union(challenge)).sorted()
            record.stepUpUsed = true
            record.requiredScopes = union
            records[id] = record
            _ = attention(id, "scope")
            return Set(union).isSubset(of: record.scopes) ? .signIn(scopes: union) : .review(scopes: union)
        }
    }

    func noteCallSucceeded(id: String) throws {
        try lock.withLock {
            guard records[id] != nil else { throw Self.refused("connection.unknown") }
            records[id]?.stepUpUsed = false
        }
    }

    private var nowMs: UInt64 { UInt64(max(0, now().timeIntervalSince1970 * 1000)) }

    private func discover(endpoint: String, local: Bool) throws -> Server {
        guard let url = URLComponents(string: endpoint), let host = url.host, url.user == nil, url.password == nil,
            url.query == nil, url.fragment == nil
        else { throw Self.refused("connection.malformed") }
        let allowed: Bool
        if ["127.0.0.1", "::1"].contains(host) {
            allowed = local && ["http", "https"].contains(url.scheme)
        } else {
            allowed = !local && url.scheme == "https"
        }
        guard allowed else { throw Self.refused("connection.egress_refused") }
        guard let server = lock.withLock({ servers[endpoint] }) else { throw Self.refused("net.unreachable") }
        return server
    }

    private func draft(
        _ id: String, _ name: String, _ endpoint: String, _ local: Bool, _ server: Server, replaces: String?,
        record: Record?
    ) -> MeshConnectionProposal {
        let host = URLComponents(string: endpoint)?.host ?? ""
        let issuerHost = server.issuer.flatMap { URLComponents(string: $0)?.host }
        var hosts: Set<String> = [host]
        if let issuerHost { hosts.insert(issuerHost) }
        let egress: [String] = hosts.sorted()
        let open = server.open
        let scheme: String = open ? "none" : "oauth"
        let redirectHost: String? = open ? nil : "astraldeep.github.io"
        let resource: String? = open ? nil : endpoint
        let tools: [MeshConnectionTool] = open ? server.tools : []
        let device: String? = local ? deviceId : nil
        let flowHint: String = record?.flow ?? "private"
        let expires: UInt64 = nowMs + Self.proposalTTLMs
        return MeshConnectionProposal(
            proposal: "proposal-\(id)-\(counter)", connection: id, name: name, endpoint: endpoint, local: local,
            device: device, scheme: scheme, issuer: server.issuer, issuerHost: issuerHost, redirectHost: redirectHost,
            scopes: server.scopes, resource: resource, clientId: record?.proposal.clientId, tools: tools,
            egress: egress, flowHint: flowHint, replaces: replaces, expiresMs: expires)
    }

    private func hold(
        _ proposal: MeshConnectionProposal, base: Int?, keys: [String: Data] = [:], recipients: [String]? = nil
    ) -> MeshConnectionProposal {
        held.removeAll { $0.proposal.expiresMs <= nowMs }
        held.append(Held(proposal: proposal, base: base, keys: keys, recipients: recipients))
        if held.count > Self.maxProposals { held.removeFirst(held.count - Self.maxProposals) }
        return proposal
    }

    private func openFlow(_ id: String) throws -> Flow {
        guard let flow = flows[id] else { throw Self.refused("connection.flow_unknown") }
        guard nowMs < flow.expiresMs else {
            flows[id] = nil
            throw Self.refused("connection.flow_expired")
        }
        return flow
    }

    private func signedIn(_ id: String) throws -> MeshConnectionState {
        guard var record = records[id] else { throw Self.refused("connection.unknown") }
        guard isNode || hasKeystore else { throw Self.refused("connection.keystore_unavailable") }
        let issuer = record.proposal.issuer ?? ""
        secrets["astral.connection/v1/\(id)/\(issuer)"] = Data("credential".utf8)
        let listed = servers[record.proposal.endpoint]?.tools ?? record.tools
        record.pendingTools = listed == record.tools ? nil : listed
        record.requiredScopes = nil
        records[id] = record
        return state(id, "signed_in", nil)
    }

    private func attention(_ id: String, _ reason: String) -> MeshConnectionState {
        state(id, "needs_attention", reason)
    }

    private func state(_ id: String, _ name: String, _ reason: String?) -> MeshConnectionState {
        let issuer = records[id]?.proposal.issuer
        records[id]?.states[deviceId] = MeshConnectionDeviceState(
            device: deviceId, label: deviceLabel, state: name, reason: reason, issuer: issuer, atMs: nowMs)
        return MeshConnectionState(
            connection: id, state: name, reason: reason, toolsPending: records[id]?.pendingTools != nil)
    }

    private func info(_ id: String, _ record: Record, clientId: String?) -> MeshConnection {
        let proposal = record.proposal
        let own =
            record.states[deviceId]
            ?? MeshConnectionDeviceState(
                device: deviceId, label: deviceLabel, state: "not_signed_in", reason: nil, issuer: nil, atMs: 0)
        let server: String = "c" + String(id.prefix(8))
        let supported: Bool = !proposal.local || proposal.device == deviceId
        let attention: String? = own.state == "needs_attention" ? own.reason : nil
        let others: [MeshConnectionDeviceState] = record.states.values
            .filter { $0.device != deviceId }
            .sorted { $0.device < $1.device }
        return MeshConnection(
            id: id, server: server, name: proposal.name, kind: proposal.kind, endpoint: proposal.endpoint,
            local: proposal.local, device: proposal.device, scheme: proposal.scheme, issuer: proposal.issuer,
            scopes: record.scopes, clientId: clientId ?? proposal.clientId, flow: record.flow,
            egress: proposal.egress, tools: record.tools, approvedBy: deviceId, approvedByRemovedDevice: false,
            unsupported: nil, supportedHere: supported, thisDevice: own, attention: attention,
            otherDevices: others, pendingTools: record.pendingTools)
    }

    nonisolated static func facts(_ card: Card, url: String) -> MeshProposedCard {
        MeshProposedCard(
            url: url, hash: card.hash, origin: card.origin, signer: card.signer, signed: card.signed,
            extendedHash: card.extendedHash, extendedPending: false, skills: card.skills)
    }

    private func a2aDraft(
        _ id: String, _ name: String, _ url: String, _ card: Card, replaces: String?, flow: String
    ) -> MeshConnectionProposal {
        let cardHost: String = URLComponents(string: url)?.host ?? ""
        let issuerHost: String? = card.issuer.flatMap { URLComponents(string: $0)?.host }
        var hosts: Set<String> = Set(card.interfaceHosts)
        hosts.insert(cardHost)
        if let issuerHost { hosts.insert(issuerHost) }
        let slug: String = String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
        let tool = MeshConnectionTool(name: "ask_" + slug, hash: card.hash)
        let oauth: Bool = card.scheme == "oauth"
        let redirect: String? = oauth ? "astraldeep.github.io" : nil
        var found = MeshConnectionProposal(
            proposal: "proposal-\(id)-\(counter)", connection: id, name: name, endpoint: url, local: false,
            device: nil, scheme: card.scheme, issuer: card.issuer, issuerHost: issuerHost, redirectHost: redirect,
            scopes: card.scopes, resource: nil, clientId: nil, tools: [tool], egress: hosts.sorted(),
            flowHint: flow, replaces: replaces, expiresMs: nowMs + Self.proposalTTLMs, kind: "a2a")
        var facts = Self.facts(card, url: url)
        facts = MeshProposedCard(
            url: facts.url, hash: facts.hash, origin: facts.origin, signer: facts.signer, signed: facts.signed,
            extendedHash: card.extendedHash, extendedPending: replaces != nil && card.extendedHash != nil,
            skills: facts.skills)
        found.card = facts
        return found
    }

    private static func checkKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 4096 else { throw refused("connection.key_required") }
    }

    private static func checkRecipients(_ recipients: [String]?) throws {
        if recipients?.isEmpty == true { throw refused("connection.recipients_empty") }
    }

    private static func redirectURI(_ redirect: MeshSignInRedirect) throws -> String {
        switch redirect {
        case .appLink, .pasted, .deviceCode: return appLinkRedirect
        case .loopback(let port):
            guard port != 0 else { throw refused("connection.redirect_invalid") }
            return "http://127.0.0.1:\(port)/callback"
        case .loopbackV6(let port):
            guard port != 0 else { throw refused("connection.redirect_invalid") }
            return "http://[::1]:\(port)/callback"
        }
    }

    private static func checkName(_ name: String) throws {
        guard (1...80).contains(name.count), !name.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            throw refused("connection.malformed")
        }
    }

    private static func isID(_ text: String) -> Bool {
        text.utf8.count == 32 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func refused(_ code: String) -> MeshKernelError { KernelMapping.refusal(code) }
}
