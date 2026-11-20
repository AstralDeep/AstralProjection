// Turns the system's memory-warning and app-backgrounded signals into unloads on the VoiceModelOwner, taking both signals as injectable streams so tests drive them directly.
// RumbleVoiceModels starts one with the system sources; the owner rebuilds its models on next use, so a backgrounded GPU never holds a loaded model.

import Foundation

#if canImport(UIKit)
    import UIKit
#endif

nonisolated final class VoiceModelLifecycleObserver: @unchecked Sendable {
    struct Sources: Sendable {
        let memoryWarnings: AsyncStream<Void>
        let backgrounded: AsyncStream<Void>

        static func system() -> Sources {
            #if canImport(UIKit)
                Sources(
                    memoryWarnings: notifications(UIApplication.didReceiveMemoryWarningNotification),
                    backgrounded: notifications(UIApplication.didEnterBackgroundNotification))
            #else
                Sources(memoryWarnings: memoryPressure(), backgrounded: AsyncStream { $0.finish() })
            #endif
        }

        #if canImport(UIKit)
            private static func notifications(_ name: Notification.Name) -> AsyncStream<Void> {
                AsyncStream { continuation in
                    let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                        continuation.yield()
                    }
                    continuation.onTermination = { _ in NotificationCenter.default.removeObserver(observer) }
                }
            }
        #else
            private static func memoryPressure() -> AsyncStream<Void> {
                AsyncStream { continuation in
                    let source = DispatchSource.makeMemoryPressureSource(
                        eventMask: [.warning, .critical], queue: .global(qos: .utility))
                    source.setEventHandler { continuation.yield() }
                    continuation.onTermination = { _ in source.cancel() }
                    source.resume()
                }
            }
        #endif
    }

    private let owner: VoiceModelOwner
    private let sources: Sources
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []

    init(owner: VoiceModelOwner, sources: Sources = .system()) {
        self.owner = owner
        self.sources = sources
    }

    func start() {
        lock.withLock {
            guard tasks.isEmpty else { return }
            let owner = owner
            let warnings = sources.memoryWarnings
            let background = sources.backgrounded
            tasks = [
                Task { for await _ in warnings { await owner.memoryPressure() } },
                Task { for await _ in background { await owner.unload() } },
            ]
        }
    }

    func stop() {
        lock.withLock {
            for task in tasks { task.cancel() }
            tasks = []
        }
    }

    deinit { stop() }
}
