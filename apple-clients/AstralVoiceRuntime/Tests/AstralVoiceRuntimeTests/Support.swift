// Shared helpers for the runtime tests: fixture lookup, a CPU-only configuration, synthetic audio and small concurrency probes.
// Every test file uses these so inference always runs on the committed tiny models without downloads.
import AstralVoiceRuntime
import Foundation

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
