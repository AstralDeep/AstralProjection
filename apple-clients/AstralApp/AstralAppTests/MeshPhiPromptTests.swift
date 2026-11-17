// Verifies the uncertain-match prompt: what the sheet shows, which answers it returns, and that nothing but a foreground owner action can raise it.
// The host runs on a worker thread as the Kernel does, and the center stands in for the sheet.

import XCTest

@testable import AstralDeep

@MainActor
final class MeshPhiPromptTests: XCTestCase {
    private func question() -> MeshPhiQuestion {
        MeshPhiQuestion(items: [
            MeshPhiQuestionItem(source: "message", kind: "name", excerpt: "Jane Roe"),
            MeshPhiQuestionItem(source: "attachment", kind: "date", excerpt: "03/04/1980"),
        ])
    }

    private func ask(_ host: MeshPhiPromptHost) async -> MeshPhiAnswer {
        let question = question()
        return await Task.detached { host.ask(question) }.value
    }

    private func settle(_ center: MeshPhiPromptCenter) async {
        for _ in 0..<200 where center.pending == nil { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testTheSheetCopyShowsEachFindingsKindAndExcerptAndBothAnswers() async {
        let center = MeshPhiPromptCenter()
        center.setForeground(true)
        let host = MeshPhiPromptHost(center: center)
        async let answer = ask(host)
        await settle(center)
        let items = center.pending?.question.items
        XCTAssertEqual(items?.map(\.excerpt), ["Jane Roe", "03/04/1980"])
        XCTAssertEqual(items?.map { MeshPhiPromptCopy.kind($0.kind) }, ["A name", "A date"])
        XCTAssertEqual(items?.map { MeshPhiPromptCopy.source($0.source) }, ["In your message", "In a file"])
        center.answer(.send)
        let result = await answer
        XCTAssertEqual(result, .send)
        XCTAssertEqual(MeshPhiPromptID.send, "mesh.phi.prompt.send")
        XCTAssertEqual(MeshPhiPromptID.treat, "mesh.phi.prompt.treat")
        XCTAssertEqual(MeshPhiPromptID.item(1), "mesh.phi.prompt.item.1")
    }

    func testTreatAsPhiReturnsTreatAsPhi() async {
        let center = MeshPhiPromptCenter()
        center.setForeground(true)
        let host = MeshPhiPromptHost(center: center)
        async let answer = ask(host)
        await settle(center)
        center.answer(.treatAsPhi)
        let result = await answer
        XCTAssertEqual(result, .treatAsPhi)
        XCTAssertNil(center.pending)
    }

    func testClosingTheSheetBackgroundingAndTheTimeoutAllTreatAsPhi() async {
        let center = MeshPhiPromptCenter()
        center.setForeground(true)
        let host = MeshPhiPromptHost(center: center)
        async let closed = ask(host)
        await settle(center)
        center.expire(center.pending?.id ?? UUID())
        let first = await closed
        XCTAssertEqual(first, .treatAsPhi)
        async let hidden = ask(host)
        await settle(center)
        center.setForeground(false)
        let second = await hidden
        XCTAssertEqual(second, .treatAsPhi)
        center.setForeground(true)
        let quick = MeshPhiPromptHost(center: center, timeout: .milliseconds(50))
        let third = await ask(quick)
        XCTAssertEqual(third, .treatAsPhi)
        await settle(center)
        XCTAssertNil(center.pending)
    }

    func testNothingShowsInTheBackgroundOrWhileAnotherQuestionIsOpen() async {
        let center = MeshPhiPromptCenter()
        let host = MeshPhiPromptHost(center: center)
        let background = await ask(host)
        XCTAssertEqual(background, .treatAsPhi)
        XCTAssertNil(center.pending)
        center.setForeground(true)
        async let first = ask(host)
        await settle(center)
        let second = await ask(host)
        XCTAssertEqual(second, .treatAsPhi)
        center.answer(.send)
        let kept = await first
        XCTAssertEqual(kept, .send)
        XCTAssertEqual(host.ask(question()), .treatAsPhi)
        let empty = await Task.detached { host.ask(MeshPhiQuestion(items: [])) }.value
        XCTAssertEqual(empty, .treatAsPhi)
    }

    func testTheExcerptNeverAppearsInADescription() {
        let item = MeshPhiQuestionItem(source: "message", kind: "name", excerpt: "Jane Roe")
        XCTAssertFalse(String(describing: item).contains("Jane"))
        XCTAssertFalse(String(reflecting: item).contains("Jane"))
    }

    func testAnOwnerSendInTheForegroundIsAttendedAndEverythingElseIsNot() async throws {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        _ = await h.runtime.newChat()
        _ = await h.runtime.send("hello")
        await h.runtime.settle()
        h.runtime.phiPrompts.setForeground(true)
        _ = await h.runtime.send("hello again")
        await h.runtime.settle()
        _ = await h.runtime.send("spoken", speaking: true)
        await h.runtime.settle()
        XCTAssertEqual(h.kernel.attendedFlags, [false, true, false])
    }

    func testAWatchRelayedMessageIsUnattendedEvenInTheForeground() async throws {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let chat = await h.runtime.newChat()
        h.runtime.phiPrompts.setForeground(true)
        let chatId = try XCTUnwrap(chat)
        _ = await h.runtime.send("from the watch", to: chatId)
        await h.runtime.settle()
        XCTAssertEqual(h.kernel.attendedFlags, [false])
        XCTAssertNil(h.runtime.phiPrompts.pending)
    }

    func testAnAttachmentIsAttendedOnlyInTheForeground() async throws {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        _ = await h.runtime.newChat()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("note".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        _ = await h.runtime.attachFile(file)
        h.runtime.phiPrompts.setForeground(true)
        _ = await h.runtime.attachFile(file)
        XCTAssertEqual(h.kernel.attendedFlags, [false, true])
    }
}
