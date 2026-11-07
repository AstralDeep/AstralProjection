// Converts server-supplied numbers for rendering. Int(Double) traps on values out of range.

import Foundation

enum RenderNumber {
    static func int(_ value: Double, in range: ClosedRange<Int>) -> Int {
        guard value.isFinite else { return range.lowerBound }
        return Int(min(max(value, Double(range.lowerBound)), Double(range.upperBound)))
    }

    static func pagerRows(offset: Double, size: Double, total: Double) -> (start: Int, end: Int, total: Int)? {
        let limit = 1_000_000_000_000.0
        guard offset.isFinite, size.isFinite, total.isFinite, offset >= 0, size > 0, total >= 0,
            offset <= limit, size <= limit, total <= limit
        else { return nil }
        return (Int(offset) + 1, min(Int(offset + size), Int(total)), Int(total))
    }
}
