// Drafts a short spoken acknowledgement with the on-device model while the owner's chosen model works on the full answer.
// VoicePipeline starts a draft on a stable partial transcript, discards it when the person keeps talking, and speaks it only if no answer text has arrived.

import Foundation

nonisolated enum VoiceAcknowledgement {
    static let maximumWords = 8
    static let maximumCharacters = 80
    private static let phrases: Set<String> = [
        "Okay.", "Sure.", "One moment.", "Sure, one moment.", "Let me check.", "I heard you.",
    ]

    static func sanitize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
        if let firstLine = text.split(whereSeparator: \.isNewline).first { text = String(firstLine) }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count <= maximumCharacters, !text.contains("?"),
            text.split(whereSeparator: \.isWhitespace).count <= maximumWords, phrases.contains(text)
        else { return nil }
        return text
    }

    static func request(for transcript: String) -> OnDeviceRequest {
        OnDeviceRequest(
            messages: [
                OnDeviceMessage(
                    role: .system,
                    text:
                        "Choose exactly one acknowledgement from this list: "
                        + phrases.sorted().joined(separator: " | ")
                        + " Do not answer the request, state facts, claim an action happened, or add any other words."
                ),
                OnDeviceMessage(role: .user, text: transcript),
            ],
            schemaJSON: nil, maxTokens: 24)
    }
}

@MainActor
final class VoiceFastPath {
    private struct Draft {
        let transcript: String
        let task: Task<String?, Never>
    }

    private let model: AstralOnDeviceModel
    private var draft: Draft?

    init(model: AstralOnDeviceModel) {
        self.model = model
    }

    var isEnabled: Bool { model.available() }

    var hasDraft: Bool { draft != nil }

    func warm() async {
        guard isEnabled else { return }
        await (model as? AstralOnDeviceModelWarmable)?.prewarm()
    }

    func speculate(_ transcript: String) {
        let normalized = Self.normalize(transcript)
        guard isEnabled, !normalized.isEmpty, draft.map({ Self.normalize($0.transcript) != normalized }) ?? true
        else { return }
        draft?.task.cancel()
        draft = Draft(transcript: transcript, task: Self.start(model: model, transcript: transcript))
    }

    func discard() {
        draft?.task.cancel()
        draft = nil
    }

    func acknowledgement(forFinal transcript: String) async -> String? {
        guard isEnabled else { return nil }
        let current: Draft
        if let existing = draft, Self.normalize(existing.transcript) == Self.normalize(transcript) {
            current = existing
        } else {
            discard()
            current = Draft(transcript: transcript, task: Self.start(model: model, transcript: transcript))
            draft = current
        }
        let result = await current.task.value
        if draft?.transcript == current.transcript { draft = nil }
        return Task.isCancelled ? nil : result
    }

    private static func start(model: AstralOnDeviceModel, transcript: String) -> Task<String?, Never> {
        Task.detached {
            let response = await model.complete(VoiceAcknowledgement.request(for: transcript))
            guard !Task.isCancelled, case .text(let text) = response else { return nil }
            return VoiceAcknowledgement.sanitize(text)
        }
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
