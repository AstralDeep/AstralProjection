// Path comparison for the execution policy on macOS: the canonical caseless fold computed only from the committed Unicode 16.0 table in Resources/Exec/path_fold.json.
// ExecPolicy and ExecBackends use it for overlap, duplicate and data-directory checks, because APFS treats case and normalization variants as one name.

import Foundation

enum ExecPathFold {
    private struct Table {
        var decompose: [UInt32: [UInt32]] = [:]
        var fold: [UInt32: [UInt32]] = [:]
        var combining: [UInt32: UInt8] = [:]
        var assigned: [(low: UInt32, high: UInt32)] = []
    }

    private static let table: Table = {
        guard let url = Bundle.module.url(forResource: "path_fold", withExtension: "json", subdirectory: "Exec"),
            let data = try? Data(contentsOf: url),
            let root = try? ExecJSON.parse(data)
        else { preconditionFailure("the path fold table is missing from AstralCore") }
        var table = Table()
        func code(_ key: String) -> UInt32 { UInt32(key, radix: 16) ?? 0 }
        func expansion(_ value: ExecJSON) -> [UInt32] { (value.stringValue ?? "").unicodeScalars.map(\.value) }
        if case .object(let members) = root["decompose"] {
            for member in members { table.decompose[code(member.key)] = expansion(member.value) }
        }
        if case .object(let members) = root["fold"] {
            for member in members { table.fold[code(member.key)] = expansion(member.value) }
        }
        if case .object(let members) = root["ccc"] {
            for member in members { table.combining[code(member.key)] = UInt8(member.value.intValue ?? 0) }
        }
        for range in root["assigned"]?.arrayValue ?? [] {
            if let pair = range.arrayValue, pair.count == 2, let low = pair[0].intValue, let high = pair[1].intValue {
                table.assigned.append((UInt32(low), UInt32(high)))
            }
        }
        return table
    }()

    private static let hangulBase: UInt32 = 0xAC00
    private static let hangulCount: UInt32 = 11172
    private static let jamoLead: UInt32 = 0x1100
    private static let jamoVowel: UInt32 = 0x1161
    private static let jamoTail: UInt32 = 0x11A7
    private static let vowelCount: UInt32 = 21
    private static let tailCount: UInt32 = 28

    static func isAssigned(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        var low = 0
        var high = table.assigned.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let range = table.assigned[middle]
            if value < range.low {
                high = middle - 1
            } else if value > range.high {
                low = middle + 1
            } else {
                return true
            }
        }
        return false
    }

    private static func ordered(_ scalars: [UInt32]) -> [UInt32] {
        var out = [UInt32]()
        var run = [UInt32]()
        func flush() {
            var sorted = [UInt32]()
            for mark in run {
                let rank = table.combining[mark] ?? 0
                var position = sorted.count
                while position > 0, (table.combining[sorted[position - 1]] ?? 0) > rank { position -= 1 }
                sorted.insert(mark, at: position)
            }
            out += sorted
            run = []
        }
        for scalar in scalars {
            if (table.combining[scalar] ?? 0) != 0 {
                run.append(scalar)
            } else {
                flush()
                out.append(scalar)
            }
        }
        flush()
        return out
    }

    private static func decomposed(_ scalars: [UInt32]) -> [UInt32] {
        var pieces = [UInt32]()
        for scalar in scalars {
            if scalar >= hangulBase, scalar - hangulBase < hangulCount {
                let index = scalar - hangulBase
                let lead = index / (vowelCount * tailCount)
                let rest = index % (vowelCount * tailCount)
                pieces += [jamoLead + lead, jamoVowel + rest / tailCount]
                if rest % tailCount != 0 { pieces.append(jamoTail + rest % tailCount) }
            } else if let expansion = table.decompose[scalar] {
                pieces += expansion
            } else {
                pieces.append(scalar)
            }
        }
        return ordered(pieces)
    }

    static func fold(_ path: String) -> [UInt32] {
        let first = decomposed(path.unicodeScalars.map(\.value))
        var mapped = [UInt32]()
        for scalar in first { mapped += table.fold[scalar] ?? [scalar] }
        return decomposed(mapped)
    }

    static func folded(_ path: String, platform: String?) -> [UInt32] {
        platform == "darwin" ? fold(path) : path.unicodeScalars.map(\.value)
    }

    static func contains(_ root: String, _ path: String, platform: String?) -> Bool {
        let base = folded(root, platform: platform)
        let target = folded(path, platform: platform)
        if target == base { return true }
        return target.count > base.count && Array(target[0..<base.count]) == base && target[base.count] == 0x2F
    }
}
