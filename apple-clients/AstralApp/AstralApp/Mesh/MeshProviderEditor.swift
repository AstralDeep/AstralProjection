// Keeps the model-provider form draft until the Kernel confirms its sealed write.
// MeshModelProviderView binds these fields and MeshRuntime serializes provider mutations.

import Foundation
import Observation

@MainActor
@Observable
final class MeshProviderEditor {
    var baseURL = "" { didSet { saved = false } }
    var model = "" { didSet { saved = false } }
    var key = "" { didSet { saved = false } }
    var recipients: [String]? { didSet { saved = false } }
    private(set) var problem: MeshProviderInputError?
    private(set) var saved = false
    private(set) var saving = false

    func save(in runtime: MeshRuntime) async {
        guard !saving else { return }
        saving = true
        saved = false
        defer { saving = false }
        let submitted = MeshModelProviderConfig(baseURL: baseURL, model: model, apiKey: key, recipients: recipients)
        problem = await runtime.saveProvider(
            baseURL: submitted.baseURL, model: submitted.model, key: submitted.apiKey, recipients: submitted.recipients)
        guard problem == nil, baseURL == submitted.baseURL, model == submitted.model,
            key == submitted.apiKey, recipients == submitted.recipients
        else { return }
        key = ""
        saved = true
    }
}
