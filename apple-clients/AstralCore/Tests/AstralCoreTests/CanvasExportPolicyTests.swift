import Foundation
import XCTest

@testable import AstralCore

final class CanvasExportPolicyTests: XCTestCase {
    private let base = URL(string: "https://astral.example.test")!

    private func capture() -> JSONValue {
        .object([
            "version": .string(CanvasExportPolicy.version),
            "components": .array([.object(["type": .string("text"), "content": .string("Visible result")])]),
            "viewport": .object([
                "width": .number(296), "height": .number(600),
                "window_width": .number(320), "window_height": .number(800),
            ]),
            "theme": .object(["bg": .string("#101020")]),
            "display_state": .array([]), "images": .array([]),
        ])
    }

    private func response(_ capture: JSONValue) throws -> Data {
        try JSONValue.object([
            "version": .string(CanvasExportPolicy.version), "html": .string("<p>Visible result</p>"),
            "viewport": capture["viewport"]!, "theme": capture["theme"]!,
        ]).encoded()
    }

    func testPresentationUsesOneFreshBearerPostAndExactCapturedDisplayGeometry() async throws {
        let source = capture()
        let payload = try source.encoded()
        let response = try response(source)
        let calls = CanvasExportCallCount()
        let client = RestClient(
            serverBase: base, tokenProvider: { "synthetic" },
            presentationTransport: { request in
                await calls.increment()
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(
                    request.url?.absoluteString,
                    "https://astral.example.test/api/export/canvas/a%3Fb%23c%252f/presentation?render_revision=7")
                XCTAssertEqual(request.httpBody, payload)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
                return (200, response, "7")
            })
        let result = try await client.canvasPresentation(chatId: "a?b#c%2f", renderRevision: 7, capture: payload)
        XCTAssertEqual(result, response)
        let count = await calls.value
        XCTAssertEqual(count, 1)
    }

    func testDenialUncertainResponseAndRevisionMismatchAreNeverRetried() async throws {
        let payload = try capture().encoded()
        let data = try response(capture())
        for (status, revision): (Int, String?) in [
            (401, "7"), (403, "7"), (409, "7"), (500, "7"),
            (200, nil), (200, "8"), (200, "7, 7"),
        ] {
            let calls = CanvasExportCallCount()
            let client = RestClient(
                serverBase: base, tokenProvider: { "synthetic" },
                presentationTransport: { _ in
                    await calls.increment()
                    return (status, data, revision)
                })
            do {
                _ = try await client.canvasPresentation(chatId: "chat", renderRevision: 7, capture: payload)
                XCTFail("Unqualified response")
            } catch { XCTAssertEqual((error as? URLError)?.code, .badServerResponse) }
            let count = await calls.value
            XCTAssertEqual(count, 1)
        }
        let calls = CanvasExportCallCount()
        let client = RestClient(
            serverBase: base, tokenProvider: { "synthetic" },
            presentationTransport: { _ in
                await calls.increment()
                throw URLError(.networkConnectionLost)
            })
        do {
            _ = try await client.canvasPresentation(chatId: "chat", renderRevision: 7, capture: payload)
            XCTFail("Uncertain request")
        } catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        let count = await calls.value
        XCTAssertEqual(count, 1)
    }

    func testMissingCredentialBadOriginAndOversizeInputDoNotStartHTTP() async throws {
        let payload = try capture().encoded()
        let client = RestClient(
            serverBase: base, tokenProvider: { nil },
            presentationTransport: { _ in
                XCTFail("Anonymous request")
                return (200, Data(), nil)
            })
        do {
            _ = try await client.canvasPresentation(chatId: "chat", renderRevision: 0, capture: payload)
            XCTFail("Anonymous presentation")
        } catch { XCTAssertEqual((error as? URLError)?.code, .userAuthenticationRequired) }
        for url in ["file:///private/export", "https://user@astral.example.test"] {
            let invalid = RestClient(
                serverBase: URL(string: url)!, tokenProvider: { "synthetic" },
                presentationTransport: { _ in
                    XCTFail("Unsafe origin")
                    return (200, Data(), nil)
                })
            do {
                _ = try await invalid.canvasPresentation(chatId: "chat", renderRevision: 0, capture: payload)
                XCTFail("Unsafe origin accepted")
            } catch {}
        }
        XCTAssertThrowsError(try CanvasExportPolicy.validateRequest(Data(repeating: 32, count: 8 * 1024 * 1024 + 1)))
        XCTAssertThrowsError(try CanvasExportPolicy.validateRequest(Data("{}".utf8)))
    }

    func testResponseCannotSubstitutePaletteViewportVersionOrAdditionalFields() throws {
        let source = capture()
        let good = try response(source)
        XCTAssertNoThrow(try CanvasExportPolicy.validateResponse(good, capture: source))
        let fields = try JSONValue.parse(good).objectValue!
        for (key, value): (String, JSONValue) in [
            ("viewport", .object(["width": .number(320)])), ("theme", .object([:])),
            ("version", .string("future")), ("html", .string("")), ("action", .string("dispatch")),
        ] {
            var changed = fields
            changed[key] = value
            XCTAssertThrowsError(
                try CanvasExportPolicy.validateResponse(JSONValue.object(changed).encoded(), capture: source))
        }
        XCTAssertThrowsError(
            try CanvasExportPolicy.validateResponse(Data(repeating: 32, count: 32 * 1024 * 1024 + 1), capture: source))
    }

    func testCancelledCredentialRefreshCannotIssuePresentationRequest() async throws {
        let gate = CanvasExportCredentialGate()
        let payload = try capture().encoded()
        let client = RestClient(
            serverBase: base, tokenProvider: { await gate.resolve() },
            presentationTransport: { _ in
                XCTFail("Cancelled credential refresh must not send display data")
                return (200, Data(), nil)
            })
        let task = Task { try await client.canvasPresentation(chatId: "chat", renderRevision: 7, capture: payload) }
        while !(await gate.waiting) { await Task.yield() }
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("Cancelled export")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}

private actor CanvasExportCallCount {
    var value = 0
    func increment() { value += 1 }
}

private actor CanvasExportCredentialGate {
    private var continuation: CheckedContinuation<String?, Never>?
    var waiting: Bool { continuation != nil }
    func resolve() async -> String? {
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        continuation?.resume(returning: "synthetic")
        continuation = nil
    }
}
