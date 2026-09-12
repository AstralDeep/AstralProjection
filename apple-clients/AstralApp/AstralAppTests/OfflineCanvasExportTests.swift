import AstralCore
import XCTest

@testable import AstralDeep

@MainActor
final class OfflineCanvasExportTests: XCTestCase {
    private func presentation(
        html: String =
            "<div class=\"dynamic-renderer\"><div class=\"astral-text\"><p>Visible local result</p></div></div>"
    ) throws
        -> Data
    {
        let roles = [
            "bg", "surface", "surface2", "primary", "secondary", "accent", "text", "muted",
            "success", "warning", "error", "info",
        ]
        var theme = Dictionary(uniqueKeysWithValues: roles.map { ($0, JSONValue.string("#253047")) })
        theme["border"] = .string("#FFFFFF14")
        return try JSONValue.object([
            "version": .string(CanvasExportPolicy.version), "html": .string(html), "theme": .object(theme),
            "viewport": .object([
                "width": .number(296), "height": .number(480),
                "window_width": .number(320), "window_height": .number(700),
            ]),
        ]).encoded()
    }

    func testBundledDocumentEncodesUntrustedPresentationAndKeepsWindowGeometry() throws {
        let data = try presentation(html: "</script><script>private_input</script>")
        let html = try OfflineCanvasExportDocument.html(presentation: data)
        XCTAssertFalse(html.contains("private_input"))
        XCTAssertFalse(html.contains("__ASTRAL_EXPORT_PRESENTATION_BASE64__"))
        XCTAssertTrue(html.contains(data.base64EncodedString()))
        XCTAssertEqual(try OfflineCanvasExportDocument.windowSize(data), CGSize(width: 320, height: 700))
        XCTAssertThrowsError(try OfflineCanvasExportDocument.windowSize(Data("{}".utf8)))
    }

    func testRealPrivateWebKitReturnsSelfContainedScriptFreeHTML() async throws {
        let output = try await OfflineCanvasExport.render(presentation: presentation(), isCurrent: { true })
        let html = try XCTUnwrap(String(data: output, encoding: .utf8))
        XCTAssertTrue(html.contains("Visible local result"))
        XCTAssertTrue(html.contains("script-src 'none'"))
        XCTAssertTrue(html.contains("data:font/woff2;base64,"))
        XCTAssertFalse(html.lowercased().contains("<script"))
        XCTAssertFalse(html.contains("data-component-id"))
    }

    func testForeignImageCannotBeFetchedOrExportedAsBlankSuccess() async throws {
        let data = try presentation(html: "<img src=\"https://export-denied.invalid/private-image.png\">")
        do {
            _ = try await OfflineCanvasExport.render(presentation: data, isCurrent: { true })
            XCTFail("A missing offline image must not create a successful file")
        } catch { XCTAssertTrue(error is CanvasExportFailure) }
    }

    func testOwnerChangesAndCancellationDiscardThePrivateDocument() async throws {
        let data = try presentation()
        var checks = 0
        do {
            _ = try await OfflineCanvasExport.render(
                presentation: data,
                isCurrent: {
                    checks += 1
                    return checks < 4
                })
            XCTFail("Old owner document")
        } catch { XCTAssertTrue(error is CancellationError) }
        let task = Task { try await OfflineCanvasExport.render(presentation: data, isCurrent: { true }) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled document")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}
