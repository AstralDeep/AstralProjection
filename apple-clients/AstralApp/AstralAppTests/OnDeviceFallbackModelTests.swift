// Checks Foundation Models preference and verified local text fallback without loading real weights.
// Controlled inference gates exercise shared loading, cancellation and asset retirement.

@testable import AstralDeep
import Foundation
import XCTest

final class OnDeviceFallbackModelTests: XCTestCase {
    private let request = OnDeviceRequest(
        messages: [.init(role: .user, text: "What is two plus two?")], schemaJSON: nil, maxTokens: 80)
    private let directory = URL(fileURLWithPath: "/verified/model")

    func testRealVerifiedTextFallbackWhenExplicitlyRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["ASTRAL_VERIFIED_MODEL_TEST_ROOT"] else {
            throw XCTSkip(
                "Set ASTRAL_VERIFIED_MODEL_TEST_ROOT to a verified installed model root for this local hardware check.")
        }
        let assets = InstalledVoiceModel(root: URL(fileURLWithPath: path))
        XCTAssertTrue(assets.available())
        let fallback = VerifiedLFM3OnDeviceModel(
            cache: .shared, installed: { assets.available() }, verifiedDirectory: { await assets.verifiedDirectory() })
        let preferred = FallbackModelFixture(available: false, response: .unavailable(.deviceNotEligible))
        let model = PreferredOnDeviceModel(preferred: preferred, fallback: fallback)
        let result = await model.complete(request)
        guard case .text(let answer) = result else {
            return XCTFail("Expected a plain local answer, received \(result)")
        }
        XCTAssertTrue(answer.contains("4") || answer.lowercased().contains("four"))
        XCTAssertEqual(preferred.callCount, 0)
        let structured = await model.complete(.init(messages: request.messages, schemaJSON: "{}", maxTokens: 80))
        XCTAssertEqual(structured, .failed(.schemaUnsupported))
        await VoiceInferenceCache.shared.retire()
    }

    func testFoundationModelsRemainPreferredIncludingRefusals() async {
        let preferred = FallbackModelFixture(available: true, response: .refused("declined"))
        let fallback = FallbackModelFixture(available: true, response: .text("four"))
        let model = PreferredOnDeviceModel(preferred: preferred, fallback: fallback)
        XCTAssertTrue(model.available())
        let answer = await model.complete(request)
        XCTAssertEqual(answer, .refused("declined"))
        XCTAssertEqual(preferred.callCount, 1)
        XCTAssertEqual(fallback.callCount, 0)
    }

    func testIneligibleFoundationModelsUseOnlyTheInstalledFallback() async {
        let preferred = FallbackModelFixture(available: false, response: .unavailable(.deviceNotEligible))
        let fallback = FallbackModelFixture(available: true, response: .text("four"))
        let model = PreferredOnDeviceModel(preferred: preferred, fallback: fallback)
        let answer = await model.complete(request)
        XCTAssertEqual(answer, .text("four"))
        XCTAssertEqual(preferred.callCount, 0)
        XCTAssertEqual(fallback.callCount, 1)
        XCTAssertFalse(PreferredOnDeviceModel(preferred: preferred, fallback: preferred).available())
    }

    func testTextFallbackRejectsSchemasEmptyHistoryAndOversizedContextBeforeLoading() async {
        let loader = FallbackInferenceFixture()
        let cache = VoiceInferenceCache(makeInference: { _ in
            await loader.loaded()
            return loader
        })
        let model = VerifiedLFM3OnDeviceModel(cache: cache, installed: { true }, verifiedDirectory: { self.directory })
        let structured = await model.complete(.init(messages: request.messages, schemaJSON: "{}", maxTokens: 80))
        let empty = await model.complete(.init(messages: [], schemaJSON: nil, maxTokens: 80))
        let oversized = await model.complete(
            .init(
                messages: [.init(role: .user, text: String(repeating: "x", count: 65_537))], schemaJSON: nil,
                maxTokens: 80))
        XCTAssertEqual(structured, .failed(.schemaUnsupported))
        XCTAssertEqual(empty, .failed(.emptyRequest))
        XCTAssertEqual(oversized, .failed(.contextTooLarge))
        let loads = await loader.loads
        XCTAssertEqual(loads, 0)
    }

    func testMissingOrCorruptAssetsNeverLoadInference() async {
        let loader = FallbackInferenceFixture()
        let cache = VoiceInferenceCache(makeInference: { _ in
            await loader.loaded()
            return loader
        })
        let missing = VerifiedLFM3OnDeviceModel(
            cache: cache, installed: { false }, verifiedDirectory: { self.directory })
        let corrupt = VerifiedLFM3OnDeviceModel(cache: cache, installed: { true }, verifiedDirectory: { nil })
        XCTAssertFalse(missing.available())
        let first = await missing.complete(request)
        let second = await corrupt.complete(request)
        XCTAssertEqual(first, .unavailable(.modelNotReady))
        XCTAssertEqual(second, .unavailable(.modelNotReady))
        let loads = await loader.loads
        XCTAssertEqual(loads, 0)
    }

    func testConcurrentTextAndVoiceConsumersShareOneLazyLoad() async throws {
        let loader = FallbackInferenceFixture()
        let gate = FallbackGate()
        let cache = VoiceInferenceCache(makeInference: { _ in
            await loader.loaded()
            await gate.wait()
            return loader
        })
        let model = VerifiedLFM3OnDeviceModel(cache: cache, installed: { true }, verifiedDirectory: { self.directory })
        let first = Task { await model.complete(self.request) }
        await loader.waitForLoad()
        let voice = Task { try await cache.inference(directory: self.directory) }
        let second = Task { await model.complete(self.request) }
        await gate.release()
        let responses = await [first.value, second.value]
        _ = try await voice.value
        XCTAssertEqual(responses, [.text("four"), .text("four")])
        let loads = await loader.loads
        XCTAssertEqual(loads, 1)
    }

    func testCancelledTextDoesNotRetireAnotherConsumerOrReturnItsAnswer() async throws {
        let loader = FallbackInferenceFixture()
        let gate = FallbackGate()
        let cache = VoiceInferenceCache(makeInference: { _ in
            await loader.loaded()
            await gate.wait()
            return loader
        })
        let model = VerifiedLFM3OnDeviceModel(cache: cache, installed: { true }, verifiedDirectory: { self.directory })
        let cancelled = Task { await model.complete(self.request) }
        await loader.waitForLoad()
        let retained = Task { try await cache.inference(directory: self.directory) }
        cancelled.cancel()
        await gate.release()
        let response = await cancelled.value
        _ = try await retained.value
        XCTAssertEqual(response, .failed(.cancelled))
        let loads = await loader.loads
        XCTAssertEqual(loads, 1)
    }

    func testRetirementFencesAnAnswerFromTheDeletedModel() async {
        let loader = FallbackInferenceFixture()
        await loader.holdAnswer()
        let cache = VoiceInferenceCache(makeInference: { _ in
            await loader.loaded()
            return loader
        })
        let model = VerifiedLFM3OnDeviceModel(cache: cache, installed: { true }, verifiedDirectory: { self.directory })
        let pending = Task { await model.complete(self.request) }
        await loader.waitForAnswer()
        await cache.retire()
        await loader.releaseAnswer()
        let response = await pending.value
        XCTAssertEqual(response, .failed(.cancelled))
        let replacement = await model.complete(request)
        XCTAssertEqual(replacement, .text("four"))
        let loads = await loader.loads
        XCTAssertEqual(loads, 2)
    }

    func testDeletionBlocksARequestThatVerifiedBeforeItsCacheLease() async {
        let loader = FallbackInferenceFixture()
        let gate = FallbackGate()
        let cache = VoiceInferenceCache(makeInference: { _ in
            await loader.loaded()
            return loader
        })
        let model = VerifiedLFM3OnDeviceModel(
            cache: cache, installed: { true },
            verifiedDirectory: {
                await gate.wait()
                return self.directory
            })
        let pending = Task { await model.complete(self.request) }
        await gate.waitUntilEntered()
        await cache.beginDeletion()
        await cache.beginDeletion()
        await gate.release()
        let duringDeletion = await pending.value
        XCTAssertEqual(duringDeletion, .failed(.cancelled))
        await cache.endDeletion()
        let stillDeleting = await model.complete(request)
        XCTAssertEqual(stillDeleting, .failed(.cancelled))
        let deniedLoads = await loader.loads
        XCTAssertEqual(deniedLoads, 0)
        await cache.endDeletion()
        let reinstalled = await model.complete(request)
        XCTAssertEqual(reinstalled, .text("four"))
        let loads = await loader.loads
        XCTAssertEqual(loads, 1)
    }

    func testLoadingFailureIsHonestAndTheNextRequestCanRetry() async {
        let loader = FallbackInferenceFixture()
        let cache = VoiceInferenceCache(makeInference: { _ in
            await loader.loaded()
            if await loader.loads == 1 { throw CocoaError(.fileReadCorruptFile) }
            return loader
        })
        let model = VerifiedLFM3OnDeviceModel(cache: cache, installed: { true }, verifiedDirectory: { self.directory })
        let first = await model.complete(request)
        let second = await model.complete(request)
        XCTAssertEqual(first, .failed(.generationFailed))
        XCTAssertEqual(second, .text("four"))
    }

    @MainActor
    func testInstalledAssetsRequireFreshDigestVerificationAndARealEligibleDevice() async throws {
        let fixture = try await VoiceModelTestFixture.installed()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try XCTUnwrap(fixture.controller.store)
        let device = VoiceDeviceProfile(
            platform: .phone, isAppleSilicon: true, isSimulator: false, physicalMemoryBytes: 6_000_000_000)
        let assets = InstalledVoiceModel(manifest: store.manifest, root: fixture.root, device: device)
        XCTAssertTrue(assets.available())
        let verified = await assets.verifiedDirectory()
        XCTAssertEqual(verified, store.installedDirectory)
        try Data("y".utf8).write(to: try XCTUnwrap(verified).appendingPathComponent(store.manifest.files[0].path))
        let corrupt = await assets.verifiedDirectory()
        XCTAssertNil(corrupt)
        let simulator = InstalledVoiceModel(
            manifest: store.manifest, root: fixture.root,
            device: .init(platform: .phone, isAppleSilicon: true, isSimulator: true, physicalMemoryBytes: 16 << 30))
        XCTAssertFalse(simulator.available())
        let unsupported = await simulator.verifiedDirectory()
        XCTAssertNil(unsupported)
    }

    func testTokenBudgetIsBoundedAndCancellationFencesAnActiveAnswer() async {
        let loader = FallbackInferenceFixture()
        await loader.holdAnswer()
        let cache = VoiceInferenceCache(makeInference: { _ in
            await loader.loaded()
            return loader
        })
        let model = VerifiedLFM3OnDeviceModel(cache: cache, installed: { true }, verifiedDirectory: { self.directory })
        let pending = Task {
            await model.complete(.init(messages: self.request.messages, schemaJSON: nil, maxTokens: 100_000))
        }
        await loader.waitForAnswer()
        pending.cancel()
        await loader.releaseAnswer()
        let response = await pending.value
        XCTAssertEqual(response, .failed(.cancelled))
        let tokens = await loader.lastTokens
        XCTAssertEqual(tokens, 2_048)
    }
}

private nonisolated final class FallbackModelFixture: AstralOnDeviceModel, @unchecked Sendable {
    private let lock = NSLock()
    private let installed: Bool
    private let response: OnDeviceResponse
    private var calls = 0
    var callCount: Int { lock.withLock { calls } }
    init(available: Bool, response: OnDeviceResponse) {
        installed = available
        self.response = response
    }
    func available() -> Bool { installed }
    func complete(_ request: OnDeviceRequest) async -> OnDeviceResponse {
        lock.withLock { calls += 1 }
        return response
    }
}

private actor FallbackGate {
    private var open = false
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var entered = false
    private var observer: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        observer?.resume()
        observer = nil
        if open { return }
        await withCheckedContinuation { pending.append($0) }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() {
        open = true
        let values = pending
        pending.removeAll()
        values.forEach { $0.resume() }
    }
}

private actor FallbackInferenceFixture: VoiceModelInference {
    private(set) var loads = 0
    private(set) var lastTokens = 0
    private var didLoad: CheckedContinuation<Void, Never>?
    private var didAnswer: CheckedContinuation<Void, Never>?
    private var answering = false
    private var held = false
    private let answerGate = FallbackGate()
    func loaded() {
        loads += 1
        didLoad?.resume()
        didLoad = nil
    }
    func waitForLoad() async {
        if loads > 0 { return }
        await withCheckedContinuation { didLoad = $0 }
    }
    func holdAnswer() { held = true }
    func waitForAnswer() async {
        if answering { return }
        await withCheckedContinuation { didAnswer = $0 }
    }
    func releaseAnswer() async { await answerGate.release() }
    func acknowledgement(_ request: OnDeviceRequest) async throws -> String {
        lastTokens = request.maxTokens
        answering = true
        didAnswer?.resume()
        didAnswer = nil
        if held { await answerGate.wait() }
        return "four"
    }
    func transcribe(_ audio: [Float], onText: @escaping @Sendable (String) -> Void) async throws -> String { "" }
    func synthesize(_ text: String, onAudio: @escaping @Sendable ([Float]) -> Void) async throws {}
}
