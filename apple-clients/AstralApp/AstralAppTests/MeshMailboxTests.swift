// Verifies the mailbox setting in MeshRuntime over an in-memory kernel: empty by default, validation, passing the address at open, reopening on a change, and the state the settings screen reads.
// The real kernel's address check and reopen are covered in RealMeshKernelTests.

@testable import AstralDeep
import AstralKernel
import XCTest

@MainActor
final class MeshMailboxTests: XCTestCase {
    func testTheMailboxIsEmptyByDefaultAndNothingIsPassedAtOpen() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        XCTAssertNil(h.runtime.mailboxAddress)
        XCTAssertEqual(h.box.openedConfigs.map(\.mailbox), [nil])
        XCTAssertEqual(h.runtime.mailbox, .off)
        XCTAssertEqual(MeshPresentation.mailbox(h.runtime.mailbox), "No mailbox is set.")
    }

    func testSavingAnAddressReopensTheMeshWithItAndRemembersIt() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let problem = await h.runtime.saveMailbox("  node-key-1  ")
        XCTAssertNil(problem)
        XCTAssertEqual(h.runtime.phase, .ready)
        XCTAssertEqual(h.runtime.mailboxAddress, "node-key-1")
        XCTAssertEqual(h.box.openedConfigs.map(\.mailbox), [nil, "node-key-1"])
        XCTAssertEqual(h.defaults.string(forKey: "astral.mesh.mailbox"), "node-key-1")
    }

    func testANewRuntimeReadsTheSavedAddressAtItsNextOpen() async {
        let again = MeshRuntimeHarness(mailbox: "saved-address")
        defer { again.cleanUp() }
        await again.runtime.open()
        XCTAssertEqual(again.runtime.mailboxAddress, "saved-address")
        XCTAssertEqual(again.box.openedConfigs.first?.mailbox, "saved-address")
    }

    func testAnEmptyAddressClearsTheMailbox() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        _ = await h.runtime.saveMailbox("node-key-1")
        let problem = await h.runtime.saveMailbox("   ")
        XCTAssertNil(problem)
        XCTAssertNil(h.runtime.mailboxAddress)
        XCTAssertNil(h.defaults.string(forKey: "astral.mesh.mailbox"))
        XCTAssertEqual(h.box.openedConfigs.map(\.mailbox), [nil, "node-key-1", nil])
    }

    func testSavingTheSameAddressDoesNotRestartTheMesh() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        _ = await h.runtime.saveMailbox("node-key-1")
        let before = h.box.openedConfigs.count
        let problem = await h.runtime.saveMailbox("node-key-1 ")
        XCTAssertNil(problem)
        XCTAssertEqual(h.box.openedConfigs.count, before)
    }

    func testBadInputIsRefusedBeforeAnythingRestarts() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let spaced = await h.runtime.saveMailbox("two words")
        XCTAssertEqual(spaced, .containsSpaces)
        let long = await h.runtime.saveMailbox(String(repeating: "a", count: MeshMailboxInput.maximumLength + 1))
        XCTAssertEqual(long, .tooLong)
        XCTAssertEqual(h.box.openedConfigs.count, 1)
        XCTAssertNil(h.runtime.mailboxAddress)
        XCTAssertFalse(MeshMailboxInputError.containsSpaces.message.isEmpty)
        XCTAssertFalse(MeshMailboxInputError.tooLong.message.isEmpty)
    }

    func testAnAddressTheKernelRefusesIsRemovedAndTheMeshOpensWithoutIt() async {
        let again = MeshRuntimeHarness(mailbox: "bad", rejectMailbox: true)
        defer { again.cleanUp() }
        await again.runtime.open()
        XCTAssertEqual(again.runtime.phase, .ready)
        XCTAssertNil(again.runtime.mailboxAddress)
        XCTAssertNil(again.defaults.string(forKey: "astral.mesh.mailbox"))
        XCTAssertEqual(again.box.openedConfigs.map(\.mailbox), ["bad", nil])
        XCTAssertEqual(again.runtime.notice, "That mailbox address was not accepted. It was removed.")
    }

    func testAKernelFailureThatIsNotAboutTheMailboxStaysAFailure() async {
        let h = MeshRuntimeHarness(factoryError: .unavailable("No runtime"), mailbox: "node-key-1")
        defer { h.cleanUp() }
        await h.runtime.open()
        XCTAssertEqual(h.runtime.phase, .failed("No runtime"))
    }

    func testTheKernelsMailboxStateReachesTheScreen() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let when = Date(timeIntervalSince1970: 1_000)
        h.kernel.setMailboxState(
            MeshMailboxState(configured: true, status: .ok, lastError: nil, lastOk: when, pendingNotices: 2, truncated: true))
        await h.runtime.refreshMailbox()
        XCTAssertEqual(h.runtime.mailbox.pendingNotices, 2)
        XCTAssertTrue(h.runtime.mailbox.truncated)
        XCTAssertEqual(h.runtime.mailbox.lastOk, when)
        await h.runtime.close()
        XCTAssertEqual(h.runtime.mailbox, .off)
    }

    func testEveryMailboxStatusHasPlainText() {
        let now = Date(timeIntervalSince1970: 10_000)
        func text(_ status: MeshMailboxState.Status, error: String? = nil, ok: Date? = nil, configured: Bool = true) -> String {
            MeshPresentation.mailbox(
                MeshMailboxState(
                    configured: configured, status: status, lastError: error, lastOk: ok, pendingNotices: 0, truncated: false),
                now: now)
        }
        XCTAssertEqual(text(.disabled), "No mailbox is set.")
        XCTAssertEqual(text(.ok, configured: false), "No mailbox is set.")
        XCTAssertEqual(text(.idle), "Set. Waiting for the first exchange.")
        XCTAssertEqual(text(.ok), "Working. No exchange yet.")
        XCTAssertEqual(text(.ok, ok: now.addingTimeInterval(-10)), "Working. Last exchange just now.")
        XCTAssertTrue(text(.ok, ok: now.addingTimeInterval(-3_600)).hasPrefix("Working. Last exchange "))
        XCTAssertEqual(text(.waiting), "Waiting for the mailbox to answer.")
        XCTAssertEqual(text(.removed), "The mailbox no longer accepts this device.")
        XCTAssertEqual(text(.unreachable), "The mailbox cannot be reached right now.")
        XCTAssertEqual(text(.error, error: "mailbox.too_large"), "The mailbox refused the exchange (mailbox.too_large).")
        XCTAssertEqual(text(.error), "The mailbox refused the exchange.")
        XCTAssertEqual(text(.unknown), "The mailbox state is not known.")
    }

    func testGeneratedMailboxStateMapsToTheHostType() {
        let state = KernelMapping.mailbox(
            MailboxState(
                configured: true, status: "unreachable", lastError: "net.connect", lastOkMs: 2_000,
                depositedThrough: 3, collectedThrough: 4, pendingNotices: 5, truncated: true))
        XCTAssertTrue(state.configured)
        XCTAssertEqual(state.status, .unreachable)
        XCTAssertEqual(state.lastError, "net.connect")
        XCTAssertEqual(state.lastOk, Date(timeIntervalSince1970: 2))
        XCTAssertEqual(state.pendingNotices, 5)
        XCTAssertTrue(state.truncated)
        let odd = KernelMapping.mailbox(
            MailboxState(
                configured: false, status: "surprise", lastError: nil, lastOkMs: nil, depositedThrough: 0,
                collectedThrough: 0, pendingNotices: 0, truncated: false))
        XCTAssertEqual(odd.status, .unknown)
        XCTAssertNil(odd.lastOk)
    }
}
