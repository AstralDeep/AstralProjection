// Relays the open mesh to the paired Apple Watch: it sends the chat list and a watch-adapted chat and forwards the watch's send and stop into the normal turn path.
// The watch holds no credentials, so every packet passes the strict AstralCore codec, the owner must be the open mesh id, and consent, pairing and ticket packets are refused.

import AstralCore
import Foundation
import Observation

@MainActor
protocol PhoneCompanionHost: AnyObject {
    var companionMeshId: String? { get }
    var companionStopped: Bool { get }
    var chats: [MeshChatSummary] { get }
    func trackCompanionState()
    func companionChatView(chatId: String) async -> MeshChatView?
    func companionSend(chatId: String, text: String) async -> Bool
    func companionStop(chatId: String) async
    func companionRunState(chatId: String) -> CompanionRunState
}

extension MeshRuntime: PhoneCompanionHost {}

@MainActor
protocol CompanionRelayChannel: AnyObject {
    var onRelayRequest: (@MainActor @Sendable (Data) async -> Void)? { get set }
    var onRelayReady: (@MainActor @Sendable () -> Void)? { get set }
    func publish(_ update: Data, kind: String, latestState: Bool, completion: @escaping @MainActor (Bool) -> Void)
    func withdraw(kind: String)
}

extension CompanionPhoneUpdate {
    var wireKind: String {
        switch self {
        case .chats: return "chats"
        case .chat: return "chat"
        case .run: return "run"
        case .phone: return "phone"
        }
    }
}

struct WatchContextStore {
    static let keys = ["chats": "companion.chats", "phone": "companion.phone"]
    private var values: [String: Any] = [:]
    private(set) var dirty = false

    var snapshot: [String: Any] { values }

    mutating func setEndpoint(_ endpoint: String) {
        values[AstralConfig.serverOverrideDefaultsKey] = endpoint
        dirty = true
    }

    @discardableResult
    mutating func set(kind: String, data: Data) -> Bool {
        guard let key = Self.keys[kind] else { return false }
        values[key] = data
        dirty = true
        return true
    }

    mutating func remove(kind: String) {
        guard let key = Self.keys[kind], values.removeValue(forKey: key) != nil else { return }
        dirty = true
    }

    mutating func markFlushed() { dirty = false }
}

enum WatchInbound {
    case voice(CompanionVoicePacket)
    case relay(Data)

    static func classify(_ data: Data) -> WatchInbound {
        if let packet = try? CompanionVoicePacket(data: data) { return .voice(packet) }
        return .relay(data)
    }
}

enum PhoneCompanionOutcome: Equatable, Sendable {
    case served
    case failed
    case refused(CompanionRelayError)
    case noMesh
    case stopped
    case wrongOwner
}

nonisolated enum WatchChatText {
    static let placeholder = "Open on your iPhone to see this."
    private static let speakers: [MeshAuthor: String] = [.owner: "You", .assistant: "Astral"]
    private static let textKeys = ["title", "label", "text", "content"]
    private static let shareable: Set<String> = ["public", "private"]
    private static let maximumDepth = 16

    static func make(_ view: MeshChatView) -> String {
        let rendered = Dictionary(view.rendered.map { ($0.surfaceId, $0) }, uniquingKeysWith: { first, _ in first })
        let path = MeshChatTree.path(to: MeshChatTree.defaultHead(of: view.messages), in: view.messages)
        var blocks: [[String]] = []
        for message in path {
            var lines: [String] = []
            if shareable.contains(message.confidentiality) {
                if let speaker = speakers[message.author] {
                    let text = clean(message.text, maximumBytes: CompanionRelay.maximumViewBytes)
                    if !text.isEmpty { lines.append("\(speaker): \(text)") }
                }
                for id in message.surfaceIds {
                    guard let surface = rendered[id] else { continue }
                    if surface.untrusted || message.confidentiality != "public" || message.integrity == "untrusted" {
                        lines.append(placeholder)
                    } else {
                        for node in surface.tree { collect(node, depth: 0, into: &lines) }
                    }
                }
            } else if speakers[message.author] != nil {
                lines.append(placeholder)
            }
            if !lines.isEmpty { blocks.append(lines) }
        }
        return fit(blocks)
    }

    static func title(_ text: String) -> String {
        let cleaned = clean(text, maximumBytes: CompanionRelay.maximumTitleBytes)
        return cleaned.isEmpty ? CompanionRelay.untitledChat : cleaned
    }

    static func clean(_ text: String, maximumBytes: Int) -> String {
        var used = 0
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let mapped: Unicode.Scalar = CharacterSet.controlCharacters.contains(scalar) ? " " : scalar
            let width = String(mapped).utf8.count
            guard used + width <= maximumBytes else { break }
            used += width
            out.append(mapped)
        }
        return String(out).trimmingCharacters(in: .whitespaces)
    }

    private static func fit(_ blocks: [[String]]) -> String {
        var kept: [String] = []
        var used = 0
        for block in blocks.reversed() {
            var lines: [String] = []
            for line in block where !(line == placeholder && lines.last == placeholder) { lines.append(line) }
            if lines.last == placeholder, let next = kept.last,
                next == placeholder || next.hasPrefix(placeholder + "\n")
            {
                lines.removeLast()
            }
            let joined = lines.joined(separator: "\n")
            guard !joined.isEmpty else { continue }
            let cost = joined.utf8.count + (kept.isEmpty ? 0 : 1)
            if used + cost > CompanionRelay.maximumViewBytes {
                if kept.isEmpty { kept.append(clean(joined, maximumBytes: CompanionRelay.maximumViewBytes)) }
                break
            }
            used += cost
            kept.append(joined)
        }
        let text = kept.reversed().joined(separator: "\n")
        return text.isEmpty ? "No messages yet." : text
    }

    private static func collect(_ value: JSONValue, depth: Int, into lines: inout [String]) {
        guard depth < maximumDepth else { return }
        switch value {
        case .object(let fields):
            for key in textKeys {
                guard let text = fields[key]?.stringValue else { continue }
                let cleaned = clean(text, maximumBytes: CompanionRelay.maximumViewBytes)
                if !cleaned.isEmpty { lines.append(cleaned) }
            }
            let nested = fields.keys.filter { !textKeys.contains($0) }.sorted { lhs, rhs in
                (lhs == "children" ? 0 : 1, lhs) < (rhs == "children" ? 0 : 1, rhs)
            }
            for key in nested { fields[key].map { collect($0, depth: depth + 1, into: &lines) } }
        case .array(let items):
            for item in items { collect(item, depth: depth + 1, into: &lines) }
        default:
            break
        }
    }
}

@MainActor
final class PhoneCompanionRelay {
    private let channel: any CompanionRelayChannel
    private weak var host: (any PhoneCompanionHost)?
    private var lastOwner: String?
    private var openChatId: String?
    private var engaged = false
    private var lastSent: [String: Data] = [:]
    private var generation = 0
    private var refreshing: Task<Void, Never>?

    init(channel: any CompanionRelayChannel) {
        self.channel = channel
        channel.onRelayRequest = { [weak self] data in _ = await self?.handle(data) }
        channel.onRelayReady = { [weak self] in
            self?.lastSent = [:]
            self?.scheduleRefresh()
        }
    }

    func bind(_ host: any PhoneCompanionHost) {
        generation += 1
        refreshing?.cancel()
        refreshing = nil
        self.host = host
        openChatId = nil
        engaged = false
        lastSent = [:]
        arm()
        scheduleRefresh()
    }

    func unbind() {
        generation += 1
        refreshing?.cancel()
        refreshing = nil
        host = nil
        openChatId = nil
        engaged = false
        withdrawChats()
        if let owner = lastOwner.flatMap(CompanionVoiceOwner.init(meshId:)) {
            deliver(.phone(owner: owner, state: .noMesh), latest: true, force: true)
        }
        lastSent = [:]
    }

    func handle(_ data: Data) async -> PhoneCompanionOutcome {
        let request: CompanionWatchRequest
        do { request = try CompanionWatchRequest(data: data) } catch {
            return .refused(error as? CompanionRelayError ?? .invalidPacket)
        }
        guard let host, let meshId = host.companionMeshId, let owner = CompanionVoiceOwner(meshId: meshId) else {
            withdrawChats()
            deliver(.phone(owner: request.owner, state: .noMesh), latest: true, force: true)
            return .noMesh
        }
        lastOwner = meshId
        guard request.owner == owner else {
            deliver(.phone(owner: owner, state: .ready), latest: true, force: true)
            return .wrongOwner
        }
        guard !host.companionStopped else {
            withdrawChats()
            deliver(.phone(owner: owner, state: .stopped), latest: true, force: true)
            return .stopped
        }
        engaged = true
        switch request {
        case .listChats:
            deliverChats(host, owner: owner, force: true)
            return .served
        case .openChat(_, let chatId):
            openChatId = chatId
            return await deliverChat(host, owner: owner, chatId: chatId, force: true) ? .served : .failed
        case .sendMessage(_, let chatId, let text):
            let sent = await host.companionSend(chatId: chatId, text: text)
            guard current(host, owner) else { return .wrongOwner }
            guard sent else {
                let state = host.companionRunState(chatId: chatId)
                deliver(.run(owner: owner, chatId: chatId, state: state == .idle ? .failed : state), force: true)
                return .failed
            }
            deliverRun(host, owner: owner, chatId: chatId, force: true)
            guard openChatId == chatId else { return .served }
            _ = await deliverChat(host, owner: owner, chatId: chatId, force: true)
            return .served
        case .stopRun(_, let chatId):
            await host.companionStop(chatId: chatId)
            guard current(host, owner) else { return .wrongOwner }
            deliverRun(host, owner: owner, chatId: chatId, force: true)
            return .served
        }
    }

    func refresh() async {
        guard let host else { return }
        guard let meshId = host.companionMeshId, let owner = CompanionVoiceOwner(meshId: meshId) else {
            withdrawChats()
            if let owner = lastOwner.flatMap(CompanionVoiceOwner.init(meshId:)) {
                deliver(.phone(owner: owner, state: .noMesh), latest: true)
            }
            return
        }
        lastOwner = meshId
        guard !host.companionStopped else {
            withdrawChats()
            deliver(.phone(owner: owner, state: .stopped), latest: true)
            return
        }
        deliver(.phone(owner: owner, state: .ready), latest: true)
        guard engaged else { return }
        deliverChats(host, owner: owner)
        if let chatId = openChatId {
            deliverRun(host, owner: owner, chatId: chatId)
            _ = await deliverChat(host, owner: owner, chatId: chatId)
        }
    }

    private func withdrawChats() {
        lastSent["chats"] = nil
        channel.withdraw(kind: "chats")
    }

    private func current(_ host: any PhoneCompanionHost, _ owner: CompanionVoiceOwner) -> Bool {
        self.host === host && host.companionMeshId == owner.meshId && !host.companionStopped
    }

    private func arm() {
        guard let host else { return }
        let token = generation
        withObservationTracking {
            host.trackCompanionState()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == token, self.host != nil else { return }
                self.scheduleRefresh()
                self.arm()
            }
        }
    }

    private func scheduleRefresh() {
        guard refreshing == nil else { return }
        refreshing = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.refreshing = nil
            await self.refresh()
        }
    }

    private func deliverChats(_ host: any PhoneCompanionHost, owner: CompanionVoiceOwner, force: Bool = false) {
        let rows = host.chats.map { CompanionChatSummary(chatId: $0.chatId, title: $0.title) }
        deliver(.chatList(owner: owner, chats: rows), latest: true, force: force)
    }

    private func deliverChat(
        _ host: any PhoneCompanionHost, owner: CompanionVoiceOwner, chatId: String, force: Bool = false
    ) async -> Bool {
        guard let view = await host.companionChatView(chatId: chatId), current(host, owner) else { return false }
        return deliver(
            .chat(
                owner: owner, chatId: chatId, title: WatchChatText.title(view.title), view: WatchChatText.make(view)),
            force: force)
    }

    private func deliverRun(
        _ host: any PhoneCompanionHost, owner: CompanionVoiceOwner, chatId: String, force: Bool = false
    ) {
        deliver(.run(owner: owner, chatId: chatId, state: host.companionRunState(chatId: chatId)), force: force)
    }

    @discardableResult
    private func deliver(_ update: CompanionPhoneUpdate, latest: Bool = false, force: Bool = false) -> Bool {
        guard let data = try? update.encoded() else { return false }
        let kind = update.wireKind
        if !force, lastSent[kind] == data { return true }
        channel.publish(data, kind: kind, latestState: latest) { [weak self] delivered in
            if delivered { self?.lastSent[kind] = data }
        }
        return true
    }
}
