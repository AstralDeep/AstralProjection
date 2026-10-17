// Verifies utterance ownership and terminal ordering used by SystemAppleLocalSpeechEngine.
// Delegate events from stopped or replaced synthesis cannot reach another announcement.

import Foundation
import XCTest

@testable import AstralDeep

final class AppleLocalSpeechProgressTests: XCTestCase {
    @MainActor
    func testOnlyTheCurrentUtteranceReportsProgressOnce() async {
        let progress = AppleLocalSpeechProgress()
        let current = NSObject()
        var phases: [String] = []
        progress.begin(current) { phases.append($0) }
        progress.start(NSObject())
        progress.finish(NSObject(), phase: "finished")
        XCTAssertTrue(phases.isEmpty)
        progress.start(current)
        progress.start(current)
        progress.finish(current, phase: "finished")
        progress.finish(current, phase: "failed")
        XCTAssertEqual(phases, ["started", "finished"])
    }

    @MainActor
    func testStoppedAndReplacedUtterancesCannotCompleteTheNewOwner() async {
        let progress = AppleLocalSpeechProgress()
        let previous = NSObject()
        let current = NSObject()
        var phases: [String] = []
        progress.begin(previous) { phases.append("previous:\($0)") }
        progress.clear()
        progress.begin(current) { phases.append("current:\($0)") }
        progress.start(previous)
        progress.finish(previous, phase: "interrupted")
        progress.start(current)
        progress.finish(current, phase: "finished")
        XCTAssertEqual(phases, ["current:started", "current:finished"])
    }

    @MainActor
    func testTerminalCallbackMayBeginTheNextUtteranceWithoutLosingItsOwner() async {
        let progress = AppleLocalSpeechProgress()
        let previous = NSObject()
        let next = NSObject()
        var phases: [String] = []
        progress.begin(previous) { phase in
            phases.append("previous:\(phase)")
            progress.begin(next) { phases.append("next:\($0)") }
        }
        progress.finish(previous, phase: "failed")
        progress.start(next)
        progress.finish(next, phase: "finished")
        XCTAssertEqual(phases, ["previous:failed", "next:started", "next:finished"])
    }
}
