// Runs the Phonon 31m English model through FluidAudio's small Pocket TTS manager, loaded only from a folder the app supplies.
// It switches FluidAudio's offline mode on before any load and never calls the manager's initialize or any other downloading API.
import FluidAudio
import Foundation

@available(iOS 18.0, macOS 15.0, *)
final class FluidAudioPhononEngine: PhononEngine {
    let sampleRate = PocketTtsConstants.audioSampleRate
    private let manager: PocketTtsSmallManager

    private init(manager: PocketTtsSmallManager) {
        self.manager = manager
    }

    static func load(from folder: URL) async throws -> FluidAudioPhononEngine {
        ModelHub.offlineMode = true
        guard ModelHub.offlineMode else {
            throw SpeechSynthesisError.loadFailed("Offline mode could not be enforced.")
        }
        let manager = PocketTtsSmallManager(model: .phonon31m)
        try await manager.load(from: folder)
        return FluidAudioPhononEngine(manager: manager)
    }

    func frames(for sentence: String) async throws -> AsyncThrowingStream<[Float], Error> {
        let session = try await manager.makeSession()
        session.enqueue(sentence)
        session.finish()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await frame in session.frames {
                        continuation.yield(frame.samples)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                await session.cancel()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
