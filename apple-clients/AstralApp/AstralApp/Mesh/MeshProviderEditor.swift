// Keeps the model-provider form draft until the Kernel confirms its sealed write.
// MeshModelProviderView binds these fields and MeshRuntime serializes provider mutations.

import Foundation
import Observation

enum MeshProviderPlaceholder {
    static let name = "openai"
    static let baseURL = "https://api.openai.com/v1"
    static let model = "gpt-4o"
    static let key = "sk-..."
}

@MainActor
@Observable
final class MeshProviderEditor {
    var providerName = "" {
        didSet {
            let lowered = providerName.lowercased()
            if lowered != providerName { providerName = lowered }
            saved = false
        }
    }
    var baseURL = "" { didSet { saved = false } }
    var model = "" { didSet { saved = false } }
    var key = "" { didSet { saved = false } }
    var recipients: [String]? { didSet { saved = false } }
    private(set) var problem: MeshProviderInputError?
    private(set) var saved = false
    private(set) var saving = false

    var nameProblem: MeshProviderInputError? {
        let typed = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty || MeshProviderInput.isValidName(typed) ? nil : .invalidName
    }

    var canSave: Bool { !saving && MeshProviderInput.isValidName(providerName) }

    func save(in runtime: MeshRuntime) async {
        guard !saving else { return }
        saving = true
        saved = false
        defer { saving = false }
        let submitted = MeshModelProviderConfig(
            baseURL: baseURL, model: model, apiKey: key, recipients: recipients, name: providerName)
        problem = await runtime.saveModelConnection(
            name: providerName, baseURL: submitted.baseURL, model: submitted.model, key: submitted.apiKey,
            recipients: submitted.recipients)
        guard problem == nil, providerName == submitted.name, baseURL == submitted.baseURL,
            model == submitted.model, key == submitted.apiKey, recipients == submitted.recipients
        else { return }
        key = ""
        saved = true
    }
}
