// Tests for the plain-language device status lines, the comparison code grouping, the identity verification flow and the on-device answer notice.
// They run over the in-memory kernel, so no sign-in, Keychain item or network is involved.

import XCTest

@testable import AstralDeep

@MainActor
final class MeshDeviceUXTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func member(this: Bool = false, seen: Date? = nil, path: MeshPath = .none)
        -> MeshMember
    {
        MeshMember(
            memberId: "sha256:m", label: "Phone", kind: .pocket, isThisDevice: this, lastSeen: seen,
            path: path)
    }

    private func sync(_ state: MeshDeviceSync.State, seen: Date?, path: MeshPath) -> MeshDeviceSync {
        MeshDeviceSync(memberId: "sha256:m", label: "Phone", state: state, lastSeen: seen, path: path)
    }

    func testSyncedDeviceReadsSyncedJustNowOnThisNetwork() {
        let line = MeshPresentation.deviceStatus(
            member(), sync: sync(.synced, seen: now.addingTimeInterval(-5), path: .direct), now: now, calendar: utc)
        XCTAssertEqual(line, "Synced just now · on this network")
    }

    func testSyncedDeviceSeenEarlierUsesRelativeTimeAndRelayPath() {
        let line = MeshPresentation.deviceStatus(
            member(), sync: sync(.synced, seen: now.addingTimeInterval(-300), path: .relay), now: now, calendar: utc)
        XCTAssertTrue(line.hasPrefix("Synced 5 minutes ago"))
        XCTAssertTrue(line.hasSuffix("through a relay"))
    }

    func testUnreachableDeviceReadsWaitingSinceTheTimeOfDay() {
        let seen = now.addingTimeInterval(-1_800)
        let line = MeshPresentation.deviceStatus(
            member(seen: seen), sync: sync(.unreachable, seen: seen, path: .none), now: now, calendar: utc)
        XCTAssertTrue(line.hasPrefix("Waiting since "))
        XCTAssertFalse(line.contains(","))
    }

    func testWaitingSinceANonRecentDayIncludesTheDate() {
        let seen = now.addingTimeInterval(-3 * 86_400)
        XCTAssertTrue(MeshPresentation.clock(seen, now: now, calendar: utc).contains(","))
    }

    func testCatchingUpAndUnknownStates() {
        XCTAssertEqual(
            MeshPresentation.deviceStatus(member(), sync: sync(.behind, seen: nil, path: .mailbox), now: now),
            "Catching up · through the mailbox")
        XCTAssertEqual(MeshPresentation.deviceStatus(member(), sync: nil, now: now), "Not seen yet")
    }

    func testDeviceMembershipDescribesTheSignedDeviceWithoutPersonVerification() {
        XCTAssertEqual(MeshPresentation.deviceStatus(member(this: true), sync: nil), "This device · signed mesh member")
        XCTAssertEqual(MeshPresentation.deviceStatus(member(), sync: nil), "Not seen yet")
    }

    func testComparisonCodeIsGroupedInFoursAndOddCodesAreKeptWhole() {
        XCTAssertEqual(MeshPresentation.codeGroups("76076454"), ["7607", "6454"])
        XCTAssertEqual(MeshPresentation.codeGroups("7607 6454"), ["7607", "6454"])
        XCTAssertEqual(MeshPresentation.codeGroups("123"), ["123"])
    }

    func testProviderFailureWithAnAvailableOnDeviceModelStaysAnError() async {
        let h = MeshRuntimeHarness(onDeviceAvailable: true)
        defer { h.cleanUp() }
        await h.runtime.open()
        _ = await h.runtime.newChat()
        h.kernel.turnScript = [
            .started, .assistantDelta("Hi"), .assistantFinished,
            .failed(KernelMapping.failureText(code: "provider.unreachable")),
        ]
        _ = await h.runtime.send("hello")
        await h.runtime.settle()
        XCTAssertEqual(h.runtime.currentTurn?.answeredOnDevice, false)
        XCTAssertEqual(h.runtime.currentTurn?.failure, KernelMapping.failureText(code: "provider.unreachable"))
    }

    func testAFailedLocalFallbackKeepsItsFailureAndNeverClaimsAnAnswer() async {
        let h = MeshRuntimeHarness(onDeviceAvailable: true)
        defer { h.cleanUp() }
        await h.runtime.open()
        _ = await h.runtime.newChat()
        let failure = KernelMapping.failureText(code: "provider.unreachable")
        h.kernel.turnScript = [.started, .notice("This turn is using on-device."), .failed(failure)]
        _ = await h.runtime.send("hello")
        await h.runtime.settle()
        XCTAssertEqual(h.runtime.currentTurn?.answeredOnDevice, false)
        XCTAssertEqual(h.runtime.currentTurn?.failure, failure)
        XCTAssertNil(h.runtime.currentTurn?.notice)
        XCTAssertEqual(h.runtime.currentTurn?.running, false)
    }

    func testProviderFailureWithoutAnOnDeviceModelStaysAnError() async {
        let h = MeshRuntimeHarness(onDeviceAvailable: false)
        defer { h.cleanUp() }
        await h.runtime.open()
        _ = await h.runtime.newChat()
        h.kernel.turnScript = [.started, .failed(KernelMapping.failureText(code: "provider.unreachable"))]
        _ = await h.runtime.send("hello")
        await h.runtime.settle()
        XCTAssertEqual(h.runtime.currentTurn?.answeredOnDevice, false)
        XCTAssertNotNil(h.runtime.currentTurn?.failure)
    }

    func testOtherFailuresStayErrorsEvenWithAnOnDeviceModel() async {
        let h = MeshRuntimeHarness(onDeviceAvailable: true)
        defer { h.cleanUp() }
        await h.runtime.open()
        _ = await h.runtime.newChat()
        h.kernel.turnScript = [.started, .failed(KernelMapping.failureText(code: "gate.mesh_stopped"))]
        _ = await h.runtime.send("hello")
        await h.runtime.settle()
        XCTAssertEqual(h.runtime.currentTurn?.answeredOnDevice, false)
        XCTAssertNotNil(h.runtime.currentTurn?.failure)
    }
}
