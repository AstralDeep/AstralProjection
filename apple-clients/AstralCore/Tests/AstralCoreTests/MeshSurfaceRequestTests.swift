// Verifies closed mesh owner payloads and explicit refusal of local or queued actions.
// Shared wire encoding exercises envelope correlation and current-connection classification.

@testable import AstralCore
import Foundation
import XCTest

final class MeshSurfaceRequestTests: XCTestCase {
    private let identity = String(repeating: "a", count: 32)
    private let key = #"{"kty":"OKP","crv":"Ed25519","x":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}"#

    private func create(_ raw: String) -> JSONValue {
        .object([
            "surface": .string("mesh"),
            "fields": .object([
                "label": .string("Phone"), "device_key": .string(raw), "scopes": .string("tools:read"),
                "ttl_seconds": .string("3600"),
            ]),
        ])
    }

    func testClosedActionsRetainNormalEnvelopeAndRefuseAdditionalFields() throws {
        let cases: [String: JSONValue] = [
            "chrome_open": .object(["surface": .string("mesh"), "params": .object([:])]),
            "chrome_close": .object(["surface": .string("mesh")]),
            "chrome_mesh_create": create(key),
            "chrome_mesh_confirm": .object(["surface": .string("mesh"), "invite_id": .string(identity)]),
            "chrome_mesh_reject": .object(["surface": .string("mesh"), "invite_id": .string(identity)]),
            "chrome_mesh_remove_invitation": .object(["surface": .string("mesh"), "invite_id": .string(identity)]),
            "chrome_mesh_revoke": .object(["surface": .string("mesh"), "member_id": .string(identity)]),
            "chrome_mesh_rename": .object([
                "surface": .string("mesh"), "member_id": .string(identity),
                "fields": .object(["label": .string("Desktop")]),
            ]),
        ]
        for (action, payload) in cases {
            XCTAssertNotNil(MeshSurfaceRequest(action: action, payload: payload))
            let frame = Outbound.uiEvent(action: action, sessionId: nil, payload: payload)
            XCTAssertNotNil(MeshSurfaceRequest(frameText: frame), action)
            XCTAssertTrue(MeshSurfaceRequest.claimsCurrentConnectionSemantics(frameText: frame))
            var fields = payload.objectValue!
            fields["unexpected"] = .bool(true)
            XCTAssertNil(MeshSurfaceRequest(action: action, payload: .object(fields)))
            fields.removeValue(forKey: "unexpected")
            fields["surface"] = .string("other")
            XCTAssertNil(MeshSurfaceRequest(action: action, payload: .object(fields)))
        }
        for action in ["chrome_mesh_identity", "chrome_mesh_redeem", "chrome_mesh_unknown"] {
            let frame = Outbound.uiEvent(action: action, sessionId: nil, payload: .object([:]))
            XCTAssertTrue(MeshSurfaceRequest.claimsCurrentConnectionSemantics(frameText: frame))
            XCTAssertNil(MeshSurfaceRequest(frameText: frame))
        }
        XCTAssertFalse(MeshSurfaceRequest.claimsCurrentConnectionSemantics(frameText: "{}"))
        XCTAssertNil(MeshSurfaceRequest(frameText: "{}"))
        XCTAssertNil(MeshSurfaceRequest(frameText: String(repeating: "x", count: 16385)))
    }

    func testMalformedPublicIdentityFieldsAndForeignSessionAreDenied() {
        for raw in [
            "", "broken", "{}", "[]", String(repeating: "x", count: 2049),
            key.replacingOccurrences(of: "OKP", with: "RSA"), key.replacingOccurrences(of: "Ed25519", with: "X25519"),
            key.replacingOccurrences(of: "AAA\"", with: "AA=\""), key.replacingOccurrences(of: "AAA\"", with: "AAB\""),
            key.replacingOccurrences(of: "}", with: ",\"d\":\"private\"}"),
        ] { XCTAssertNil(MeshSurfaceRequest(action: "chrome_mesh_create", payload: create(raw)), raw) }
        for name in ["label", "device_key", "scopes", "ttl_seconds"] {
            for value: JSONValue in [.bool(true), .string(""), .string(String(repeating: "x", count: 2050))] {
                var fields = create(key)["fields"]!.objectValue!
                fields[name] = value
                XCTAssertNil(
                    MeshSurfaceRequest(
                        action: "chrome_mesh_create",
                        payload: .object(["surface": .string("mesh"), "fields": .object(fields)])))
            }
        }
        for id in ["", String(repeating: "A", count: 32), "foreign"] {
            XCTAssertNil(
                MeshSurfaceRequest(
                    action: "chrome_mesh_revoke",
                    payload: .object(["surface": .string("mesh"), "member_id": .string(id)])))
        }
        XCTAssertNil(
            MeshSurfaceRequest(
                action: "chrome_mesh_rename",
                payload: .object([
                    "surface": .string("mesh"),
                    "member_id": .string(identity), "fields": .object(["label": .bool(true)]),
                ])))
        let foreign = Outbound.uiEvent(
            action: "chrome_mesh_revoke", sessionId: "foreign",
            payload: .object([
                "surface": .string("mesh"), "member_id": .string(identity),
            ]))
        XCTAssertNil(MeshSurfaceRequest(frameText: foreign))
        let other = Outbound.uiEvent(action: "ordinary", sessionId: nil, payload: .object([:]))
        XCTAssertFalse(MeshSurfaceRequest.claimsCurrentConnectionSemantics(frameText: other))
    }
}
