// Fakes for the on-device voice tests: a manual clock, scripted audio, transcriber, kernel link and model.
// They let pipeline, barge-in and fast-path logic run deterministically with no microphone, speaker or system model.

import AVFoundation
import AstralCore
import Foundation
import XCTest

@testable import AstralDeep

final class ManualVoiceClock: VoiceClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 100

    var now: TimeInterval { lock.withLock { value } }

    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

@MainActor
final class FakeDuplexAudio: VoiceDuplexAudio {
    var onEvent: ((VoiceSpeechEvent) -> Void)?
    var onMicrophone: ((AVAudioPCMBuffer) -> Void)?
    var onVoiceActivity: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    var spoken: [(index: Int, text: String)] = []
    var volumes: [Float] = []
    var stopSpeakingCount = 0
    var started = false
    var stopped = false
    var progress: VoiceSpeechProgress?
    var startError: VoiceDuplexError?

    func start() throws {
        if let startError { throw startError }
        started = true
    }
    func stop() { stopped = true }
    func speak(index: Int, text: String) { spoken.append((index, text)) }
    func stopSpeaking() { stopSpeakingCount += 1 }
    func setVolume(_ volume: Float) { volumes.append(volume) }
    func playedProgress() -> VoiceSpeechProgress? { progress }
}

final class FakeTranscriber: VoiceStreamingTranscriber, @unchecked Sendable {
    let kind = VoiceTranscriberKind.onDeviceRecognizer
    private let lock = NSLock()
    private(set) var begun = 0
    private(set) var ended = 0
    private(set) var shutdowns = 0
    private(set) var appendedFrames = 0
    private(set) var partialFlushes = 0

    func setEventHandler(_ handler: @escaping @Sendable (VoiceRecognizerEvent) -> Void) {}
    func prepare() async throws {}
    func beginSegment() throws { lock.withLock { begun += 1 } }
    func append(_ buffer: AVAudioPCMBuffer) { lock.withLock { appendedFrames += Int(buffer.frameLength) } }
    func flushPartial() { lock.withLock { partialFlushes += 1 } }
    func endSegment() { lock.withLock { ended += 1 } }
    func cancelSegment() {}
    func shutdown() { lock.withLock { shutdowns += 1 } }
}

final class FakeKernelLink: VoiceKernelLink {
    var preparationError: Error?
    private(set) var preparations = 0
    func prepareForOwnerSession() async throws {
        preparations += 1
        if let preparationError { throw preparationError }
    }
    var turns: [OwnerVoiceTurn] = []
    var cancelledTurns = 0
    var cancelledTools: [String] = []
    var spoken: [VoiceSpokenRecord] = []

    func submit(turn: OwnerVoiceTurn) { turns.append(turn) }
    func cancelTurn() { cancelledTurns += 1 }
    func cancelTool(id: String) { cancelledTools.append(id) }
    func record(spoken record: VoiceSpokenRecord) { spoken.append(record) }
}

nonisolated enum FakeOnDeviceResponses {
    static func response(_ response: OnDeviceResponse, to request: OnDeviceRequest) -> OnDeviceResponse {
        guard case .text(let text) = response, let schema = request.schemaJSON,
            let value = try? JSONDecoder().decode(JSONValue.self, from: Data(schema.utf8)),
            let outer = value.objectValue,
            Set(outer.keys).subtracting(["x-astral-tool-proposals"]) == [
                "type", "properties", "required", "additionalProperties",
            ],
            outer["type"] == .string("object"), outer["additionalProperties"] == .bool(false),
            required(outer["required"], is: ["text", "calls"]), let properties = outer["properties"]?.objectValue,
            Set(properties.keys) == ["text", "calls"], let textSchema = properties["text"]?.objectValue,
            Set(textSchema.keys) == ["type"], textSchema["type"] == .string("string"),
            let calls = properties["calls"]?.objectValue,
            Set(calls.keys) == ["type", "minItems", "maxItems", "items"],
            calls["type"] == .string("array"), calls["minItems"] == .number(0), calls["maxItems"] == .number(64),
            let item = calls["items"]?.objectValue,
            Set(item.keys) == ["type", "properties", "required", "additionalProperties"],
            item["type"] == .string("object"),
            item["additionalProperties"] == .bool(false), required(item["required"], is: ["tool", "arguments_json"]),
            let fields = item["properties"]?.objectValue, Set(fields.keys) == ["tool", "arguments_json"],
            let tool = fields["tool"]?.objectValue, Set(tool.keys) == ["type", "enum"],
            tool["type"] == .string("string"),
            let names = tool["enum"]?.arrayValue, !names.isEmpty,
            names.allSatisfy({ $0.stringValue.map { !$0.isEmpty } == true }),
            Set(names.compactMap(\.stringValue)).count == names.count,
            let arguments = fields["arguments_json"]?.objectValue, Set(arguments.keys) == ["type"],
            arguments["type"] == .string("string")
        else { return response }
        if outer["x-astral-tool-proposals"] != nil {
            guard let catalog = try? OnDeviceToolCatalog(schemaJSON: schema),
                Set(catalog.tools.map(\.name)) == Set(names.compactMap(\.stringValue))
            else { return response }
        }
        let answer = JSONValue.object(["text": .string(text), "calls": .array([])])
        guard let data = try? JSONEncoder().encode(answer) else { return .failed(.generationFailed) }
        return .json(String(decoding: data, as: UTF8.self))
    }

    private static func required(_ value: JSONValue?, is expected: Set<String>) -> Bool {
        guard let values = value?.arrayValue, values.count == expected.count else { return false }
        return Set(values.compactMap(\.stringValue)) == expected
    }
}

final class FakeOnDeviceModel: AstralOnDeviceModel, @unchecked Sendable {
    enum Mode {
        case respond(OnDeviceResponse)
        case hang
    }

    private let lock = NSLock()
    private var isUp: Bool
    private var mode: Mode
    private var requestLog: [OnDeviceRequest] = []
    private var cancellations = 0

    init(available: Bool = true, mode: Mode = .respond(.text("Sure."))) {
        isUp = available
        self.mode = mode
    }

    var requests: [OnDeviceRequest] { lock.withLock { requestLog } }
    var cancellationCount: Int { lock.withLock { cancellations } }

    func available() -> Bool { lock.withLock { isUp } }

    func complete(_ request: OnDeviceRequest) async -> OnDeviceResponse {
        let current = lock.withLock { () -> Mode in
            requestLog.append(request)
            return mode
        }
        switch current {
        case .respond(let response):
            return FakeOnDeviceResponses.response(response, to: request)
        case .hang:
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            lock.withLock { cancellations += 1 }
            return .failed(.cancelled)
        }
    }
}

@MainActor
func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
