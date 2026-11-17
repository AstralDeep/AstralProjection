// Screens text the PHI floor marked clean by asking the on-device model the pinned filter request, chunk by chunk, and hands the model's answers back unaltered.
// The Kernel counts the findings; this adapter reports an absent, refusing or off-schema model as a failure or as absence and never as a clean answer.

import Foundation

nonisolated struct PhiFilterContract: Equatable, Sendable {
    let instructions: String
    let schemaJSON: String
    let budgetBytes: Int
    let chunkBytes: Int
    let maxTokens: Int

    enum LoadError: Error, Equatable { case malformed }

    init(data: Data) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            root["format"] as? String == "astral.phi-filter/v1",
            let instructions = root["instructions"] as? String, !instructions.isEmpty,
            let schema = root["schema"] as? [String: Any],
            let schemaData = try? JSONSerialization.data(
                withJSONObject: schema, options: [.sortedKeys, .withoutEscapingSlashes]),
            let schemaJSON = String(data: schemaData, encoding: .utf8),
            let limits = root["limits"] as? [String: Any],
            let budget = (limits["budget_bytes"] as? NSNumber)?.intValue,
            let chunk = (limits["chunk_bytes"] as? NSNumber)?.intValue,
            budget > 0, chunk > 0
        else { throw LoadError.malformed }
        self.instructions = instructions
        self.schemaJSON = schemaJSON
        budgetBytes = budget
        chunkBytes = chunk
        maxTokens = 2048
    }

    static func bundled() throws -> PhiFilterContract {
        guard let url = Bundle(for: BundleToken.self).url(forResource: "phi_filter", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else { throw LoadError.malformed }
        return try PhiFilterContract(data: data)
    }

    final class BundleToken {}
}

nonisolated enum PhiFilterFailure: Equatable, Sendable {
    case refused
    case answerMissedSchema
    case contextTooLarge
    case model(OnDeviceFailure)
}

nonisolated enum PhiFilterRun: Equatable, Sendable {
    case answers([String])
    case failed(PhiFilterFailure)
    case unavailable(OnDeviceUnavailableReason)
}

private nonisolated struct PhiFilterStop: Error { let run: PhiFilterRun }

nonisolated struct OnDevicePhiFilter: Sendable {
    private let model: any AstralOnDeviceModel
    private let contract: PhiFilterContract
    private let schema: OnDeviceJSONSchema

    init(model: any AstralOnDeviceModel, contract: PhiFilterContract) throws {
        self.model = model
        self.contract = contract
        schema = try OnDeviceJSONSchema(json: contract.schemaJSON)
    }

    static func system(contract: PhiFilterContract) throws -> OnDevicePhiFilter {
        try OnDevicePhiFilter(model: FoundationModelsOnDeviceModel(), contract: contract)
    }

    func chunks(of text: String) -> [String] {
        var rest = Array(text.utf8)
        rest = Array(rest.prefix(Self.cut(rest, limit: contract.budgetBytes)))
        var chunks: [String] = []
        while !rest.isEmpty {
            let at = Self.cut(rest, limit: contract.chunkBytes)
            chunks.append(String(decoding: rest[..<at], as: UTF8.self))
            rest = Array(rest[at...])
        }
        return chunks
    }

    func screen(_ text: String) async -> PhiFilterRun {
        var answers: [String] = []
        for chunk in chunks(of: text) where !chunk.allSatisfy(\.isWhitespace) {
            switch await ask(chunk) {
            case .success(let answer): answers.append(answer)
            case .failure(let stop): return stop.run
            }
        }
        return .answers(answers)
    }

    private func ask(_ chunk: String) async -> Result<String, PhiFilterStop> {
        let request = OnDeviceRequest(
            messages: [
                OnDeviceMessage(role: .system, text: contract.instructions),
                OnDeviceMessage(role: .user, text: chunk),
            ],
            schemaJSON: contract.schemaJSON, maxTokens: contract.maxTokens)
        switch await model.complete(request) {
        case .text(let answer), .json(let answer):
            return schema.accepts(answer) ? .success(answer) : .failure(.init(run: .failed(.answerMissedSchema)))
        case .refused:
            return .failure(.init(run: .failed(.refused)))
        case .unavailable(let reason):
            return .failure(.init(run: .unavailable(reason)))
        case .failed(.contextTooLarge):
            return .failure(.init(run: .failed(.contextTooLarge)))
        case .failed(.outputMismatchedSchema):
            return .failure(.init(run: .failed(.answerMissedSchema)))
        case .failed(let failure):
            return .failure(.init(run: .failed(.model(failure))))
        }
    }

    private static func cut(_ bytes: [UInt8], limit: Int) -> Int {
        guard bytes.count > limit else { return bytes.count }
        var at = limit
        while at > 0 && bytes[at] & 0xC0 == 0x80 { at -= 1 }
        return at
    }
}
