// Tests the attachment upload filename parameter in RestClient: quotes and line breaks are percent-encoded inside
// one quoted value as browsers send them, while percent signs, plain ASCII and non-ASCII names stay as they are.

import XCTest

@testable import AstralCore

final class AttachmentUploadFilenameTests: XCTestCase {
    func testPlainAsciiNameIsQuotedUnchanged() {
        XCTAssertEqual(RestClient.formDataFilename("report-2026 final.pdf"), "filename=\"report-2026 final.pdf\"")
        XCTAssertEqual(RestClient.formDataFilename("a'b;c=d\\e.txt"), "filename=\"a'b;c=d\\e.txt\"")
    }

    func testQuotesAndLineBreaksArePercentEncodedAndPercentSignsAreKept() {
        XCTAssertEqual(RestClient.formDataFilename("say \"hi\".txt"), "filename=\"say %22hi%22.txt\"")
        XCTAssertEqual(
            RestClient.formDataFilename("a.txt\"\r\nContent-Type: text/html\r\n\r\n"),
            "filename=\"a.txt%22%0D%0AContent-Type: text/html%0D%0A%0D%0A\"")
        XCTAssertEqual(RestClient.formDataFilename("cr\ronly\nlf"), "filename=\"cr%0Donly%0Alf\"")
        XCTAssertEqual(RestClient.formDataFilename("100%.txt"), "filename=\"100%.txt\"")
        XCTAssertEqual(RestClient.formDataFilename("50% off \"now\".txt"), "filename=\"50% off %22now%22.txt\"")
    }

    func testNonAsciiNamesStayUtf8InsideTheQuotedValue() {
        let parameter = RestClient.formDataFilename("café \"menu\" 東京.pdf")
        XCTAssertEqual(parameter, "filename=\"café %22menu%22 東京.pdf\"")
        XCTAssertEqual(Array(parameter.utf8).filter { $0 == UInt8(ascii: "\"") }.count, 2)
    }

    func testEncodedParameterNeverBreaksTheHeaderLine() {
        let names = ["\r", "\n", "\r\n", "\"", "x\u{2028}y", "\u{202E}gpj.exe", "tab\tname"]
        for name in names {
            let parameter = RestClient.formDataFilename(name)
            let bytes = Array(parameter.utf8)
            XCTAssertFalse(bytes.contains(13), name)
            XCTAssertFalse(bytes.contains(10), name)
            XCTAssertEqual(bytes.filter { $0 == UInt8(ascii: "\"") }.count, 2, name)
            XCTAssertTrue(parameter.hasPrefix("filename=\"") && parameter.hasSuffix("\""), name)
        }
    }
}
