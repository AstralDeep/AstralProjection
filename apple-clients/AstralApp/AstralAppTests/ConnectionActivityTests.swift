// Checks the ProcessInfo activity AppModel holds so App Nap and timer throttling cannot starve the socket.
// A recording scheduler stands in for ProcessInfo; a scripted Mac host supplies the computer session.

#if os(macOS)
    import AstralCore
    import Foundation
    import XCTest

    @testable import AstralDeep

    @MainActor
    final class ConnectionActivityTests: XCTestCase {
        private func model(host: MacComputerHost? = nil) throws -> (AppModel, RecordingActivityScheduler) {
            let scheduler = RecordingActivityScheduler()
            let suite = "ConnectionActivityTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
            let model = AppModel(
                conversationResumeStore: ConversationResumeStore(defaults: defaults), tokenStore: InMemoryTokenStore(),
                defaults: defaults, computerHost: host, processActivity: scheduler)
            model.outboundTap = { _ in }
            return (model, scheduler)
        }

        private func settle(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertTrue(condition())
        }

        private func sessionHost() throws -> MacComputerHost {
            let suite = "ConnectionActivityHost.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
            let host = MacComputerHost(
                available: true, defaults: defaults, driver: MacComputerTaskDriver(),
                monitor: MacComputerTaskMonitor(),
                permissionProvider: { MacComputerPermissions(accessibility: true, screen: true, monitoring: true) },
                desktopProbe: { true }, desktopRearm: { true }, system: MacComputerTestSystem(),
                panelPresenter: { _ in })
            host.bind(owner: "activity-owner") { _ in true }
            host.setEnabled(true)
            addTeardownBlock { host.applicationWillTerminate() }
            return host
        }

        func testSignedInHoldsALightActivityAndATurnRaisesItUntilTheTurnEnds() async throws {
            let (model, scheduler) = try model()
            XCTAssertTrue(scheduler.held.isEmpty)
            model.signedIn = true
            try await settle { scheduler.held.count == 1 }
            XCTAssertEqual(scheduler.held.first?.options, [.userInitiatedAllowingIdleSystemSleep])
            XCTAssertEqual(model.connectionActivity.level, .signedIn)
            model.turnActive = true
            try await settle { scheduler.held.first?.options == [.userInitiated, .latencyCritical] }
            XCTAssertEqual(scheduler.held.count, 1)
            XCTAssertEqual(model.connectionActivity.level, .active)
            model.turnActive = false
            try await settle { scheduler.held.first?.options == [.userInitiatedAllowingIdleSystemSleep] }
            XCTAssertEqual(scheduler.held.count, 1)
            XCTAssertEqual(scheduler.began.count, 3)
            await model.signOut(revokeRemote: false)
            try await settle { scheduler.held.isEmpty }
            XCTAssertEqual(scheduler.ended.count, 3)
            XCTAssertEqual(model.connectionActivity.level, .idle)
        }

        func testAComputerSessionKeepsTheLatencyCriticalActivityWithoutATurn() async throws {
            let host = try sessionHost()
            let (model, scheduler) = try model(host: host)
            model.signedIn = true
            try await settle { model.connectionActivity.level == .signedIn }
            let descriptor = try XCTUnwrap(host.descriptor)
            let session = UUID().uuidString.lowercased()
            host.consume(
                InboundFrame(
                    name: "computer_session",
                    payload: .object([
                        "type": .string("computer_session"), "host_id": .string(descriptor.hostId),
                        "session_id": .string(session), "state": .string("active"),
                        "controller_label": .string("Activity test"),
                    ])))
            XCTAssertTrue(host.taskActive)
            try await settle { model.connectionActivity.level == .active }
            XCTAssertEqual(scheduler.held.first?.options, [.userInitiated, .latencyCritical])
            host.stop()
            try await settle { model.connectionActivity.level == .signedIn }
            XCTAssertEqual(scheduler.held.count, 1)
        }

        func testReleasingTheHolderEndsItsActivity() {
            let scheduler = RecordingActivityScheduler()
            var holder: ConnectionActivity? = ConnectionActivity(scheduler: scheduler)
            holder?.update(.active)
            holder?.update(.active)
            XCTAssertEqual(scheduler.began.count, 1)
            holder = nil
            XCTAssertTrue(scheduler.held.isEmpty)
            XCTAssertEqual(scheduler.ended.count, 1)
        }
    }

    nonisolated final class RecordingActivityScheduler: ProcessActivityScheduling, @unchecked Sendable {
        struct Activity {
            let token: NSObject
            let options: ProcessInfo.ActivityOptions
            let reason: String
        }
        private let lock = NSLock()
        private var started: [Activity] = []
        private var finished: [NSObject] = []

        var began: [Activity] { lock.withLock { started } }
        var ended: [NSObject] { lock.withLock { finished } }
        var held: [Activity] {
            lock.withLock { started.filter { activity in !finished.contains { $0 === activity.token } } }
        }

        func beginActivity(options: ProcessInfo.ActivityOptions, reason: String) -> NSObjectProtocol {
            let token = NSObject()
            lock.withLock { started.append(Activity(token: token, options: options, reason: reason)) }
            return token
        }

        func endActivity(_ activity: NSObjectProtocol) {
            guard let token = activity as? NSObject else { return }
            lock.withLock { finished.append(token) }
        }
    }
#endif
