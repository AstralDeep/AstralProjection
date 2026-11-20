// Shares test doubles: a scripted fake engine, a loopback listener that counts connection attempts, and a helper that builds placeholder model folders.
// The fakes live behind the internal PhononEngine seam so cancel timing can be tested without a model.
import FluidAudio
import Foundation
import Network
import XCTest

@testable import AstralVoiceSpeech

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return storage }
    func increment() { lock.lock(); storage += 1; lock.unlock() }
}

final class Gate: @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    init() { (stream, continuation) = AsyncStream.makeStream(of: Void.self) }
    func open() { continuation.yield(); continuation.finish() }
    func wait() async { for await _ in stream { return } }
}

enum FakeBehavior: Sendable {
    case frames([[Float]])
    case framesThenFail([[Float]])
    case holdUntilReleased
}

struct FakeFailure: Error {}

final class FakeEngine: PhononEngine, @unchecked Sendable {
    let sampleRate: Int
    let behavior: FakeBehavior
    let terminated = Counter()
    let release = Gate()

    init(sampleRate: Int = 24_000, behavior: FakeBehavior) {
        self.sampleRate = sampleRate
        self.behavior = behavior
    }

    func frames(for sentence: String) async throws -> AsyncThrowingStream<[Float], Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: [Float].self, throwing: Error.self)
        let terminated = terminated
        continuation.onTermination = { _ in terminated.increment() }
        switch behavior {
        case .frames(let frames):
            frames.forEach { continuation.yield($0) }
            continuation.finish()
        case .framesThenFail(let frames):
            frames.forEach { continuation.yield($0) }
            continuation.finish(throwing: FakeFailure())
        case .holdUntilReleased:
            let release = release
            Task {
                await release.wait()
                continuation.yield([0.1, 0.2])
            }
        }
        return stream
    }
}

func completeFolder(missing: String? = nil) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("phonon-\(UUID().uuidString)")
    for path in PhononModelFolder.requiredFiles where path != missing {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0]).write(to: url)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

func emptyFolder() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("phonon-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

final class LoopbackTripwire: @unchecked Sendable {
    private let listener: NWListener
    private let connections = Counter()
    private let previousBase: String
    private(set) var baseURL = ""

    var connectionCount: Int { connections.value }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        previousBase = ModelRegistry.baseURL
    }

    func start() async throws {
        let connections = connections
        listener.newConnectionHandler = { connection in
            connections.increment()
            connection.cancel()
        }
        let ready = Gate()
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.open() }
        }
        listener.start(queue: DispatchQueue(label: "tripwire"))
        await ready.wait()
        guard let port = listener.port else { throw FakeFailure() }
        baseURL = "http://127.0.0.1:\(port.rawValue)"
        ModelRegistry.baseURL = baseURL
    }

    func stop() {
        ModelRegistry.baseURL = previousBase
        listener.cancel()
    }
}
