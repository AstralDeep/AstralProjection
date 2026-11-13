// Exercises bounded local file imports and attachment drafts through the runtime that owns the chat composer.
// It verifies attachment-only sends, per-chat drafts, refusals and the file bytes offered for an explicit save.

import XCTest

@testable import AstralDeep

final class MeshAttachmentTests: XCTestCase {
    private func file(_ bytes: Data = Data("hello".utf8), name: String = "note.txt") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    func testImportKeepsTheBytesAndAnAttachmentOnlyMessageNamesTheFile() async throws {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let chat = await h.runtime.newChat()
        let imported = await h.runtime.attachFile(try file())
        XCTAssertTrue(imported)
        let attachment = try XCTUnwrap(h.runtime.draftAttachments.first)
        XCTAssertEqual(attachment.name, "note.txt")
        XCTAssertEqual(attachment.mime, "text/plain")
        let bytes = await h.runtime.attachmentBytes(attachment)
        XCTAssertEqual(bytes, Data("hello".utf8))
        let sent = await h.runtime.send("")
        XCTAssertTrue(sent)
        XCTAssertTrue(h.runtime.draftAttachments.isEmpty)
        let view = try h.kernel.chat(chatId: XCTUnwrap(chat))
        XCTAssertEqual(view.messages.first?.attachments.map(\.id), [attachment.id])
        XCTAssertEqual(view.messages.first?.text, "")
    }

    func testDraftsStayWithTheirChatAndFailedSendKeepsTheSelection() async throws {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let opened = await h.runtime.newChat()
        let first = try XCTUnwrap(opened)
        let imported = await h.runtime.attachFile(try file())
        XCTAssertTrue(imported)
        let selected = h.runtime.draftAttachments
        _ = await h.runtime.newChat()
        XCTAssertTrue(h.runtime.draftAttachments.isEmpty)
        await h.runtime.openChat(first)
        XCTAssertEqual(h.runtime.draftAttachments, selected)
        h.kernel.failure = .unavailable("Offline")
        let sent = await h.runtime.send("keep this")
        XCTAssertFalse(sent)
        XCTAssertEqual(h.runtime.draftAttachments, selected)
        h.kernel.failure = nil
        h.runtime.removeDraftAttachment(selected[0].id)
        XCTAssertTrue(h.runtime.draftAttachments.isEmpty)
    }

    func testTheNinthAttachmentAndStoppedImportsNeverEnterTheChat() async throws {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        _ = await h.runtime.newChat()
        for index in 0..<8 {
            let imported = await h.runtime.attachFile(try file(name: "note\(index).txt"))
            XCTAssertTrue(imported)
        }
        let ninth = await h.runtime.attachFile(try file(name: "ninth.txt"))
        XCTAssertFalse(ninth)
        XCTAssertEqual(h.runtime.draftAttachments.count, 8)
        await h.runtime.raiseStop()
        h.runtime.removeDraftAttachment(h.runtime.draftAttachments[0].id)
        let stopped = await h.runtime.attachFile(try file(name: "stopped.txt"))
        XCTAssertFalse(stopped)
        XCTAssertEqual(h.runtime.draftAttachments.count, 7)
    }

    func testFileInputRejectsEmptyOversizeUnsupportedDirectoriesAndSymlinks() throws {
        XCTAssertThrowsError(try MeshAttachmentFile.read(file(Data())))
        XCTAssertThrowsError(try MeshAttachmentFile.read(file(Data(repeating: 0, count: 16 * 1024 * 1024 + 1))))
        XCTAssertThrowsError(try MeshAttachmentFile.read(file(name: "script.sh")))
        let regular = try file()
        XCTAssertThrowsError(try MeshAttachmentFile.read(regular.deletingLastPathComponent()))
        let link = regular.deletingLastPathComponent().appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        XCTAssertThrowsError(try MeshAttachmentFile.read(link))
        XCTAssertThrowsError(try MeshAttachmentFile.read(URL(string: "https://example.test/x.txt")!))
        let parsed = try MeshAttachmentFile.read(regular)
        XCTAssertEqual(parsed.bytes, Data("hello".utf8))
        XCTAssertEqual(parsed.mime, "text/plain")
        XCTAssertEqual(parsed.name, "note.txt")
    }

    func testClosingTheMeshDropsAttachmentDrafts() async throws {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        _ = await h.runtime.newChat()
        let imported = await h.runtime.attachFile(try file())
        XCTAssertTrue(imported)
        await h.runtime.close()
        XCTAssertTrue(h.runtime.attachmentDrafts.isEmpty)
        XCTAssertFalse(h.runtime.importingAttachment)
    }
}
