// Names the small engine seam PhononSpeech drives, so the speech logic can run against a fake engine in tests.
// FluidAudioPhononEngine is the only production conformance.
import Foundation

protocol PhononEngine: Sendable {
    var sampleRate: Int { get }
    func frames(for sentence: String) async throws -> AsyncThrowingStream<[Float], Error>
}
