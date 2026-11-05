// Verifies owner scoping, bounded retention, and safe closed-vocabulary computer activity summaries.
// Timeline records intentionally expose no request arguments, paths, screenshots, or result payloads.

#if os(macOS)
    import Foundation
    import XCTest

    @testable import AstralDeep

    @MainActor
    final class MacComputerActivityTimelineTests: XCTestCase {
        func testOwnerChangesAndSignOutClearPriorActivity() {
            let timeline = MacComputerActivityTimeline()
            timeline.bind(owner: "owner-a")
            timeline.record(.admission, state: "admitted", verb: "click")
            XCTAssertEqual(timeline.entries.count, 1)

            timeline.bind(owner: "owner-b")
            XCTAssertTrue(timeline.entries.isEmpty)
            timeline.record(.denial, state: "denied", verb: "type")
            timeline.bind(owner: nil)
            XCTAssertTrue(timeline.entries.isEmpty)
            timeline.record(.result, state: "succeeded", verb: "click")
            XCTAssertTrue(timeline.entries.isEmpty)
        }

        func testRetentionIsBoundedAndKeepsNewestEntries() throws {
            var instant = Date(timeIntervalSince1970: 1_000)
            let timeline = MacComputerActivityTimeline(now: { instant })
            timeline.bind(owner: "owner-a")
            for _ in 0..<MacComputerActivityTimeline.maximumEntries + 5 {
                timeline.record(.admission, state: "admitted", verb: "click")
                instant.addTimeInterval(1)
            }

            XCTAssertEqual(timeline.entries.count, MacComputerActivityTimeline.maximumEntries)
            XCTAssertEqual(timeline.entries.first?.occurredAt.timeIntervalSince1970, 1_005)
            XCTAssertEqual(timeline.entries.last?.occurredAt.timeIntervalSince1970, 1_104)
        }

        func testDenialAndTransitionLabelsUseOnlySafeMetadata() throws {
            let timeline = MacComputerActivityTimeline()
            timeline.bind(owner: "owner-a")
            timeline.record(.approval, state: "waiting")
            timeline.record(.admission, state: "admitted", verb: "read_file")
            timeline.record(.denial, state: "denied", verb: "click")
            timeline.record(.pause, state: "paused")
            timeline.record(.resume, state: "requested")
            timeline.record(.resume, state: "active")
            timeline.record(.checkpoint, state: "succeeded", verb: "restore_checkpoint")
            timeline.record(.stop, state: "stopped")

            XCTAssertEqual(
                timeline.entries.map(\.title),
                [
                    "Approval requested", "Request admitted", "Request denied", "Computer access paused",
                    "Resume requested", "Computer access resumed", "Checkpoint request completed",
                    "Computer task stopped",
                ])
            XCTAssertEqual(timeline.entries[1].safeVerb, "read file")
            XCTAssertEqual(timeline.entries[2].safeVerb, "click")
        }

        func testUnknownStateOrUnsafeVerbIsRejected() {
            let timeline = MacComputerActivityTimeline()
            timeline.bind(owner: "owner-a")
            timeline.record(.admission, state: "future_state", verb: "click")
            timeline.record(.denial, state: "denied", verb: "run_command /Users/private")
            XCTAssertEqual(timeline.entries.map(\.title), ["Request denied"])
            XCTAssertNil(timeline.entries.first?.safeVerb)
        }
    }
#endif
