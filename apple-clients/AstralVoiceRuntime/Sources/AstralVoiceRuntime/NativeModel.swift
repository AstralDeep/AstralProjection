// Owns one native llama.cpp model and context and runs the token loop for a prompt, checking task cancellation and the native abort flag between tokens.
// It is not thread-safe: SpeechRecognizer and TextGenerator confine each instance to their own serial queue and only use it while holding the scheduler.
import CAstralLlama
import Foundation

struct NativeOutcome: Sendable {
    var text: String
    var tokenCount: Int
    var stop: StopReason
}

struct NativeSampling: Sendable {
    var temperature: Float
    var topK: Int
    var seed: UInt32

    static let greedy = NativeSampling(temperature: 0, topK: 0, seed: 0)
}

final class NativeModel: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let encoderURL: URL?

    private init(handle: OpaquePointer, encoderURL: URL?) {
        self.handle = handle
        self.encoderURL = encoderURL
    }

    deinit { close() }

    static func load(model: URL, encoder: URL?, configuration: RuntimeConfiguration) throws -> NativeModel {
        try configuration.validate()
        for url in [model] + (encoder.map { [$0] } ?? []) where !FileManager.default.fileExists(atPath: url.path) {
            throw VoiceRuntimeError.fileNotFound(url)
        }
        let options = avr_options(
            cpu_only: configuration.compute == .cpuOnly,
            context_tokens: Int32(configuration.contextTokens),
            batch_tokens: Int32(configuration.batchTokens),
            threads: Int32(configuration.threads)
        )
        var status = AVR_OK
        let handle = model.path.withCString { modelPath in
            if let encoder {
                return encoder.path.withCString { avr_model_load(modelPath, $0, options, &status) }
            }
            return avr_model_load(modelPath, nil, options, &status)
        }
        guard let handle else {
            switch status {
            case AVR_ENCODER_LOAD_FAILED: throw VoiceRuntimeError.encoderLoadFailed(encoder ?? model)
            case AVR_ENCODER_WITHOUT_AUDIO: throw VoiceRuntimeError.encoderHasNoAudioInput(encoder ?? model)
            case AVR_CONTEXT_FAILED: throw VoiceRuntimeError.contextCreationFailed
            case AVR_INVALID_ARGUMENT: throw VoiceRuntimeError.invalidConfiguration("rejected by the runtime")
            default: throw VoiceRuntimeError.modelLoadFailed(model)
            }
        }
        return NativeModel(handle: handle, encoderURL: encoder)
    }

    func close() {
        guard let handle else { return }
        avr_model_free(handle)
        self.handle = nil
    }

    var contextTokens: Int {
        handle.map { Int(avr_model_context_tokens($0)) } ?? 0
    }

    func chatPrompt(_ messages: [(role: String, content: String)]) throws -> String {
        let handle = try open()
        var status = AVR_OK
        var roles = messages.map { strdup($0.role) }
        var contents = messages.map { strdup($0.content) }
        defer {
            roles.forEach { free($0) }
            contents.forEach { free($0) }
        }
        let rendered = roles.withUnsafeMutableBufferPointer { roleBuffer in
            contents.withUnsafeMutableBufferPointer { contentBuffer in
                avr_model_chat_prompt(
                    handle,
                    UnsafeRawPointer(roleBuffer.baseAddress!).assumingMemoryBound(to: UnsafePointer<CChar>?.self),
                    UnsafeRawPointer(contentBuffer.baseAddress!).assumingMemoryBound(to: UnsafePointer<CChar>?.self),
                    messages.count,
                    &status
                )
            }
        }
        guard let rendered else { throw VoiceRuntimeError.chatTemplateUnavailable }
        defer { avr_string_free(rendered) }
        return String(cString: rendered)
    }

    func generate(prompt: String, sampling: NativeSampling, limit: Int, cancel: CancelFlag, onText: (String) -> Void) throws -> NativeOutcome {
        let handle = try open()
        var promptTokens: Int32 = 0
        let status = prompt.withCString {
            avr_begin_text(handle, $0, nativeSampling(sampling), cancel.handle, &promptTokens)
        }
        return try loop(handle, beginStatus: status, limit: limit, onText: onText)
    }

    func recognize(prompt: String, samples: [Float], limit: Int, cancel: CancelFlag, onText: (String) -> Void) throws -> NativeOutcome {
        let handle = try open()
        var promptTokens: Int32 = 0
        let status = prompt.withCString { text in
            samples.withUnsafeBufferPointer {
                avr_begin_audio(handle, text, $0.baseAddress, $0.count, nativeSampling(.greedy), cancel.handle, &promptTokens)
            }
        }
        return try loop(handle, beginStatus: status, limit: limit, onText: onText)
    }

    private func open() throws -> OpaquePointer {
        guard let handle else { throw VoiceRuntimeError.unloaded }
        return handle
    }

    private func nativeSampling(_ sampling: NativeSampling) -> avr_sampling {
        avr_sampling(temperature: sampling.temperature, top_k: Int32(sampling.topK), seed: sampling.seed)
    }

    private func loop(_ handle: OpaquePointer, beginStatus: avr_status, limit: Int, onText: (String) -> Void) throws -> NativeOutcome {
        try check(beginStatus)
        var assembler = Utf8Assembler()
        var text = ""
        var count = 0
        var piece = [CChar](repeating: 0, count: 512)
        var stop = StopReason.tokenLimit
        while count < limit {
            try Task.checkCancellation()
            var length: Int32 = 0
            let status = avr_next(handle, &piece, Int32(piece.count), &length)
            if status == AVR_END {
                stop = .endOfSequence
                break
            }
            if status == AVR_CONTEXT_FULL {
                stop = .contextFull
                break
            }
            try check(status)
            count += 1
            let bytes = piece[0..<Int(length)].map { UInt8(bitPattern: $0) }
            let delta = assembler.append(bytes)
            if !delta.isEmpty {
                text += delta
                onText(delta)
            }
        }
        let tail = assembler.finish()
        if !tail.isEmpty {
            text += tail
            onText(tail)
        }
        return NativeOutcome(text: text, tokenCount: count, stop: stop)
    }

    private func check(_ status: avr_status) throws {
        switch status {
        case AVR_OK, AVR_TOKEN: return
        case AVR_CANCELLED: throw CancellationError()
        case AVR_TOKENIZE_FAILED: throw VoiceRuntimeError.tokenizationFailed
        case AVR_PROMPT_TOO_LONG: throw VoiceRuntimeError.promptTooLong
        case AVR_ENCODE_FAILED: throw VoiceRuntimeError.encodeFailed
        case AVR_ENCODER_WITHOUT_AUDIO: throw VoiceRuntimeError.encoderHasNoAudioInput(encoderURL ?? URL(fileURLWithPath: "/"))
        case AVR_NO_CHAT_TEMPLATE: throw VoiceRuntimeError.chatTemplateUnavailable
        default: throw VoiceRuntimeError.decodeFailed
        }
    }
}
