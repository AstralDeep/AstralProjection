// Verifies that host signing bytes use the shared strict parser and reject ambiguous JSON.
import Foundation
import XCTest

@testable import AstralKernel

final class KernelCanonicalJSONTests: XCTestCase {
    func testCanonicalizesWithoutAStore() throws {
        let input = Data(#"{ "z": 1, "a": [true, null], "é": "value" }"#.utf8)
        let expected = Data(#"{"a":[true,null],"z":1,"é":"value"}"#.utf8)
        let canonical = try KernelCanonicalJSON.canonicalize(input)
        XCTAssertEqual(canonical, expected)
        XCTAssertEqual(try KernelCanonicalJSON.canonicalize(canonical), canonical)
    }

    func testRefusesDuplicateKeysFloatsRangeAndInvalidUTF8() {
        let malformed = [#"{"a":1,"a":2}"#, "1.5", "9223372036854775808", "{", #""\ud800""#]
        for input in malformed {
            XCTAssertThrowsError(try KernelCanonicalJSON.canonicalize(Data(input.utf8)))
        }
        XCTAssertThrowsError(try KernelCanonicalJSON.canonicalize(Data([0xff])))
    }
}
