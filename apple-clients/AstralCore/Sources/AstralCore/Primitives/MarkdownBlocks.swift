// Splits markdown source into coarse blocks (headings, fences, lists, tables) for markdown-variant text and
// narrative doc cards, defaulting to paragraph when structure is ambiguous. Styled per block by
// MarkdownBlockView.

import Foundation

public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(String)
    case bullets(items: [String], ordered: Bool, start: Int)
    case table(rows: [[String]], hasHeader: Bool)
    case divider
}

public enum MarkdownBlocks {

    public static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var bulletsOrdered = false
        var bulletsStart = 1
        var tableRows: [[String]] = []
        var tableRawLines: [String] = []
        var tableHasHeader = false
        var codeLines: [String] = []
        var inCode = false
        var codeQuoted = false

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }
        func flushBullets() {
            if !bullets.isEmpty {
                blocks.append(
                    .bullets(
                        items: bullets, ordered: bulletsOrdered,
                        start: bulletsStart))
            }
            bullets = []
            bulletsStart = 1
        }
        func flushTable() {
            defer {
                tableRows = []
                tableRawLines = []
                tableHasHeader = false
            }
            guard !tableRows.isEmpty else { return }
            if tableHasHeader || tableRows.count >= 2 {
                blocks.append(.table(rows: tableRows, hasHeader: tableHasHeader))
            } else {
                blocks.append(.paragraph(tableRawLines.joined(separator: "\n")))
            }
        }
        func flushAll() {
            flushParagraph()
            flushBullets()
            flushTable()
        }

        for rawLine in source.components(separatedBy: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            let indent = rawLine.prefix(while: { $0 == " " }).count

            var quoted = false
            if !inCode || codeQuoted {
                while line.hasPrefix("> ") || line == ">" {
                    quoted = true
                    line = line == ">" ? "" : String(line.dropFirst(2))
                }
            }

            if inCode {
                if line.hasPrefix("```") {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines = []
                    inCode = false
                } else {
                    codeLines.append(codeQuoted ? line : rawLine)
                }
                continue
            }

            if line.hasPrefix("```") {
                flushAll()
                inCode = true
                codeQuoted = quoted
                continue
            }

            if line.isEmpty {
                flushParagraph()
                flushBullets()
                flushTable()
                continue
            }

            if line.hasPrefix("|"), line.hasSuffix("|"), line.count >= 2,
                line.dropFirst().contains("|")
            {
                flushParagraph()
                flushBullets()
                let cells = tableCells(line)
                if isTableSeparator(cells) {
                    if tableRows.count == 1 { tableHasHeader = true }
                } else if !cells.isEmpty {
                    tableRows.append(cells)
                    tableRawLines.append(line)
                }
                continue
            }
            flushTable()

            if let (level, text) = headingLine(line) {
                flushAll()
                blocks.append(.heading(level: level, text: text))
                continue
            }

            if isDividerLine(line) {
                flushAll()
                blocks.append(.divider)
                continue
            }

            if let item = bulletLine(line) {
                flushParagraph()
                if !bullets.isEmpty && indent >= 2 {
                    bullets[bullets.count - 1] += "\n◦ " + item.text
                    continue
                }
                if !bullets.isEmpty && bulletsOrdered != item.ordered { flushBullets() }
                if bullets.isEmpty {
                    bulletsOrdered = item.ordered
                    bulletsStart = item.number ?? 1
                }
                bullets.append(item.text)
                continue
            }

            if !bullets.isEmpty && indent >= 2 {
                bullets[bullets.count - 1] += " " + line
                continue
            }
            flushBullets()

            paragraph.append(line)
        }

        if inCode { blocks.append(.code(codeLines.joined(separator: "\n"))) }
        flushAll()
        return blocks
    }

    public static func plainText(_ source: String) -> String {
        parse(source).compactMap { block -> String? in
            switch block {
            case .heading(_, let text): return text
            case .paragraph(let text): return text
            case .code(let text): return text
            case .bullets(let items, let ordered, let start):
                return items.enumerated().map { index, item in
                    ordered ? "\(start + index). \(item)" : "• \(item)"
                }.joined(separator: "\n")
            case .table(let rows, _):
                return rows.map { $0.joined(separator: " · ") }.joined(separator: "\n")
            case .divider: return nil
            }
        }.joined(separator: "\n")
    }

    private static func headingLine(_ line: String) -> (Int, String)? {
        guard line.hasPrefix("#") else { return nil }
        let level = line.prefix(while: { $0 == "#" }).count
        guard level <= 6 else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (level, text)
    }

    private static func bulletLine(_ line: String) -> (text: String, ordered: Bool, number: Int?)? {
        if let first = line.first, "-*+".contains(first),
            line.dropFirst().first == " "
        {
            return (line.dropFirst(2).trimmingCharacters(in: .whitespaces), false, nil)
        }
        let digits = line.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 3 {
            let rest = line.dropFirst(digits.count)
            if rest.first == "." || rest.first == ")", rest.dropFirst().first == " " {
                return (
                    rest.dropFirst(2).trimmingCharacters(in: .whitespaces),
                    true, Int(digits)
                )
            }
        }
        return nil
    }

    private static func isDividerLine(_ line: String) -> Bool {
        line.count >= 3 && (Set(line) == ["-"] || Set(line) == ["*"] || Set(line) == ["_"])
    }

    private static func tableCells(_ line: String) -> [String] {
        var trimmed = line
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableSeparator(_ cells: [String]) -> Bool {
        !cells.isEmpty
            && cells.allSatisfy { cell in
                !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" } && cell.contains("-")
            }
    }
}
