// Sequences real keyboard and drag effects through an immutable observation check at each step.
// Platform adapters supply OS events; release carries no destination and only neutralizes held input.

import Foundation

public struct ComputerHostObservationIdentity: Sendable, Equatable {
    public let foreground: Int32?
    public let topology: String
    public let screenshot: Bool
    public init(foreground: Int32?, topology: String, screenshot: Bool) {
        self.foreground = foreground
        self.topology = topology
        self.screenshot = screenshot
    }
}

public enum ComputerHostObservationGate {
    public static func validate(
        expected: ComputerHostObservationIdentity, current: ComputerHostObservationIdentity, requireScreenshot: Bool
    ) throws {
        guard expected.foreground != nil, current.foreground == expected.foreground,
            !expected.topology.isEmpty, current.topology == expected.topology,
            !requireScreenshot || expected.screenshot
        else {
            throw ComputerHostError(
                "stale_target", "The desktop observation is missing or changed. Observe the target again.")
        }
    }
}

public enum ComputerHostPointerStep: Sendable, Equatable {
    case down(CGPoint)
    case drag(CGPoint)
    case release
}

public enum ComputerHostInputSequence {
    public static func type(
        _ text: String, authorize: @Sendable () throws -> Void,
        post: @Sendable ([UInt16], Bool) throws -> Void
    ) async throws {
        for chunk in ComputerHostText.keyboardChunks(text) {
            try Task.checkCancellation()
            try authorize()
            try post(chunk, true)
            try post([], false)
            await Task.yield()
        }
    }
    public static func drag(
        from start: CGPoint, to end: CGPoint, authorize: @Sendable () throws -> Void,
        post: @Sendable (ComputerHostPointerStep) throws -> Void,
        delay: @Sendable () async throws -> Void = { try await Task.sleep(nanoseconds: 10_000_000) }
    ) async throws {
        try Task.checkCancellation()
        try authorize()
        try post(.down(start))
        defer { try? post(.release) }
        for step in 1...20 {
            try Task.checkCancellation()
            try authorize()
            let fraction = Double(step) / 20
            try post(
                .drag(CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)))
            try await delay()
        }
    }
}
