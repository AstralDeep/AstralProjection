// Speaks one English sentence at a time with the Phonon 31m model, streaming de-essed 24 kHz mono buffers as the model produces them.
// It loads only from the folder the app supplies, reports unavailable below iOS 18 and macOS 15, and conforms to SpeechSynthesizer.
import Foundation

public actor PhononSpeech: SpeechSynthesizer {
    public nonisolated let availability: SpeechAvailability

    private let makeEngine: @Sendable (URL) async throws -> any PhononEngine
    private var engine: (any PhononEngine)?
    private var loading = false
    private var current: Task<Void, Never>?

    public init() {
        self.init(availability: Self.platformAvailability, makeEngine: Self.liveEngine)
    }

    init(
        availability: SpeechAvailability,
        makeEngine: @escaping @Sendable (URL) async throws -> any PhononEngine
    ) {
        self.availability = availability
        self.makeEngine = makeEngine
    }

    public var isLoaded: Bool { engine != nil }

    public func load(from folder: URL) async throws {
        if case .unavailable(let reason) = availability {
            throw SpeechSynthesisError.unavailable(reason)
        }
        guard !loading else { throw SpeechSynthesisError.loadInProgress }
        let missing = PhononModelFolder.missingFiles(in: folder)
        guard missing.isEmpty else { throw SpeechSynthesisError.modelFolderIncomplete(missing: missing) }
        loading = true
        defer { loading = false }
        await unload()
        do {
            engine = try await makeEngine(folder)
        } catch let error as SpeechSynthesisError {
            throw error
        } catch {
            throw SpeechSynthesisError.loadFailed("\(error)")
        }
    }

    public func synthesize(sentence: String) async throws -> AsyncThrowingStream<SpeechAudioBuffer, Error> {
        guard engine != nil else { throw SpeechSynthesisError.notLoaded }
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SpeechSynthesisError.emptySentence }
        await cancelCurrent()
        guard let engine else { throw SpeechSynthesisError.notLoaded }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: SpeechAudioBuffer.self, throwing: Error.self)
        let task = Task { await Self.pump(engine: engine, sentence: text, into: continuation) }
        continuation.onTermination = { _ in task.cancel() }
        current = task
        return stream
    }

    public func cancel() async {
        await cancelCurrent()
    }

    public func unload() async {
        await cancelCurrent()
        engine = nil
    }

    private func cancelCurrent() async {
        while let running = current {
            current = nil
            running.cancel()
            await running.value
        }
    }

    @concurrent
    private static func pump(
        engine: any PhononEngine,
        sentence: String,
        into continuation: AsyncThrowingStream<SpeechAudioBuffer, Error>.Continuation
    ) async {
        var filter = TtsPostFilter(sampleRate: Float(engine.sampleRate))
        do {
            let frames = try await engine.frames(for: sentence)
            for try await raw in frames {
                if Task.isCancelled { break }
                var samples = raw
                filter.process(&samples)
                for index in samples.indices {
                    samples[index] = min(1, max(-1, samples[index]))
                }
                if samples.isEmpty { continue }
                continuation.yield(SpeechAudioBuffer(samples: samples, sampleRate: engine.sampleRate))
            }
            if Task.isCancelled {
                continuation.finish(throwing: SpeechSynthesisError.cancelled)
            } else {
                continuation.finish()
            }
        } catch {
            if Task.isCancelled || error is CancellationError {
                continuation.finish(throwing: SpeechSynthesisError.cancelled)
            } else {
                continuation.finish(throwing: SpeechSynthesisError.synthesisFailed("\(error)"))
            }
        }
    }

    private static var platformAvailability: SpeechAvailability {
        if #available(iOS 18.0, macOS 15.0, *) {
            return .available
        }
        #if os(macOS)
        return .unavailable(.operatingSystemTooOld(required: "macOS 15"))
        #else
        return .unavailable(.operatingSystemTooOld(required: "iOS 18"))
        #endif
    }

    @Sendable
    private static func liveEngine(folder: URL) async throws -> any PhononEngine {
        if #available(iOS 18.0, macOS 15.0, *) {
            return try await FluidAudioPhononEngine.load(from: folder)
        }
        throw SpeechSynthesisError.unavailable(.operatingSystemTooOld(required: "iOS 18 or macOS 15"))
    }
}
