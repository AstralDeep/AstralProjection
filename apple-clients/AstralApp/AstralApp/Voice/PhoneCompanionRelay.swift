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
    func publish(_ update: Data, latestState: Bool)
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
    private static let speakers: [MeshAuthor: String] = [.owner: "You", .assistant: "Astral"]
    private static let surfaceKeys: Set<String> = ["text", "content", "title", "label"]
    private static let maximumDepth = 16

    static func make(_ view: MeshChatView) -> String {
        var lines: [String] = []
        for message in view.messages.sorted(by: { ($0.createdAt, $0.eventId) < ($1.createdAt, $1.eventId) }) {
            guard let speaker = speakers[message.author] else { continue }
            let text = clean(message.text, maximumBytes: CompanionRelay.maximumViewBytes)
            if !text.isEmpty { lines.append("\(speaker): \(text)") }
        }
        for surface in view.rendered where !surface.untrusted {
            for node in surface.tree { collect(node, depth: 0, into: &lines) }
        }
        let joined = tail(lines.joined(separator: "\n"), maximumBytes: CompanionRelay.maximumViewBytes)
        return joined.isEmpty ? "No messages yet." : joined
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

    private static func tail(_ text: String, maximumBytes: Int) -> String {
        var used = 0
        var kept: [Unicode.Scalar] = []
        for scalar in text.unicodeScalars.reversed() {
            let width = String(scalar).utf8.count
            guard used + width <= maximumBytes else { break }
            used += width
            kept.append(scalar)
        }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: kept.reversed())
        return String(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func collect(_ value: JSONValue, depth: Int, into lines: inout [String]) {
        guard depth < maximumDepth else { return }
        switch value {
        case .object(let fields):
            for key in fields.keys.sorted() {
                guard let nested = fields[key] else { continue }
                if surfaceKeys.contains(key), let text = nested.stringValue {
                    let cleaned = clean(text, maximumBytes: CompanionRelay.maximumViewBytes)
                    if !cleaned.isEmpty { lines.append(cleaned) }
                } else {
                    collect(nested, depth: depth + 1, into: &lines)
                }
            }
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
        if let owner = lastOwner.flatMap(CompanionVoiceOwner.init(meshId:)) {
            deliver(.phone(owner: owner, state: .noMesh), key: "phone", latest: true)
        }
        lastSent = [:]
    }

    func handle(_ data: Data) async -> PhoneCompanionOutcome {
        let request: CompanionWatchRequest
        do { request = try CompanionWatchRequest(data: data) } catch {
            return .refused(error as? CompanionRelayError ?? .invalidPacket)
        }
        guard let host, let meshId = host.companionMeshId, let owner = CompanionVoiceOwner(meshId: meshId) else {
            deliver(.phone(owner: request.owner, state: .noMesh), key: "phone", latest: true, force: true)
            return .noMesh
        }
        lastOwner = meshId
        guard request.owner == owner else {
            deliver(.phone(owner: owner, state: .ready), key: "phone", latest: true, force: true)
            return .wrongOwner
        }
        guard !host.companionStopped else {
            deliver(.phone(owner: owner, state: .stopped), key: "phone", latest: true, force: true)
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
            guard await host.companionSend(chatId: chatId, text: text) else {
                deliverRun(host, owner: owner, chatId: chatId, force: true)
                return .failed
            }
            openChatId = chatId
            deliverRun(host, owner: owner, chatId: chatId, force: true)
            _ = await deliverChat(host, owner: owner, chatId: chatId, force: true)
            return .served
        case .stopRun(_, let chatId):
            await host.companionStop(chatId: chatId)
            deliverRun(host, owner: owner, chatId: chatId, force: true)
            return .served
        }
    }

    func refresh() async {
        guard let host else { return }
        guard let meshId = host.companionMeshId, let owner = CompanionVoiceOwner(meshId: meshId) else {
            if let owner = lastOwner.flatMap(CompanionVoiceOwner.init(meshId:)) {
                deliver(.phone(owner: owner, state: .noMesh), key: "phone", latest: true)
            }
            return
        }
        lastOwner = meshId
        guard !host.companionStopped else {
            deliver(.phone(owner: owner, state: .stopped), key: "phone", latest: true)
            return
        }
        deliver(.phone(owner: owner, state: .ready), key: "phone", latest: true)
        guard engaged else { return }
        deliverChats(host, owner: owner)
        if let chatId = openChatId {
            deliverRun(host, owner: owner, chatId: chatId)
            _ = await deliverChat(host, owner: owner, chatId: chatId)
        }
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
        deliver(.chatList(owner: owner, chats: rows), key: "chats", latest: true, force: force)
    }

    private func deliverChat(
        _ host: any PhoneCompanionHost, owner: CompanionVoiceOwner, chatId: String, force: Bool = false
    ) async -> Bool {
        guard let view = await host.companionChatView(chatId: chatId) else { return false }
        return deliver(
            .chat(
                owner: owner, chatId: chatId, title: WatchChatText.title(view.title), view: WatchChatText.make(view)),
            key: "chat", latest: false, force: force)
    }

    private func deliverRun(
        _ host: any PhoneCompanionHost, owner: CompanionVoiceOwner, chatId: String, force: Bool = false
    ) {
        deliver(
            .run(owner: owner, chatId: chatId, state: host.companionRunState(chatId: chatId)),
            key: "run", latest: false, force: force)
    }

    @discardableResult
    private func deliver(_ update: CompanionPhoneUpdate, key: String, latest: Bool, force: Bool = false) -> Bool {
        guard let data = try? update.encoded() else { return false }
        if !force, lastSent[key] == data { return true }
        lastSent[key] = data
        channel.publish(data, latestState: latest)
        return true
    }
}
