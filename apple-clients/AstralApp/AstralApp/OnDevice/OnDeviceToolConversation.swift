// Preserves real conversation roles and matched tool-result identities in the Foundation Models transcript.
// A tool-call envelope is recognized only when the following tool messages carry all matching results; ordinary assistant JSON stays text.

import Foundation

#if canImport(FoundationModels)
    import FoundationModels

    @available(iOS 26.0, macOS 26.0, *)
    nonisolated enum FoundationToolConversation {
        struct Composed {
            let transcript: Transcript
            let prompt: String
        }

        static func compose(
            _ messages: [OnDeviceMessage], instructions: String,
            definitions: [Transcript.ToolDefinition]
        ) throws -> Composed {
            let conversation = messages.filter {
                $0.role != .system && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            guard let last = conversation.last, last.role == .user else { throw OnDeviceProposalInvalid() }
            var entries: [Transcript.Entry] = [
                .instructions(.init(segments: [.text(.init(content: instructions))], toolDefinitions: definitions))
            ]
            var calls: [String: String] = [:]
            for (index, message) in conversation.dropLast().enumerated() {
                switch message.role {
                case .user:
                    entries.append(.prompt(.init(segments: [.text(.init(content: message.text))])))
                case .assistant:
                    if let envelope = envelope(message.text),
                        let proposals = envelope["tool_calls"] as? [[String: String]], !proposals.isEmpty,
                        proposals.count <= 64, index + proposals.count < conversation.count,
                        Set(proposals.compactMap { $0["id"] }).count == proposals.count,
                        proposals.allSatisfy({
                            Set($0.keys) == ["id", "name", "arguments"] && $0["id"]?.isEmpty == false
                                && calls[$0["id"]!] == nil
                        }),
                        Set(conversation[(index + 1)...(index + proposals.count)].compactMap(resultID))
                            == Set(proposals.compactMap { $0["id"] })
                    {
                        let text = envelope["text"] as? String ?? ""
                        if !text.isEmpty {
                            entries.append(.response(.init(assetIDs: [], segments: [.text(.init(content: text))])))
                        }
                        let typed = try proposals.map { call in
                            let id = call["id"]!
                            let name = call["name"]!
                            calls[id] = name
                            return Transcript.ToolCall(
                                id: id, toolName: name, arguments: try GeneratedContent(json: call["arguments"]!))
                        }
                        entries.append(.toolCalls(.init(typed)))
                    } else {
                        entries.append(.response(.init(assetIDs: [], segments: [.text(.init(content: message.text))])))
                    }
                case .tool:
                    guard let value = object(message.text), Set(value.keys) == ["tool_call_id", "result"],
                        let id = value["tool_call_id"] as? String, let name = calls[id],
                        let result = value["result"] as? String
                    else { throw OnDeviceProposalInvalid() }
                    entries.append(
                        .toolOutput(.init(id: id, toolName: name, segments: [.text(.init(content: result))])))
                case .system:
                    throw OnDeviceProposalInvalid()
                }
            }
            return Composed(transcript: Transcript(entries: entries), prompt: last.text)
        }

        private static func object(_ text: String) -> [String: Any]? {
            guard let data = text.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        private static func envelope(_ text: String) -> [String: Any]? {
            guard let value = object(text), Set(value.keys) == ["text", "tool_calls"], value["text"] is String else {
                return nil
            }
            return value
        }
        private static func resultID(_ message: OnDeviceMessage) -> String? {
            guard message.role == .tool, let value = object(message.text),
                Set(value.keys) == ["tool_call_id", "result"], value["result"] is String
            else { return nil }
            return value["tool_call_id"] as? String
        }
    }
#endif
