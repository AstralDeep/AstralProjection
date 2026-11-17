// Defines the strict JSON packets the iPhone and its Apple Watch exchange so the phone relays chats, runs and voice for a watch that holds no credentials.
// Each packet carries the phone's mesh id as owner and a closed key set; consent, pairing and ticket kinds are refused in both directions, so nothing that grants authority crosses.
// The phone builds updates from its kernel and applies requests through its normal turn gates, and CompanionVoice supplies the voice packets and the owner type.

import Foundation

public enum CompanionRelayError: Error, Equatable, Sendable {
    case invalidPacket
    case unknownKind
    case authorityRefused
}

public enum CompanionRelay {
    public static let maximumBytes = 8_192
    public static let maximumChats = 20
    public static let maximumMessageCharacters = 4_096
    public static let maximumViewBytes = 6_144

    static let authorityMarkers = ["consent", "pair", "ticket", "approv", "grant", "authoriz", "delegat"]

    static func decode(_ data: Data) throws -> (kind: String, object: [String: Any]) {
        guard data.count <= maximumBytes,
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let kind = object["kind"] as? String
        else { throw CompanionRelayError.invalidPacket }
        let lowered = kind.lowercased()
        if authorityMarkers.contains(where: lowered.contains) { throw CompanionRelayError.authorityRefused }
        return (kind, object)
    }

    static func owner(_ object: [String: Any]) throws -> CompanionVoiceOwner {
        guard let text = object["owner"] as? String, let owner = CompanionVoiceOwner(meshId: text) else {
            throw CompanionRelayError.invalidPacket
        }
        return owner
    }

    static func text(_ object: [String: Any], _ key: String, maximum: Int) throws -> String {
        guard let value = object[key] as? String, companionVoiceText(value, maximum: maximum) else {
            throw CompanionRelayError.invalidPacket
        }
        return value
    }

    static func require(_ object: [String: Any], keys: Set<String>) throws {
        guard Set(object.keys) == keys else { throw CompanionRelayError.invalidPacket }
    }

    static func seal(_ object: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= maximumBytes else { throw CompanionRelayError.invalidPacket }
        return data
    }
}

public struct CompanionChatSummary: Equatable, Sendable {
    public let chatId: String
    public let title: String

    public init(chatId: String, title: String) {
        self.chatId = chatId
        self.title = title
    }
}

public enum CompanionRunState: String, Equatable, Sendable {
    case idle, running, stopping, failed
}

public enum CompanionPhoneState: String, Equatable, Sendable {
    case ready
    case noMesh = "no_mesh"
    case stopped
}

public enum CompanionPhoneUpdate: Equatable, Sendable {
    case chats(owner: CompanionVoiceOwner, chats: [CompanionChatSummary])
    case chat(owner: CompanionVoiceOwner, chatId: String, title: String, view: String)
    case run(owner: CompanionVoiceOwner, chatId: String, state: CompanionRunState)
    case phone(owner: CompanionVoiceOwner, state: CompanionPhoneState)

    public init(data: Data) throws {
        let (kind, object) = try CompanionRelay.decode(data)
        let owner = try CompanionRelay.owner(object)
        switch kind {
        case "chats":
            try CompanionRelay.require(object, keys: ["kind", "owner", "chats"])
            guard let rows = object["chats"] as? [[String: Any]], rows.count <= CompanionRelay.maximumChats else {
                throw CompanionRelayError.invalidPacket
            }
            self = .chats(
                owner: owner,
                chats: try rows.map {
                    try CompanionRelay.require($0, keys: ["chat_id", "title"])
                    return CompanionChatSummary(
                        chatId: try CompanionRelay.text($0, "chat_id", maximum: 512),
                        title: try CompanionRelay.text($0, "title", maximum: 1_024))
                })
        case "chat":
            try CompanionRelay.require(object, keys: ["kind", "owner", "chat_id", "title", "view"])
            let view = try CompanionRelay.text(object, "view", maximum: CompanionRelay.maximumViewBytes)
            self = .chat(
                owner: owner, chatId: try CompanionRelay.text(object, "chat_id", maximum: 512),
                title: try CompanionRelay.text(object, "title", maximum: 1_024), view: view)
        case "run":
            try CompanionRelay.require(object, keys: ["kind", "owner", "chat_id", "state"])
            guard let raw = object["state"] as? String, let state = CompanionRunState(rawValue: raw) else {
                throw CompanionRelayError.invalidPacket
            }
            self = .run(owner: owner, chatId: try CompanionRelay.text(object, "chat_id", maximum: 512), state: state)
        case "phone":
            try CompanionRelay.require(object, keys: ["kind", "owner", "state"])
            guard let raw = object["state"] as? String, let state = CompanionPhoneState(rawValue: raw) else {
                throw CompanionRelayError.invalidPacket
            }
            self = .phone(owner: owner, state: state)
        default:
            throw CompanionRelayError.unknownKind
        }
    }

    public func encoded() throws -> Data {
        switch self {
        case .chats(let owner, let chats):
            guard chats.count <= CompanionRelay.maximumChats else { throw CompanionRelayError.invalidPacket }
            return try validated(
                ["kind": "chats", "owner": owner.meshId, "chats": chats.map { ["chat_id": $0.chatId, "title": $0.title] }])
        case .chat(let owner, let chatId, let title, let view):
            return try validated(
                ["kind": "chat", "owner": owner.meshId, "chat_id": chatId, "title": title, "view": view])
        case .run(let owner, let chatId, let state):
            return try validated(
                ["kind": "run", "owner": owner.meshId, "chat_id": chatId, "state": state.rawValue])
        case .phone(let owner, let state):
            return try validated(["kind": "phone", "owner": owner.meshId, "state": state.rawValue])
        }
    }

    private func validated(_ object: [String: Any]) throws -> Data {
        let data = try CompanionRelay.seal(object)
        guard (try? CompanionPhoneUpdate(data: data)) == self else { throw CompanionRelayError.invalidPacket }
        return data
    }
}

public enum CompanionWatchRequest: Equatable, Sendable {
    case listChats(owner: CompanionVoiceOwner)
    case openChat(owner: CompanionVoiceOwner, chatId: String)
    case sendMessage(owner: CompanionVoiceOwner, chatId: String, text: String)
    case stopRun(owner: CompanionVoiceOwner, chatId: String)

    public var owner: CompanionVoiceOwner {
        switch self {
        case .listChats(let owner), .openChat(let owner, _), .sendMessage(let owner, _, _), .stopRun(let owner, _):
            return owner
        }
    }

    public init(data: Data) throws {
        let (kind, object) = try CompanionRelay.decode(data)
        let owner = try CompanionRelay.owner(object)
        switch kind {
        case "list_chats":
            try CompanionRelay.require(object, keys: ["kind", "owner"])
            self = .listChats(owner: owner)
        case "open_chat":
            try CompanionRelay.require(object, keys: ["kind", "owner", "chat_id"])
            self = .openChat(owner: owner, chatId: try CompanionRelay.text(object, "chat_id", maximum: 512))
        case "send_message":
            try CompanionRelay.require(object, keys: ["kind", "owner", "chat_id", "text"])
            self = .sendMessage(
                owner: owner, chatId: try CompanionRelay.text(object, "chat_id", maximum: 512),
                text: try CompanionRelay.text(object, "text", maximum: CompanionRelay.maximumMessageCharacters))
        case "stop_run":
            try CompanionRelay.require(object, keys: ["kind", "owner", "chat_id"])
            self = .stopRun(owner: owner, chatId: try CompanionRelay.text(object, "chat_id", maximum: 512))
        default:
            throw CompanionRelayError.unknownKind
        }
    }

    public func encoded() throws -> Data {
        let object: [String: Any]
        switch self {
        case .listChats(let owner):
            object = ["kind": "list_chats", "owner": owner.meshId]
        case .openChat(let owner, let chatId):
            object = ["kind": "open_chat", "owner": owner.meshId, "chat_id": chatId]
        case .sendMessage(let owner, let chatId, let text):
            object = ["kind": "send_message", "owner": owner.meshId, "chat_id": chatId, "text": text]
        case .stopRun(let owner, let chatId):
            object = ["kind": "stop_run", "owner": owner.meshId, "chat_id": chatId]
        }
        let data = try CompanionRelay.seal(object)
        guard (try? CompanionWatchRequest(data: data)) == self else { throw CompanionRelayError.invalidPacket }
        return data
    }
}
