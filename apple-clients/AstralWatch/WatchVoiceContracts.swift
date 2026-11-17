// Watch-local PCM framing and the voice state and permission vocabularies shared by WatchModel and WatchVoiceBridge.
// The frame codec is the ADVC header the phone relay shares for paired audio; nothing here reaches a server.

import Foundation

enum WatchVoicePermission: String, Equatable, Sendable {
    case notDetermined = "not_determined"
    case authorized
    case denied
    case restricted
}

enum WatchVoiceState: String, Equatable, Sendable {
    case off
    case unavailable
    case connecting
    case greeting
    case listening
    case speechDetected = "speech_detected"
    case transcribing
    case acknowledging
    case processing
    case waitingOnUser = "waiting_on_user"
    case speakingProgress = "speaking_progress"
    case speakingResult = "speaking_result"
    case muted
    case suspended
    case reconnecting
    case error
    case ended

    var active: Bool {
        switch self {
        case .connecting, .greeting, .listening, .speechDetected, .transcribing,
            .acknowledging, .processing, .waitingOnUser, .speakingProgress,
            .speakingResult, .muted, .reconnecting:
            return true
        case .off, .unavailable, .suspended, .error, .ended:
            return false
        }
    }

}

struct WatchVoicePCMFrame: Equatable, Sendable {
    static let headerLength = 26
    static let capturePayloadLength = 640
    static let assistantPayloadLength = 960

    enum Kind: UInt8, Equatable, Sendable {
        case microphone = 1
        case assistant = 2

        var payloadLength: Int {
            self == .microphone
                ? WatchVoicePCMFrame.capturePayloadLength
                : WatchVoicePCMFrame.assistantPayloadLength
        }
    }

    let kind: Kind
    let sequence: UInt64
    let timestampMicroseconds: UInt64
    let payload: Data

    init?(data: Data) {
        guard data.count >= Self.headerLength,
            data.prefix(4) == Data([0x41, 0x44, 0x56, 0x43]),
            data[4] == 1,
            let kind = Kind(rawValue: data[5]),
            data[6] == 0, data[7] == 0
        else { return nil }
        let sequence = data.watchVoiceUInt64(at: 8)
        let timestamp = data.watchVoiceUInt64(at: 16)
        let length = Int(data.watchVoiceUInt16(at: 24))
        guard length == kind.payloadLength, data.count == Self.headerLength + length else {
            return nil
        }
        self.kind = kind
        self.sequence = sequence
        timestampMicroseconds = timestamp
        payload = data.subdata(in: Self.headerLength..<data.count)
    }

    init?(kind: Kind, sequence: UInt64, timestampMicroseconds: UInt64, payload: Data) {
        guard payload.count == kind.payloadLength else { return nil }
        self.kind = kind
        self.sequence = sequence
        self.timestampMicroseconds = timestampMicroseconds
        self.payload = payload
    }

    var encoded: Data {
        var data = Data(capacity: Self.headerLength + payload.count)
        data.append(contentsOf: [0x41, 0x44, 0x56, 0x43, 1, kind.rawValue, 0, 0])
        data.watchVoiceAppendBigEndian(sequence)
        data.watchVoiceAppendBigEndian(timestampMicroseconds)
        data.watchVoiceAppendBigEndian(UInt16(payload.count))
        data.append(payload)
        return data
    }
}

struct WatchVoicePCMSequenceGate: Sendable {
    private(set) var last: [WatchVoicePCMFrame.Kind: UInt64] = [:]

    mutating func accept(_ frame: WatchVoicePCMFrame) -> Bool {
        if let prior = last[frame.kind], prior == UInt64.max || frame.sequence != prior + 1 {
            return false
        }
        last[frame.kind] = frame.sequence
        return true
    }

    mutating func reset() { last.removeAll() }
}

extension Data {
    fileprivate func watchVoiceUInt64(at offset: Int) -> UInt64 {
        var result: UInt64 = 0
        for byte in self[offset..<(offset + 8)] { result = (result << 8) | UInt64(byte) }
        return result
    }

    fileprivate func watchVoiceUInt16(at offset: Int) -> UInt16 {
        (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    fileprivate mutating func watchVoiceAppendBigEndian(_ value: UInt64) {
        append(contentsOf: (0..<8).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    fileprivate mutating func watchVoiceAppendBigEndian(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}
