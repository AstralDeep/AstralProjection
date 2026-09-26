// Tests AstralCore's ClientDispositions against contracts/ui_protocol.json: vocabulary parity, voice and
// runtime frame classification, and per-client (iOS, macOS, watch) disposition completeness.

import XCTest

@testable import AstralCore

final class ManifestDriftTests: XCTestCase {

    enum ManifestLookupError: LocalizedError {
        case missing(String)

        var errorDescription: String? {
            switch self {
            case .missing(let path):
                return "required standalone UI protocol manifest is missing: \(path)"
            }
        }
    }

    struct Manifest: Decodable {
        struct Named: Decodable { let name: String }
        struct AdmissionRefusalContract: Decodable {
            let type: String
            let exactFields: [String]
            let submissionId: String
            let accepted: Bool
            let additionalFields: Bool
            let codes: [String]

            enum CodingKeys: String, CodingKey {
                case type
                case exactFields = "exact_fields"
                case submissionId = "submission_id"
                case accepted
                case additionalFields = "additional_fields"
                case codes
            }
        }
        struct FrameContracts: Decodable {
            let admissionRefusal: AdmissionRefusalContract
            let voice065: Voice065Contract

            enum CodingKeys: String, CodingKey {
                case admissionRefusal = "admission_refusal"
                case voice065 = "voice_065"
            }
        }
        struct Voice065Contract: Decodable {
            let composerActions: [String: String]
            let clientFrames: [String: [String]]

            enum CodingKeys: String, CodingKey {
                case composerActions = "composer_actions"
                case clientFrames = "client_frames"
            }
        }
        struct AdditiveField: Decodable {
            let field: String
            let carriedOn: [String]

            enum CodingKeys: String, CodingKey {
                case field
                case carriedOn = "carried_on"
            }
        }
        let pushTypes: [Named]
        let componentTypes: [String]
        let acceptActions: [String]
        let additiveFields: [AdditiveField]
        let frameContracts: FrameContracts

        enum CodingKeys: String, CodingKey {
            case pushTypes = "push_types"
            case componentTypes = "component_types"
            case acceptActions = "accept_actions"
            case additiveFields = "additive_fields"
            case frameContracts = "frame_contracts"
        }
    }

    static func manifestURL() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("contracts/ui_protocol.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        throw ManifestLookupError.missing("contracts/ui_protocol.json")
    }

    func loadManifest() throws -> Manifest {
        let data = try Data(contentsOf: try Self.manifestURL())
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    func testManifestVocabularyMatchesEmbeddedLists() throws {
        let manifest = try loadManifest()
        XCTAssertEqual(
            Set(manifest.pushTypes.map(\.name)),
            Set(ClientDispositions.allPushTypes),
            "push_types drift — update Dispositions.swift + parity matrix")
        XCTAssertEqual(
            Set(manifest.componentTypes),
            Set(ClientDispositions.allComponentTypes),
            "component_types drift — update Dispositions.swift + parity matrix")
        XCTAssertEqual(manifest.pushTypes.count, 72)
        XCTAssertEqual(manifest.componentTypes.count, 41)
        XCTAssertEqual(manifest.acceptActions.count, 138)
        XCTAssertTrue(Set(manifest.acceptActions).isSuperset(of: ["chrome_work_result_save", "chrome_job_stop"]))
        XCTAssertEqual(Set(manifest.acceptActions.filter { $0.hasPrefix("chrome_note_") }), GuidanceRequest.noteActions)
    }

    func testPersistentAssignmentActionsUseExistingSurfaceFrames() throws {
        let manifest = try loadManifest()
        let expected: Set<String> = [
            "chrome_assignment_create", "chrome_assignment_revise",
            "chrome_assignment_pause", "chrome_assignment_resume",
            "chrome_assignment_stop", "chrome_assignment_revoke",
            "chrome_assignment_run_now", "chrome_assignment_approval_decide",
        ]
        XCTAssertEqual(Set(manifest.acceptActions.filter { $0.hasPrefix("chrome_assignment_") }), expected)
        XCTAssertTrue(
            Set(manifest.pushTypes.map(\.name)).isDisjoint(with: ["assignment_state", "assignment_approval"]))
    }

    func testConversationalVoiceFramesAndActionsAreClassifiedExactly() throws {
        let manifest = try loadManifest()
        let requiredFrames = Set([
            "composer_state", "voice_announcement_media", "voice_control_binding",
            "voice_local_announcement", "voice_local_final_rejected", "voice_local_session_ready",
            "voice_local_turn_bound", "voice_session_state", "voice_submission_rejected",
            "voice_transcript", "voice_turn_state",
        ])
        let manifestFrames = Set(manifest.pushTypes.map(\.name))
        XCTAssertTrue(requiredFrames.isSubset(of: manifestFrames))

        let manifestActions = Set(manifest.frameContracts.voice065.composerActions.keys)
        let expectedActions = Set(ClientDispositions.allVoiceControlActions)
        XCTAssertEqual(manifestActions, expectedActions)
        XCTAssertTrue(manifestActions.isSubset(of: Set(manifest.acceptActions)))
        XCTAssertEqual(
            Set(manifest.frameContracts.voice065.clientFrames.keys),
            ["voice_playout_event"],
            "voice_playout_event is the sole content-free client media acknowledgement")

        for client in [ClientDispositions.ios, ClientDispositions.macos, ClientDispositions.watch] {
            XCTAssertEqual(client.voiceActions, expectedActions, "\(client.client): voice action drift")
            for frame in requiredFrames {
                XCTAssertEqual(
                    client.frames[frame], .handled,
                    "\(client.client): required voice frame must be handled: \(frame)")
            }
        }

        for action in expectedActions {
            XCTAssertNotNil(
                VoiceControlAction(rawValue: action),
                "AstralCore must provide a typed reducer action for \(action)")
        }
    }

    func testClientLocalVoiceContractIsPinnedToClosedV2Dispositions() throws {
        let data = try Data(contentsOf: try Self.manifestURL())
        let root = try JSONValue.parse(data)
        let contract = try XCTUnwrap(root["frame_contracts"]?["voice_075"]?.objectValue)
        XCTAssertEqual(contract["schema_version"]?.stringValue, "2")
        XCTAssertEqual(contract["local_frame_contract"]?.stringValue, "client_local/v1")
        XCTAssertEqual(
            contract["required_dispositions"]?.arrayValue?.compactMap(\.stringValue),
            ["ready", "typed_fallback", "rejected", "permission_denied", "final", "speaking", "finished"])
    }

    func testRuntimeReliabilityFramesAndRegistrationDisposition() throws {
        let manifest = try loadManifest()
        let required = Set([
            "conversation_snapshot", "operation_status", "agent_lifecycle",
            "agent_host_inventory_reconciled", "agent_host_registered",
            "agent_host_registration_refused", "conversation_commit_ready",
        ])
        XCTAssertTrue(required.isSubset(of: Set(manifest.pushTypes.map(\.name))))

        let registrations = manifest.additiveFields.filter {
            $0.field == "agent_host" && $0.carriedOn == ["register_ui"]
        }
        XCTAssertEqual(
            registrations.count, 1,
            "manifest must declare structured register_ui.agent_host exactly once")

        let hostFrames = [
            "agent_host_inventory_reconciled", "agent_host_registered",
            "agent_host_registration_refused",
        ]
        for client in [ClientDispositions.ios, ClientDispositions.macos, ClientDispositions.watch] {
            for frame in hostFrames {
                guard let disposition = client.frames[frame] else {
                    XCTFail("\(client.client) must classify \(frame)")
                    continue
                }
                if case .ignored(_) = disposition {
                    // Expected: Apple clients are author-only.
                } else {
                    XCTFail("\(client.client) must explicitly ignore host-only \(frame)")
                }
            }
        }
    }

    func testManifestPinsExactAdmissionRefusalContract() throws {
        let contract = try loadManifest().frameContracts.admissionRefusal
        XCTAssertEqual(contract.type, "error")
        XCTAssertEqual(
            contract.exactFields,
            [
                "type", "submission_id", "accepted", "code", "message",
                "retryable", "retry_after_ms",
            ])
        XCTAssertEqual(contract.submissionId, "canonical_lowercase_uuid4")
        XCTAssertFalse(contract.accepted)
        XCTAssertFalse(contract.additionalFields)
        XCTAssertEqual(
            contract.codes,
            [
                "capacity_exceeded", "registration_required", "registration_timeout",
                "idempotency_conflict", "connection_closing", "service_draining",
                "invalid_input", "registration_queue_full", "operation_failed",
            ])
    }

    func testEveryClientDispositionsEveryFrameAndComponent() throws {
        for client in [ClientDispositions.ios, ClientDispositions.macos, ClientDispositions.watch] {
            for name in ClientDispositions.allPushTypes {
                XCTAssertNotNil(
                    client.frames[name],
                    "\(client.client): missing frame disposition for \(name)")
            }
            for name in ClientDispositions.allComponentTypes {
                XCTAssertNotNil(
                    client.components[name],
                    "\(client.client): missing component disposition for \(name)")
            }
            for name in client.frames.keys {
                XCTAssertTrue(
                    ClientDispositions.allPushTypes.contains(name),
                    "\(client.client): stale frame disposition \(name)")
            }
            for name in client.components.keys {
                XCTAssertTrue(
                    ClientDispositions.allComponentTypes.contains(name),
                    "\(client.client): stale component disposition \(name)")
            }
        }
    }

    func testWatchHandlesNotificationForBackgroundContinuity() {
        XCTAssertEqual(ClientDispositions.watch.frames["notification"], .handled)
    }

    func testWatchNativeSetIsWithinProfileVocabulary() {
        // Charts/tables/code are degraded server-side; watch must not claim them
        let native = Set(ClientDispositions.watch.nativeComponentTypes)
        for forbidden in [
            "bar_chart", "line_chart", "pie_chart", "plotly_chart",
            "table", "code", "tabs", "file_upload", "file_download",
        ] {
            XCTAssertFalse(
                native.contains(forbidden),
                "watch must not advertise \(forbidden) as native")
        }
        for required in ["text", "alert", "list", "metric", "keyvalue"] {
            XCTAssertTrue(native.contains(required))
        }
    }

    func testSupportedTypesRideOnDeviceDescriptors() {
        XCTAssertEqual(
            Set(
                DeviceDescriptor.watch(viewportWidth: 200, viewportHeight: 240)
                    .supportedTypes),
            Set(ClientDispositions.watch.nativeComponentTypes))
        XCTAssertFalse(
            DeviceDescriptor.ios(viewportWidth: 390, viewportHeight: 844)
                .supportedTypes.isEmpty)
    }
}
