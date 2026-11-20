// Lists the files the Phonon 31m English pack must hold and reports which are missing before any model code runs.
// PhononSpeech checks a folder with it first, so an empty or partial folder fails with a clear error instead of reaching FluidAudio.
import Foundation

enum PhononModelFolder {
    static let requiredFiles: [String] = [
        "arch.json",
        "pocket_state.json",
        "pocket_state.mlmodelc/coremldata.bin",
        "pocket_state.mlmodelc/model.mil",
        "pocket_state.mlmodelc/weights/weight.bin",
        "mimi_decoder.mlmodelc/coremldata.bin",
        "mimi_decoder.mlmodelc/model.mil",
        "mimi_decoder.mlmodelc/weights/weight.bin",
        "constants_bin/bos_emb.bin",
        "constants_bin/text_embed_table.bin",
        "constants_bin/tokenizer.model",
        "constants_bin/default.safetensors",
    ]

    static func missingFiles(in folder: URL) -> [String] {
        let manager = FileManager.default
        return requiredFiles.filter { path in
            var isDirectory: ObjCBool = false
            let exists = manager.fileExists(atPath: folder.appendingPathComponent(path).path, isDirectory: &isDirectory)
            return !exists || isDirectory.boolValue
        }
    }
}
