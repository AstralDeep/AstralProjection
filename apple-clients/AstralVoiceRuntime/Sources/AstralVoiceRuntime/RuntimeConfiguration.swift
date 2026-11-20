// Settings shared by the recognizer and the text generator: where inference runs, how much context to reserve and how many threads to use.
// The simulator slice has no Metal, so tests and the simulator use cpuOnly, which also keeps the audio encoder off the GPU.
import Foundation

public struct RuntimeConfiguration: Sendable, Equatable {
    public enum Compute: Sendable, Equatable {
        case automatic
        case cpuOnly
    }

    public var compute: Compute
    public var contextTokens: Int
    public var batchTokens: Int
    public var threads: Int

    public init(compute: Compute = .automatic, contextTokens: Int = 2048, batchTokens: Int = 512, threads: Int = RuntimeConfiguration.defaultThreads) {
        self.compute = compute
        self.contextTokens = contextTokens
        self.batchTokens = batchTokens
        self.threads = threads
    }

    public static var defaultThreads: Int {
        max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 2))
    }

    func validate() throws {
        guard contextTokens >= 256 else { throw VoiceRuntimeError.invalidConfiguration("contextTokens must be at least 256") }
        guard batchTokens >= 1 else { throw VoiceRuntimeError.invalidConfiguration("batchTokens must be positive") }
        guard threads >= 1 else { throw VoiceRuntimeError.invalidConfiguration("threads must be positive") }
    }
}

public enum StopReason: Sendable, Equatable {
    case endOfSequence
    case tokenLimit
    case contextFull
}
