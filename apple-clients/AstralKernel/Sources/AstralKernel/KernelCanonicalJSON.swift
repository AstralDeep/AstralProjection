// Provides the kernel's strict signing JSON format to host-owned consent and identity flows.
// All parsing and serialization use the Rust implementation through UniFFI.
import Foundation
import AstralKernelBindings

public enum KernelCanonicalJSON {
    public static func canonicalize(_ data: Data) throws -> Data {
        try canonicalJson(input: data)
    }
}
