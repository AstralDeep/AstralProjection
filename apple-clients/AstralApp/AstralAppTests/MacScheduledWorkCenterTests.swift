// Verifies how the scheduled work window presents a job's next run.
// The node remains the authority for materialization and execution.

#if os(macOS)
    import AstralCore
    import Foundation
    import XCTest

    @testable import AstralDeep

    @MainActor
    final class MacScheduledWorkCenterTests: XCTestCase {
        private let jobID = "6d12ed1e-7485-4a76-8e94-9827b049fce8"

        private func scheduleJob(status: String) throws -> ScheduledWorkJob {
            try XCTUnwrap(
                ScheduledWorkJob(
                    json: .object([
                        "id": .string(jobID), "name": .string("Daily research"),
                        "instruction": .string("Review the latest results"), "status": .string(status),
                        "schedule_kind": .string("cron"), "schedule_expr": .string("0 9 * * *"),
                        "timezone": .string("America/New_York"), "consented_scopes": .array([]),
                        "next_run_at": .number(1_800_000_000_000), "last_run_at": .null,
                    ])))
        }

        func testNextRunDateIsPresentedOnlyForActiveSchedules() throws {
            let active = try scheduleJob(status: "active")
            let disabled = try scheduleJob(status: "disabled")

            XCTAssertNotNil(MacScheduledWorkCenter.nextRunDateText(for: active))
            XCTAssertNil(MacScheduledWorkCenter.nextRunDateText(for: disabled))
        }

    }
#endif
