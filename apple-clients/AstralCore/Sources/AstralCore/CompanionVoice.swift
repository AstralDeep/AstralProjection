// Defines bounded ephemeral audio and control packets for the paired Watch and phone.
// WatchConnectivity supplies peer identity; owner metadata is compared with the phone's verified principal and never grants approval authority.

import CoreFoundation
import Foundation

public enum CompanionVoiceError: Error, Equatable, Sendable {
    case invalidPacket
    case invalidSequence
    case notReachable
    case rejected
}

public struct CompanionVoicePacket: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        case start = 1
        case ready, capture, speechStart, speechPCM, playbackStarted, playbackFinished
        case partialTranscript, finalTranscript, stop, ack, failure, stopSpeech, volume
    }

    public static let headerBytes = 40
    public static let maximumPayloadBytes = 8_192
    public static let maximumMicroseconds: UInt64 = 3_600_000_000
    public let kind: Kind
    public let session: UUID
    public let sequence: UInt64
    public let microseconds: UInt64
    public let payload: Data

    public init(kind: Kind, session: UUID, sequence: UInt64, microseconds: UInt64, payload: Data = Data()) throws {
        guard microseconds <= Self.maximumMicroseconds, Self.valid(payload, for: kind) else {
            throw CompanionVoiceError.invalidPacket
        }
        self.kind = kind
        self.session = session
        self.sequence = sequence
        self.microseconds = microseconds
        self.payload = payload
    }

    public init(data: Data) throws {
        let data = Data([UInt8](data))
        guard data.count >= Self.headerBytes, data.count <= Self.headerBytes + Self.maximumPayloadBytes,
            Array(data.prefix(4)) == [65, 86, 67, 49], data[5] == 0,
            let kind = Kind(rawValue: data[4])
        else { throw CompanionVoiceError.invalidPacket }
        let count = Int(data[6]) * 256 + Int(data[7])
        guard count == data.count - Self.headerBytes else { throw CompanionVoiceError.invalidPacket }
        let session = data.subdata(in: 8..<24).withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
        try self.init(
            kind: kind, session: session, sequence: Self.uint64(data, at: 24),
            microseconds: Self.uint64(data, at: 32), payload: data.subdata(in: Self.headerBytes..<data.count))
    }

    public var encoded: Data {
        var data = Data([65, 86, 67, 49, kind.rawValue, 0, UInt8(payload.count >> 8), UInt8(payload.count & 255)])
        var uuid = session.uuid
        withUnsafeBytes(of: &uuid) { data.append(contentsOf: $0) }
        for value in [sequence, microseconds] {
            data.append(contentsOf: (0..<8).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        data.append(payload)
        return data
    }

    private static func uint64(_ data: Data, at offset: Int) -> UInt64 {
        data[offset..<(offset + 8)].reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private static func valid(_ payload: Data, for kind: Kind) -> Bool {
        guard payload.count <= maximumPayloadBytes else { return false }
        switch kind {
        case .capture: return !payload.isEmpty && payload.count <= 3_200 && payload.count.isMultiple(of: 2)
        case .speechPCM: return !payload.isEmpty && payload.count <= 4_800 && payload.count.isMultiple(of: 2)
        case .ack, .stop: return payload.isEmpty
        case .volume:
            return payload.count == 37 && payload.last! <= 100
                && UUID(uuidString: String(decoding: payload.prefix(36), as: UTF8.self)) != nil
        case .playbackStarted, .playbackFinished, .stopSpeech:
            guard let text = String(data: payload, encoding: .utf8) else { return false }
            return text.count == 36 && UUID(uuidString: text) != nil
        default: return !payload.isEmpty && String(data: payload, encoding: .utf8) != nil
        }
    }
}

public struct CompanionVoiceSequenceGate: Sendable {
    private let session: UUID
    private var expected: UInt64 = 0
    private var lastMicroseconds: UInt64 = 0
    private var exhausted = false

    public init(session: UUID) { self.session = session }

    public mutating func accept(_ packet: CompanionVoicePacket) -> Bool {
        guard !exhausted, packet.session == session, packet.sequence == expected,
            packet.microseconds >= lastMicroseconds
        else { return false }
        lastMicroseconds = packet.microseconds
        if expected == UInt64.max { exhausted = true } else { expected += 1 }
        return true
    }
}

public struct CompanionVoiceOwner: Equatable, Sendable {
    public let issuer: String
    public let subject: String

    public init?(issuer: String, subject: String) {
        guard companionVoiceText(issuer, maximum: 2_048), companionVoiceText(subject, maximum: 2_048) else {
            return nil
        }
        self.issuer = issuer
        self.subject = subject
    }
}

public struct CompanionVoiceActivation: Equatable, Sendable {
    public enum Mode: String, Sendable { case conversation, playback }
    public let owner: CompanionVoiceOwner
    public let mode: Mode
    public let text: String?

    public init(owner: CompanionVoiceOwner, mode: Mode, text: String? = nil) {
        self.owner = owner
        self.mode = mode
        self.text = text
    }

    public init?(data: Data) {
        guard let object = companionVoiceObject(data), let rawOwner = object["owner"] as? [String: Any],
            Set(rawOwner.keys) == ["issuer", "subject"], let issuer = rawOwner["issuer"] as? String,
            let subject = rawOwner["subject"] as? String,
            let owner = CompanionVoiceOwner(issuer: issuer, subject: subject),
            let rawMode = object["mode"] as? String, let mode = Mode(rawValue: rawMode),
            Set(object.keys) == (mode == .conversation ? ["owner", "mode"] : ["owner", "mode", "text"])
        else { return nil }
        let text = object["text"] as? String
        guard mode == .conversation || text.map({ companionVoiceText($0, maximum: 8_192) }) == true else { return nil }
        self.init(owner: owner, mode: mode, text: text)
    }

    public func encoded() throws -> Data {
        guard mode == .conversation ? text == nil : text.map({ companionVoiceText($0, maximum: 8_192) }) == true
        else { throw CompanionVoiceError.invalidPacket }
        var object: [String: Any] = [
            "owner": ["issuer": owner.issuer, "subject": owner.subject], "mode": mode.rawValue,
        ]
        if let text { object["text"] = text }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

public struct CompanionVoiceConversation: Equatable, Sendable {
    public let chatId: String
    public let title: String

    public init(chatId: String, title: String) {
        self.chatId = chatId
        self.title = title
    }

    public init?(data: Data) {
        guard let object = companionVoiceObject(data), Set(object.keys) == ["chat_id", "title"],
            let chat = object["chat_id"] as? String, companionVoiceText(chat, maximum: 512),
            let title = object["title"] as? String, companionVoiceText(title, maximum: 1_024)
        else { return nil }
        self.init(chatId: chat, title: title)
    }

    public func encoded() throws -> Data {
        guard companionVoiceText(chatId, maximum: 512), companionVoiceText(title, maximum: 1_024)
        else { throw CompanionVoiceError.invalidPacket }
        return try JSONSerialization.data(withJSONObject: ["chat_id": chatId, "title": title], options: [.sortedKeys])
    }
}

public struct CompanionVoiceSpeech: Equatable, Sendable {
    public let id: UUID
    public let index: Int
    public let text: String
    public let frames: Int

    public init(id: UUID, index: Int, text: String, frames: Int) {
        self.id = id
        self.index = index
        self.text = text
        self.frames = frames
    }

    public init?(data: Data) {
        guard let object = companionVoiceObject(data), Set(object.keys) == ["id", "index", "text", "frames"],
            let idText = object["id"] as? String, let id = UUID(uuidString: idText),
            let index = companionVoiceInteger(object["index"], range: -1...1_000_000),
            let frames = companionVoiceInteger(object["frames"], range: 1...2_880_000),
            let text = object["text"] as? String, companionVoiceText(text, maximum: 8_192),
            (-1...1_000_000).contains(index), (1...2_880_000).contains(frames)
        else { return nil }
        self.init(id: id, index: index, text: text, frames: frames)
    }

    public func encoded() throws -> Data {
        guard companionVoiceText(text, maximum: 8_192), (-1...1_000_000).contains(index),
            (1...2_880_000).contains(frames)
        else { throw CompanionVoiceError.invalidPacket }
        return try JSONSerialization.data(
            withJSONObject: ["id": id.uuidString, "index": index, "text": text, "frames": frames],
            options: [.sortedKeys])
    }
}

@MainActor
public protocol CompanionVoiceChannel: AnyObject {
    var reachable: Bool { get }
    var onPacket: (@MainActor @Sendable (CompanionVoicePacket) async throws -> Void)? { get set }
    var onReachabilityChanged: (@MainActor @Sendable (Bool) -> Void)? { get set }
    func send(_ packet: CompanionVoicePacket) async throws
}

@MainActor
public final class CompanionVoiceSender {
    private let channel: any CompanionVoiceChannel
    private let session: UUID
    private let started = ContinuousClock.now
    private var sequence: UInt64 = 0
    private var pending = 0
    private var retired = false
    private var tail: Task<Void, Error>?

    public init(channel: any CompanionVoiceChannel, session: UUID) {
        self.channel = channel
        self.session = session
    }

    public func send(_ kind: CompanionVoicePacket.Kind, payload: Data = Data()) async throws {
        guard !retired, channel.reachable, pending < 8 else { throw CompanionVoiceError.notReachable }
        pending += 1
        let previous = tail
        let task = Task { [weak self] in
            try await previous?.value
            try Task.checkCancellation()
            guard let self, !self.retired, self.channel.reachable, self.sequence < UInt64.max
            else { throw CompanionVoiceError.notReachable }
            let elapsed = self.started.duration(to: .now).components
            guard elapsed.seconds >= 0, elapsed.seconds <= 3_600 else { throw CompanionVoiceError.invalidPacket }
            let microseconds =
                UInt64(elapsed.seconds) * 1_000_000 + UInt64(max(0, elapsed.attoseconds) / 1_000_000_000_000)
            let packet = try CompanionVoicePacket(
                kind: kind, session: self.session, sequence: self.sequence,
                microseconds: microseconds, payload: payload)
            self.sequence += 1
            try await self.channel.send(packet)
        }
        tail = task
        defer { pending -= 1 }
        try await task.value
    }

    public func retire() {
        retired = true
        tail?.cancel()
        tail = nil
    }
}

private func companionVoiceObject(_ data: Data) -> [String: Any]? {
    guard data.count <= CompanionVoicePacket.maximumPayloadBytes else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func companionVoiceText(_ value: String, maximum: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= maximum
        && !value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t"
        }
}

private func companionVoiceInteger(_ value: Any?, range: ClosedRange<Int>) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
        number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
        number.doubleValue >= Double(range.lowerBound), number.doubleValue <= Double(range.upperBound)
    else { return nil }
    return number.intValue
}
