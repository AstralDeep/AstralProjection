// Holds the ProcessInfo activity that keeps a signed-in client's socket and keepalive out of App Nap and timer
// throttling. AppModel picks the level from its session state: a light activity while signed in, and a
// user-initiated, latency-critical one while a turn or computer session runs.

import Foundation

nonisolated protocol ProcessActivityScheduling: AnyObject, Sendable {
    func beginActivity(options: ProcessInfo.ActivityOptions, reason: String) -> NSObjectProtocol
    func endActivity(_ activity: NSObjectProtocol)
}

extension ProcessInfo: ProcessActivityScheduling {}

nonisolated final class ConnectionActivity: @unchecked Sendable {
    enum Level: Equatable, Sendable {
        case idle, signedIn, active

        var options: ProcessInfo.ActivityOptions {
            switch self {
            case .idle: []
            case .signedIn: [.userInitiatedAllowingIdleSystemSleep]
            case .active: [.userInitiated, .latencyCritical]
            }
        }

        var reason: String {
            switch self {
            case .idle: ""
            case .signedIn: "Keeping the AstralDeep server connection"
            case .active: "Running an AstralDeep turn or computer session"
            }
        }
    }

    private let scheduler: any ProcessActivityScheduling
    private let lock = NSLock()
    private var held = Level.idle
    private var token: NSObjectProtocol?

    init(scheduler: any ProcessActivityScheduling) {
        self.scheduler = scheduler
    }

    var level: Level { lock.withLock { held } }

    func update(_ next: Level) {
        lock.lock()
        guard next != held else {
            lock.unlock()
            return
        }
        let previous = token
        token = next == .idle ? nil : scheduler.beginActivity(options: next.options, reason: next.reason)
        held = next
        lock.unlock()
        if let previous { scheduler.endActivity(previous) }
    }

    deinit {
        if let token { scheduler.endActivity(token) }
    }
}
