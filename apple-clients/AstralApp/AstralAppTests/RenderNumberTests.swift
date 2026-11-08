// Verifies server-supplied numbers cannot trap the renderers that show ratings, grids, skeletons and pagers.

import XCTest

@testable import AstralDeep

final class RenderNumberTests: XCTestCase {
    func testOutOfRangeValuesClampInsteadOfTrapping() {
        XCTAssertEqual(RenderNumber.int(1e19, in: 1...10), 10)
        XCTAssertEqual(RenderNumber.int(-1e19, in: 1...10), 1)
        XCTAssertEqual(RenderNumber.int(.infinity, in: 0...5), 0)
        XCTAssertEqual(RenderNumber.int(.nan, in: 0...5), 0)
        XCTAssertEqual(RenderNumber.int(4, in: 0...5), 4)
    }

    func testPagerHidesRowsItCannotShow() {
        XCTAssertNil(RenderNumber.pagerRows(offset: 1e19, size: 10, total: 100))
        XCTAssertNil(RenderNumber.pagerRows(offset: 0, size: 10, total: 1e19))
        XCTAssertNil(RenderNumber.pagerRows(offset: -1, size: 10, total: 100))
        XCTAssertNil(RenderNumber.pagerRows(offset: .nan, size: 10, total: 100))
        let page = RenderNumber.pagerRows(offset: 90, size: 20, total: 100)
        XCTAssertEqual(page?.start, 91)
        XCTAssertEqual(page?.end, 100)
        XCTAssertEqual(page?.total, 100)
    }
}
