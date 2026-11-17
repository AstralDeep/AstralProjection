// The contact list, invitations, comparison exchanges and shares behind InMemoryMeshKernel, with a hub that lets two in-memory kernels complete an exchange.
// It applies the real kernel's refusal codes and states, and the real kernel stays the authority on signatures, expiry and the roster rules.

import CryptoKit
import Foundation

nonisolated final class InMemoryContactHub: @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [String: InMemoryContacts] = [:]

    func register(_ book: InMemoryContacts) { lock.withLock { peers[book.meshId] = book } }

    func peer(_ mesh: String) -> InMemoryContacts? { lock.withLock { peers[mesh] } }
}

nonisolated final class InMemoryContacts: @unchecked Sendable {
    struct Hooks: Sendable {
        let consent: @Sendable () throws -> Void
        let emit: @Sendable (MeshKernelChange) -> Void
        let chat: @Sendable (String) throws -> MeshChatView
        let chatHoldsPhi: @Sendable (String) -> Bool
        let phiAllowed: @Sendable (String) -> Bool
        let removePhiDestination: @Sendable (String) -> Void
        let now: @Sendable () -> Date
    }

    private struct Invitation {
        let text: String
        let name: String
        let expires: Date
    }

    private struct Held {
        var contact: MeshContact
    }

    private struct Grant {
        var info: MeshShareInfo
    }

    private let lock = NSLock()
    private let hub: InMemoryContactHub
    private let hooks: Hooks
    let meshId: String
    private var ownName = "Me"
    private var invitation: Invitation?
    private var held: [String: Held] = [:]
    private var exchanges: [String: MeshContactExchange] = [:]
    private var proposals: [String: MeshShareProposal] = [:]
    private var grants: [String: Grant] = [:]
    private var received: [String: MeshSharedItem] = [:]
    private var receivedChats: [String: MeshChatView] = [:]
    private var attachments: [String: Data] = [:]
    private var counter = 0

    init(meshId: String, hub: InMemoryContactHub, hooks: Hooks) {
        self.meshId = meshId
        self.hub = hub
        self.hooks = hooks
        hub.register(self)
    }

    static func code(_ first: String, _ second: String) -> String {
        let pair = [first, second].sorted().joined(separator: "|")
        let bytes = Array(SHA256.hash(data: Data(pair.utf8)).prefix(8))
        let value = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } % 1_000_000_000_000
        let text = String(format: "%012llu", value)
        return [text.prefix(4), text.dropFirst(4).prefix(4), text.suffix(4)].map(String.init).joined(separator: " ")
    }

    func createInvitation(name: String, ttl: UInt64) throws -> MeshContactInvitation {
        try lock.withLock {
            let now = hooks.now()
            if let open = invitation, open.expires > now {
                throw KernelMapping.refusal("contact.invitation_open")
            }
            guard ttl >= 1, ttl <= 86_400 else { throw KernelMapping.refusal("contact.invite_lifetime") }
            ownName = name
            let expires = now.addingTimeInterval(Double(ttl))
            let body: [String: Any] = [
                "mesh": meshId, "name": name, "expires_s": Int(expires.timeIntervalSince1970), "v": 1,
            ]
            let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
            let payload = Self.base64URL(data)
            let text = "astral-contact:v1:" + payload
            invitation = Invitation(text: text, name: name, expires: expires)
            return MeshContactInvitation(
                text: text, link: "https://astraldeep.github.io/contact/#" + payload, expiresInSeconds: ttl)
        }
    }

    func cancelInvitation() { lock.withLock { invitation = nil } }

    func accept(text: String, name: String) throws -> MeshContactExchange {
        let body = try Self.decode(text)
        guard let mesh = body["mesh"] as? String, let theirName = body["name"] as? String,
            let expires = body["expires_s"] as? Int
        else { throw KernelMapping.refusal("contact.invite_malformed") }
        guard mesh != meshId else { throw KernelMapping.refusal("contact.self") }
        guard Double(expires) > hooks.now().timeIntervalSince1970 else {
            throw KernelMapping.refusal("contact.invite_expired")
        }
        guard let peer = hub.peer(mesh), peer.isOpen(text) else { throw KernelMapping.refusal("contact.unreachable") }
        let id = nextId("exchange")
        let code = Self.code(meshId, mesh)
        let mine = MeshContactExchange(id: id, mesh: mesh, name: theirName, code: code, codeQR: code, devices: 1)
        lock.withLock {
            ownName = name
            if held[mesh] == nil { held[mesh] = Held(contact: Self.unverified(mesh: mesh, name: theirName)) }
            exchanges[id] = mine
        }
        peer.receiveAcceptance(from: meshId, name: name, code: code)
        hooks.emit(.contactsChanged)
        return mine
    }

    fileprivate func isOpen(_ text: String) -> Bool {
        lock.withLock { invitation?.text == text && (invitation?.expires ?? .distantPast) > hooks.now() }
    }

    fileprivate func receiveAcceptance(from mesh: String, name: String, code: String) {
        let id = nextId("exchange")
        lock.withLock {
            invitation = nil
            if held[mesh] == nil { held[mesh] = Held(contact: Self.unverified(mesh: mesh, name: name)) }
            exchanges[id] = MeshContactExchange(id: id, mesh: mesh, name: name, code: code, codeQR: code, devices: 1)
        }
        hooks.emit(.contactsChanged)
    }

    func startVerification(mesh: String) throws -> MeshContactExchange {
        let name = try lock.withLock { () -> String in
            guard let found = held[mesh] else { throw KernelMapping.refusal("contact.unverified") }
            return found.contact.name
        }
        guard hub.peer(mesh) != nil else { throw KernelMapping.refusal("contact.unreachable") }
        let id = nextId("exchange")
        let code = Self.code(meshId, mesh)
        let mine = MeshContactExchange(id: id, mesh: mesh, name: name, code: code, codeQR: code, devices: 1)
        lock.withLock {
            exchanges = exchanges.filter { $0.value.mesh != mesh }
            exchanges[id] = mine
        }
        hub.peer(mesh)?.receiveAcceptance(from: meshId, name: ownName, code: code)
        return mine
    }

    func pending() -> [MeshContactExchange] { lock.withLock { exchanges.values.sorted { $0.id < $1.id } } }

    func verify(exchangeId: String) throws -> MeshContact {
        let exchange = try lock.withLock { () -> MeshContactExchange in
            guard let found = exchanges[exchangeId] else { throw KernelMapping.refusal("contact.exchange_unknown") }
            return found
        }
        try hooks.consent()
        let verified = lock.withLock { () -> MeshContact in
            let current = held[exchange.mesh]?.contact ?? Self.unverified(mesh: exchange.mesh, name: exchange.name)
            let next = MeshContact(
                mesh: current.mesh, name: current.name, state: .verified, fingerprint: current.fingerprint,
                devices: current.devices, notices: current.notices, reason: nil)
            held[exchange.mesh] = Held(contact: next)
            exchanges[exchangeId] = nil
            return next
        }
        hooks.emit(.contactsChanged)
        return verified
    }

    func reject(exchangeId: String) throws {
        try lock.withLock {
            guard exchanges.removeValue(forKey: exchangeId) != nil else {
                throw KernelMapping.refusal("contact.exchange_unknown")
            }
        }
        hooks.emit(.contactsChanged)
    }

    func contacts() -> [MeshContact] { lock.withLock { held.values.map(\.contact).sorted { $0.name < $1.name } } }

    func remove(mesh: String) throws {
        let live = try lock.withLock { () -> [String] in
            guard held.removeValue(forKey: mesh) != nil else { throw KernelMapping.refusal("contact.unverified") }
            exchanges = exchanges.filter { $0.value.mesh != mesh }
            return grants.values.filter { $0.info.contact == mesh }.map(\.info.id)
        }
        for id in live { endGrant(id) }
        lock.withLock {
            received = received.filter { $0.value.contact != mesh }
            receivedChats = receivedChats.filter { received[$0.key] != nil }
        }
        hooks.removePhiDestination(mesh)
        hooks.emit(.contactsChanged)
        hooks.emit(.sharesChanged)
    }

    func isVerified(_ mesh: String) -> Bool { lock.withLock { held[mesh]?.contact.isVerified == true } }

    func verifiedMeshes() -> Set<String> {
        lock.withLock { Set(held.values.filter { $0.contact.isVerified }.map(\.contact.mesh)) }
    }

    func seedNotice(mesh: String, notice: MeshContactNotice) {
        lock.withLock {
            guard var entry = held[mesh] else { return }
            let current = entry.contact
            entry = Held(
                contact: MeshContact(
                    mesh: current.mesh, name: current.name, state: current.state, fingerprint: current.fingerprint,
                    devices: current.devices, notices: current.notices + [notice], reason: current.reason))
            held[mesh] = entry
        }
        hooks.emit(.contactsChanged)
    }

    func downgrade(mesh: String) {
        lock.withLock {
            guard let current = held[mesh]?.contact else { return }
            held[mesh] = Held(
                contact: MeshContact(
                    mesh: current.mesh, name: current.name, state: .unverified, fingerprint: current.fingerprint,
                    devices: current.devices, notices: current.notices, reason: "contact.roster_rejected"))
        }
        hooks.emit(.contactsChanged)
        hooks.emit(.sharesChanged)
    }

    func proposeShare(chat: String, contact: String) throws -> MeshShareProposal {
        let proposal = try evaluate(id: nextId("grant"), chat: chat, contact: contact)
        lock.withLock { proposals[proposal.id] = proposal }
        return proposal
    }

    private func evaluate(id: String, chat: String, contact: String) throws -> MeshShareProposal {
        let view = try hooks.chat(chat)
        let found = lock.withLock { held[contact]?.contact }
        let verified = found?.isVerified == true
        let phiNeeded = hooks.chatHoldsPhi(chat)
        let destination = hooks.phiAllowed(contact)
        let existing = lock.withLock {
            grants.values.first { $0.info.chat == chat && $0.info.contact == contact && $0.info.state != .revoked }
        }
        let upgrade = existing.flatMap { $0.info.phi == false && phiNeeded ? $0 : nil }
        let refusal: String?
        if !verified {
            refusal = "contact.unverified"
        } else if existing != nil && upgrade == nil {
            refusal = "share.exists"
        } else if phiNeeded && !destination {
            refusal = "share.phi_not_destination"
        } else {
            refusal = nil
        }
        return MeshShareProposal(
            id: id, chat: chat, title: view.title, contact: contact, contactName: found?.name ?? "",
            verified: verified, labels: view.labels, phiNeeded: phiNeeded, phiDestination: destination,
            supersedes: upgrade?.info.id, refusal: refusal)
    }

    func approveShare(_ proposal: MeshShareProposal) throws -> MeshShareInfo {
        let open = try lock.withLock { () -> MeshShareProposal in
            guard let found = proposals.removeValue(forKey: proposal.id) else {
                throw KernelMapping.refusal("share.proposal_unknown")
            }
            return found
        }
        guard open == proposal else { throw KernelMapping.refusal("share.changed") }
        let current = try evaluate(id: open.id, chat: open.chat, contact: open.contact)
        if let code = current.refusal { throw KernelMapping.refusal(code) }
        guard current == open else { throw KernelMapping.refusal("share.changed") }
        try hooks.consent()
        if let old = open.supersedes { endGrant(old) }
        let view = try hooks.chat(open.chat)
        let info = MeshShareInfo(
            id: open.id, chat: open.chat, title: open.title, contact: open.contact, contactName: open.contactName,
            phi: open.phiNeeded, phiWithheld: false, state: hub.peer(open.contact) == nil ? .waiting : .inEffect)
        lock.withLock { grants[info.id] = Grant(info: info) }
        hub.peer(open.contact)?.receiveGrant(from: meshId, info: info, view: view)
        hooks.emit(.sharesChanged)
        return info
    }

    private func nextId(_ kind: String) -> String {
        lock.withLock {
            counter += 1
            let seed = Data((meshId + kind + String(counter)).utf8)
            return SHA256.hash(data: seed).prefix(16).map { String(format: "%02x", $0) }.joined()
        }
    }

    func revoke(id: String) throws {
        guard lock.withLock({ grants[id]?.info.state != nil && grants[id]?.info.state != .revoked }) else {
            throw KernelMapping.refusal("share.grant_unknown")
        }
        endGrant(id)
        hooks.emit(.sharesChanged)
    }

    private func endGrant(_ id: String) {
        let contact = lock.withLock { () -> String? in
            guard let grant = grants[id] else { return nil }
            grants[id] = Grant(info: grant.info.revoked())
            return grant.info.contact
        }
        if let contact { hub.peer(contact)?.receiveRevocation(grant: id) }
    }

    func shares() -> [MeshShareInfo] {
        lock.withLock { grants.values.map(\.info).filter { $0.state != .revoked }.sorted { $0.id < $1.id } }
    }

    fileprivate func receiveGrant(from mesh: String, info: MeshShareInfo, view: MeshChatView) {
        lock.withLock {
            let name = held[mesh]?.contact.name ?? ""
            received[info.id] = MeshSharedItem(
                grant: info.id, contact: mesh, contactName: name, chat: info.chat, title: info.title, phi: info.phi,
                withheldPhi: 0, withheldFields: 0, withheldKeys: 0, state: .ready, events: view.messages.count,
                updatedAt: hooks.now())
            receivedChats[info.id] = view
        }
        hooks.emit(.sharesChanged)
    }

    fileprivate func receiveRevocation(grant: String) {
        lock.withLock {
            guard let item = received[grant] else { return }
            received[grant] = MeshSharedItem(
                grant: grant, contact: item.contact, contactName: item.contactName, chat: "", title: item.title,
                phi: false, withheldPhi: 0, withheldFields: 0, withheldKeys: 0, state: .stopped, events: 0,
                updatedAt: hooks.now())
            receivedChats[grant] = nil
        }
        hooks.emit(.sharesChanged)
    }

    func sharedWithMe() -> [MeshSharedItem] {
        lock.withLock {
            received.values.map { item in
                guard item.state != .stopped, held[item.contact]?.contact.isVerified != true else { return item }
                return MeshSharedItem(
                    grant: item.grant, contact: item.contact, contactName: item.contactName, chat: item.chat,
                    title: item.title, phi: item.phi, withheldPhi: item.withheldPhi,
                    withheldFields: item.withheldFields, withheldKeys: item.withheldKeys, state: .needsVerification,
                    events: item.events, updatedAt: item.updatedAt)
            }
            .sorted { $0.grant < $1.grant }
        }
    }

    func sharedChat(grant: String) throws -> MeshChatView {
        try lock.withLock {
            guard let item = received[grant], item.state != .stopped, let view = receivedChats[grant],
                held[item.contact]?.contact.isVerified == true
            else { throw KernelMapping.refusal("share.grant_unknown") }
            return view
        }
    }

    func refresh(grant: String) throws -> MeshRefreshReport {
        let item = try lock.withLock { () -> MeshSharedItem in
            guard let found = received[grant] else { throw KernelMapping.refusal("share.grant_unknown") }
            return found
        }
        guard isVerified(item.contact) else { throw KernelMapping.refusal("contact.unverified") }
        guard item.state != .stopped else { return MeshRefreshReport(received: 0, refused: 0, stopped: [grant]) }
        guard let owner = hub.peer(item.contact), let view = owner.currentSnapshot(grant: grant) else {
            return MeshRefreshReport(received: 0, refused: 0, stopped: [grant])
        }
        lock.withLock { receivedChats[grant] = view }
        hooks.emit(.sharesChanged)
        return MeshRefreshReport(received: view.messages.count, refused: 0, stopped: [])
    }

    func refresh(contact: String) throws -> MeshRefreshReport {
        guard isVerified(contact) else { throw KernelMapping.refusal("contact.unverified") }
        let ids = lock.withLock { received.values.filter { $0.contact == contact }.map(\.grant) }
        var total = MeshRefreshReport(received: 0, refused: 0, stopped: [])
        for id in ids {
            let one = try refresh(grant: id)
            total = MeshRefreshReport(
                received: total.received + one.received, refused: total.refused + one.refused,
                stopped: total.stopped + one.stopped)
        }
        return total
    }

    fileprivate func currentSnapshot(grant: String) -> MeshChatView? {
        guard let live = lock.withLock({ grants[grant] }), live.info.state != .revoked else { return nil }
        return try? hooks.chat(live.info.chat)
    }

    func seedAttachment(grant: String, event: String, bytes: Data) {
        lock.withLock { attachments[grant + "/" + event] = bytes }
    }

    func attachment(grant: String, event: String) throws -> Data {
        try lock.withLock {
            guard let item = received[grant], item.state == .ready, held[item.contact]?.contact.isVerified == true
            else { throw KernelMapping.refusal("share.grant_unknown") }
            guard let bytes = attachments[grant + "/" + event] else { throw KernelMapping.refusal("share.key_unknown") }
            return bytes
        }
    }

    private static func unverified(mesh: String, name: String) -> MeshContact {
        MeshContact(
            mesh: mesh, name: name, state: .unverified, fingerprint: ConsentPrompt.fingerprint(mesh), devices: 1,
            notices: [], reason: nil)
    }

    private static func decode(_ text: String) throws -> [String: Any] {
        let prefix = "astral-contact:v1:"
        guard text.hasPrefix(prefix) else { throw KernelMapping.refusal("contact.invite_malformed") }
        var payload = String(text.dropFirst(prefix.count)).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw KernelMapping.refusal("contact.invite_malformed") }
        return body
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
