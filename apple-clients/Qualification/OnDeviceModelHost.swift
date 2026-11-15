// Runs the production Foundation Models adapter over a bounded local standard-input protocol for manual model qualification.
// It accepts synthetic requests from the Kernel qualification driver and exports no account state or credentials.

import Foundation

private struct Request: Decodable {
    struct Message: Decodable {
        let role: String
        let content: String
    }
    let id: Int
    let messages: [Message]
    let json_schema: String?
    let max_tokens: Int
}

@main
private struct OnDeviceModelHost {
    static func emit(_ value: [String: Any]) throws {
        var bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        bytes.append(10)
        try FileHandle.standardOutput.write(contentsOf: bytes)
    }

    static func main() async throws {
        let model = FoundationModelsOnDeviceModel()
        guard model.available() else {
            try emit(["status": "unavailable", "code": String(describing: model.availability())])
            return
        }
        try emit(["status": "ready", "model": "FoundationModels.default"])
        while let line = readLine() {
            guard line.utf8.count <= 1_048_576,
                let request = try? JSONDecoder().decode(Request.self, from: Data(line.utf8)),
                request.id > 0, request.messages.count <= 128,
                (1...4096).contains(request.max_tokens)
            else {
                try emit(["id": 0, "status": "failed", "code": "invalid_request"])
                continue
            }
            let messages = request.messages.compactMap { message -> OnDeviceMessage? in
                guard let role = OnDeviceMessage.Role(rawValue: message.role) else { return nil }
                return OnDeviceMessage(role: role, text: message.content)
            }
            guard messages.count == request.messages.count else {
                try emit(["id": request.id, "status": "failed", "code": "invalid_role"])
                continue
            }
            let result = await model.complete(
                OnDeviceRequest(
                    messages: messages, schemaJSON: request.json_schema, maxTokens: request.max_tokens))
            var output: [String: Any] = ["id": request.id]
            switch result {
            case .text(let text): output.merge(["status": "text", "text": text]) { _, value in value }
            case .json(let text): output.merge(["status": "json", "text": text]) { _, value in value }
            case .refused: output.merge(["status": "refused", "code": "refused"]) { _, value in value }
            case .unavailable(let reason):
                output.merge(["status": "unavailable", "code": reason.rawValue]) { _, value in value }
            case .failed(let failure):
                output.merge(["status": "failed", "code": failure.rawValue]) { _, value in value }
            }
            try emit(output)
        }
    }
}
