// Classifies one complete Swift source through the selected toolchain's lossless parser and conditional evaluator.
// swift_inactive_input.py combines this result with native target identity and independent typed AST and SIL checks.

import Foundation
import SwiftIfConfig
import SwiftParser
import SwiftSyntax

struct Predicate: Encodable {
    let kind = "os"
    let name: String
}

struct SyntaxResult: Encodable {
    let format = "astral.swift-whole-os-syntax/v1"
    var sourceBytes = 0
    var targetOs = ""
    var decision = "refused"
    var predicate: Predicate?
    var statementCount = 0
    var clauseCount = 0
    var roundtrip = false
    var parserError = true
    var diagnosticCount = 0
}

func classify() -> SyntaxResult {
    var result = SyntaxResult()
    guard CommandLine.arguments.count == 3 else { return result }
    result.targetOs = CommandLine.arguments[2]
    guard ["iOS", "macOS", "watchOS"].contains(result.targetOs) else { return result }
    do {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        result.sourceBytes = bytes.count
        guard !bytes.isEmpty, bytes.count <= 16 * 1024 * 1024,
            let text = String(data: bytes, encoding: .utf8)
        else { return result }
        let tree = Parser.parse(source: text)
        result.roundtrip = Data(tree.description.utf8) == bytes
        result.parserError = tree.hasError
        result.statementCount = tree.statements.count
        guard result.roundtrip, !tree.hasError, tree.statements.count == 1,
            let statement = tree.statements.first,
            let outer = statement.item.as(IfConfigDeclSyntax.self)
        else { return result }
        result.clauseCount = outer.clauses.count
        guard outer.clauses.count == 1, let clause = outer.clauses.first,
            clause.poundKeyword.tokenKind == .poundIf,
            let condition = clause.condition,
            let call = condition.as(FunctionCallExprSyntax.self),
            let name = call.calledExpression.as(DeclReferenceExprSyntax.self),
            name.baseName.tokenKind == .identifier("os"), name.argumentNames == nil,
            call.leftParen?.tokenKind == .leftParen, call.rightParen?.tokenKind == .rightParen,
            call.trailingClosure == nil, call.additionalTrailingClosures.isEmpty,
            call.arguments.count == 1, let argument = call.arguments.first,
            argument.label == nil, argument.colon == nil, argument.trailingComma == nil,
            let value = argument.expression.as(DeclReferenceExprSyntax.self),
            value.argumentNames == nil, ["iOS", "macOS", "watchOS"].contains(value.baseName.text)
        else { return result }
        result.predicate = Predicate(name: value.baseName.text)
        let configuration = StaticBuildConfiguration(
            targetOSs: [result.targetOs], languageVersion: VersionTuple(5),
            compilerVersion: VersionTuple(6)
        )
        let (state, _, diagnostics) = IfConfigRegionState.evaluating(
            condition, in: configuration
        )
        result.diagnosticCount = diagnostics.count
        guard diagnostics.isEmpty else { return result }
        switch state {
        case .inactive: result.decision = "inactive"
        case .active: result.decision = "active"
        case .unparsed: break
        @unknown default: break
        }
    } catch {
        return result
    }
    return result
}

let encoder = JSONEncoder()
encoder.keyEncodingStrategy = .convertToSnakeCase
if let data = try? encoder.encode(classify()) {
    FileHandle.standardOutput.write(data)
}
