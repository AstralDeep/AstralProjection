// Replays one stored outside-agent surface and the kernel's two adapted records through the guarded native UI fixture.
#if DEBUG
import AstralCore
import AstralKernel
import CryptoKit
import Foundation

nonisolated enum MeshStoredSurfaceFixture {
    struct Snapshot: Decodable {
        struct Event: Decodable {
            struct Clock: Decodable { let ms: UInt64; let n: UInt64 }
            let id: String
            let kind: String
            let feed: String
            let seq: UInt64
            let clock: Clock
            let after: [String]
            let body: JSONValue

            func native() throws -> SurfaceEvent {
                SurfaceEvent(
                    id: id, kind: kind, feed: feed, seq: seq, clock: ClockStamp(ms: clock.ms, n: clock.n),
                    after: after, bodyJson: String(decoding: try JSONEncoder().encode(body), as: UTF8.self),
                    bodyState: .present)
            }
        }
        struct Profile: Decodable {
            let surface: String
            let document: JSONValue
            let tree: [JSONValue]
            let untrusted: Bool
            let rejected: [String]
            let unresolved: [String]

            func native() throws -> RenderedSurface {
                RenderedSurface(
                    surface: surface, turn: nil,
                    documentJson: String(decoding: try JSONEncoder().encode(document), as: UTF8.self),
                    treeJson: String(decoding: try JSONEncoder().encode(tree), as: UTF8.self),
                    untrusted: untrusted, rejected: rejected, unresolved: unresolved)
            }
        }
        let a2ui: [JSONValue]
        let event: Event
        let profiles: [String: Profile]
    }

    static let payloadDigest = "050d11e29a5ed8c2892986bf0aff776c2be79812ab382f405151d9dad627e7e0"
    static let eventId = "sha256:ca3e200bd8a6f2f6614ca6d029cf22c931b228c38a9c6ca2a119d4d7aa09c8fb"
    static var digest: String { SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func load() throws -> Snapshot { try JSONDecoder().decode(Snapshot.self, from: Data(payload.utf8)) }

    static func seed(_ kernel: InMemoryMeshKernel) throws {
        let snapshot = try load()
        let folded = KernelSurfaceFold.fold([try snapshot.event.native()])
        let surfaces = folded.map(\.surface)
        let chat = kernel.seedChat(
            title: "Shared clinical summary",
            messages: [MeshChatMessage(
                eventId: "surface-result", parentId: nil, author: .assistant, authorDevice: nil,
                text: "Outside lab summary", createdAt: Date(timeIntervalSince1970: 1), delivery: .recorded,
                surfaceIds: surfaces.map(\.surfaceId))], surfaces: surfaces)
        #if os(macOS)
            let profile = "mac"
        #else
            let profile = "iphone"
        #endif
        if let record = snapshot.profiles[profile], let rendered = KernelChatMapper.rendered(try record.native()) {
            kernel.setRendered(chatId: chat, [rendered])
        }
    }

    private static let payload = #"{"a2ui":[{"createSurface":{"catalogId":"https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json","surfaceId":"shared_summary"},"version":"1.0"},{"updateComponents":{"components":[{"children":["heading","pulse","link","send"],"component":"Column","id":"root"},{"component":"Text","id":"heading","text":"Shared clinical summary"},{"component":"Text","id":"pulse","text":"Pulse: 72 bpm"},{"component":"Text","id":"link","text":"https://outside.example/collect?patient=fixture"},{"action":{"event":{"name":"send"}},"child":"send_label","component":"Button","id":"send"},{"component":"Text","id":"send_label","text":"Send patient record"}],"surfaceId":"shared_summary"},"version":"1.0"}],"event":{"after":[],"body":{"document":{"capabilities":{},"components":{"heading":{"children":[],"id":"heading","props":{"content":"Shared clinical summary","variant":"body"},"prov":"agent","type":"text"},"link":{"children":[],"id":"link","props":{"content":"[text with a link was removed]","variant":"body"},"prov":"agent","type":"text"},"pulse":{"children":[],"id":"pulse","props":{"content":"Pulse: 72 bpm","variant":"body"},"prov":"agent","type":"text"},"root":{"children":["heading","pulse","link","send"],"id":"root","props":{"direction":"column"},"prov":"agent","type":"container"},"send":{"children":[],"id":"send","props":{"content":"Send patient record","variant":"muted"},"prov":"agent","type":"text"}},"root":"root","surface":"new","v":1},"source":{"catalog":"https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json","format":"a2ui/1.0","name":"outside-lab-agent","origin":"agent","surface":"shared_summary"},"turn":null},"body_state":"present","clock":{"ms":1794590252271,"n":0},"feed":"HIY5CfakPcvzT5LzhIf4qRyIFVbjfQLIxZT86N6zho8","id":"sha256:ca3e200bd8a6f2f6614ca6d029cf22c931b228c38a9c6ca2a119d4d7aa09c8fb","kind":"ui.surface_put","seq":4},"kernel_source":"f96039267a77968f26597ab56edbc7372a856ee6","notices":[{"code":"a2ui.link_removed","detail":"text in content held a link and was removed"},{"code":"a2ui.control_dropped","detail":"the button cannot be pressed from outside and became text"}],"profiles":{"iphone":{"document":{"capabilities":{},"components":{"heading":{"children":[],"id":"heading","props":{"content":"Shared clinical summary","variant":"body"},"prov":"agent","type":"text"},"link":{"children":[],"id":"link","props":{"content":"[text with a link was removed]","variant":"body"},"prov":"agent","type":"text"},"pulse":{"children":[],"id":"pulse","props":{"content":"Pulse: 72 bpm","variant":"body"},"prov":"agent","type":"text"},"root":{"children":["heading","pulse","link","send"],"id":"root","props":{"direction":"column"},"prov":"agent","type":"container"},"send":{"children":[],"id":"send","props":{"content":"Send patient record","variant":"muted"},"prov":"agent","type":"text"}},"root":"root","surface":"new","v":1},"rejected":[],"surface":"sha256:ca3e200bd8a6f2f6614ca6d029cf22c931b228c38a9c6ca2a119d4d7aa09c8fb","tree":[{"children":[{"content":"Shared clinical summary","id":"heading","provenance":"agent","type":"text","variant":"body"},{"content":"Pulse: 72 bpm","id":"pulse","provenance":"agent","type":"text","variant":"body"},{"content":"[text with a link was removed]","id":"link","provenance":"agent","type":"text","variant":"body"},{"content":"Send patient record","id":"send","provenance":"agent","type":"text","variant":"muted"}],"direction":"column","id":"root","provenance":"agent","type":"container"}],"unresolved":[],"untrusted":true},"mac":{"document":{"capabilities":{},"components":{"heading":{"children":[],"id":"heading","props":{"content":"Shared clinical summary","variant":"body"},"prov":"agent","type":"text"},"link":{"children":[],"id":"link","props":{"content":"[text with a link was removed]","variant":"body"},"prov":"agent","type":"text"},"pulse":{"children":[],"id":"pulse","props":{"content":"Pulse: 72 bpm","variant":"body"},"prov":"agent","type":"text"},"root":{"children":["heading","pulse","link","send"],"id":"root","props":{"direction":"column"},"prov":"agent","type":"container"},"send":{"children":[],"id":"send","props":{"content":"Send patient record","variant":"muted"},"prov":"agent","type":"text"}},"root":"root","surface":"new","v":1},"rejected":[],"surface":"sha256:ca3e200bd8a6f2f6614ca6d029cf22c931b228c38a9c6ca2a119d4d7aa09c8fb","tree":[{"children":[{"content":"Shared clinical summary","id":"heading","provenance":"agent","type":"text","variant":"body"},{"content":"Pulse: 72 bpm","id":"pulse","provenance":"agent","type":"text","variant":"body"},{"content":"[text with a link was removed]","id":"link","provenance":"agent","type":"text","variant":"body"},{"content":"Send patient record","id":"send","provenance":"agent","type":"text","variant":"muted"}],"direction":"column","id":"root","provenance":"agent","type":"container"}],"unresolved":[],"untrusted":true}}}"#
}
#endif
