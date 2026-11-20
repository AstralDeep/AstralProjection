// Shared helpers for the runtime tests: fixture lookup, a CPU-only configuration, synthetic audio and small concurrency probes.
// Every test file uses these so inference always runs on the committed tiny models without downloads.
import AstralVoiceRuntime
import Foundation
import XCTest

enum Fixtures {
    static func url(_ name: String) -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: "gguf", subdirectory: "Fixtures") else {
            fatalError("missing fixture \(name)")
        }
        return url
    }

    static let asr = url("tiny-asr")
    static let encoder = url("tiny-asr-mmproj")
    static let chat = url("tiny-chat")
    static let chatShort = url("tiny-chat-short")
}

let cpuConfiguration = RuntimeConfiguration(compute: .cpuOnly, contextTokens: 2048, batchTokens: 256, threads: 2)

func sine(seconds: Double, frequency: Double = 440) -> [Float] {
    (0..<Int(seconds * 16_000)).map { Float(0.4 * sin(2 * Double.pi * frequency * Double($0) / 16_000)) }
}

func loadRecognizer(scheduler: RuntimeScheduler = RuntimeScheduler()) async throws -> SpeechRecognizer {
    try await SpeechRecognizer.load(model: Fixtures.asr, audioEncoder: Fixtures.encoder, configuration: cpuConfiguration, scheduler: scheduler)
}

func loadGenerator(_ model: URL = Fixtures.chat, scheduler: RuntimeScheduler = RuntimeScheduler()) async throws -> TextGenerator {
    try await TextGenerator.load(model: model, configuration: RuntimeConfiguration(compute: .cpuOnly, contextTokens: 1024, batchTokens: 256, threads: 2), scheduler: scheduler)
}

actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

actor EventLog {
    private(set) var events: [String] = []
    func add(_ event: String) { events.append(event) }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var action: (() -> Void)?
    private var trigger = Int.max

    func fire(at count: Int, _ action: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        trigger = count
        self.action = action
    }

    func tick() {
        lock.lock()
        value += 1
        let pending = value == trigger ? action : nil
        lock.unlock()
        pending?()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

func waitUntil(_ condition: () async -> Bool) async {
    while !(await condition()) { await Task.yield() }
}

struct RealModels {
    let rumble: URL
    let encoder: URL
    let chat: URL
    let samples: [Float]
    let expectedWords: [String]

    static func fromEnvironment() throws -> RealModels {
        let env = ProcessInfo.processInfo.environment
        guard let directory = env["ASTRAL_VOICE_MODELS_DIR"], let wav = env["ASTRAL_VOICE_SAMPLE_WAV"], let text = env["ASTRAL_VOICE_SAMPLE_TEXT"] else {
            throw XCTSkip("Set ASTRAL_VOICE_MODELS_DIR, ASTRAL_VOICE_SAMPLE_WAV and ASTRAL_VOICE_SAMPLE_TEXT to run the real model tests.")
        }
        let root = URL(fileURLWithPath: directory)
        return RealModels(
            rumble: root.appendingPathComponent("rumble/Rumble-2-Flash-AD-Q5_K_M.gguf"),
            encoder: root.appendingPathComponent("rumble/mmproj-Rumble-2-Flash-Q8_0.gguf"),
            chat: root.appendingPathComponent("chat-1.2b/LFM2.5-1.2B-Instruct-Q4_K_M.gguf"),
            samples: try readWave16kMono(URL(fileURLWithPath: wav)),
            expectedWords: words(in: text)
        )
    }
}

func words(in text: String) -> [String] {
    text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
}

func readWave16kMono(_ url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    func u16(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 }
    func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
    guard data.count > 44, String(decoding: data[0..<4], as: UTF8.self) == "RIFF", String(decoding: data[8..<12], as: UTF8.self) == "WAVE" else {
        throw WaveError.notWave
    }
    var offset = 12
    var format: (channels: Int, rate: Int, bits: Int)?
    while offset + 8 <= data.count {
        let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
        let size = u32(offset + 4)
        let body = offset + 8
        if id == "fmt " {
            guard u16(body) == 1 else { throw WaveError.unsupported }
            format = (u16(body + 2), u32(body + 4), u16(body + 14))
        } else if id == "data" {
            guard let format, format.channels == 1, format.rate == 16_000, format.bits == 16 else { throw WaveError.unsupported }
            let end = min(body + size, data.count)
            return stride(from: body, to: end - 1, by: 2).map { Float(Int16(truncatingIfNeeded: u16($0))) / 32_768 }
        }
        offset = body + size + (size & 1)
    }
    throw WaveError.notWave
}

enum WaveError: Error {
    case notWave
    case unsupported
}
