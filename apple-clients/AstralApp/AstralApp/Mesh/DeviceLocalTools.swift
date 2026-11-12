// The tools this device offers the kernel: none yet, so the kernel plans only with its own and remote tools.
// A call for any name is refused rather than ignored, so a stale ticket cannot reach a missing tool.

import Foundation

nonisolated struct DeviceLocalTools: MeshLocalTools {
    func list() -> [MeshLocalToolSpec] { [] }

    func call(name: String, argumentsJSON: String, ticket: Data) throws -> String {
        throw MeshKernelError.refused("tool.unknown: " + name)
    }
}
