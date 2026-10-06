// Exercises WatchModel authentication recovery through a real loopback broker and registered sockets.
// Synthetic credentials use memory storage; retired owners, sessions and registrations cannot adopt or replay work.

import AstralCore
@testable import AstralWatch
import CryptoKit
import Foundation
import Network
import XCTest

@MainActor
final class WatchSocketAuthenticationTests: XCTestCase {
    private let timeout: TimeInterval = 30
    private let refusal = #"{"type":"auth_required","reason":"expired"}"#

    private func waitUntil(_ name: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), name)
    }

    private func withModel(
        _ body: (WatchModel, InMemoryTokenStore, WatchAuthenticationClock, WatchAuthenticationPeer) async throws -> Void
    ) async throws {
        let clock = WatchAuthenticationClock()
        let peer = try WatchAuthenticationPeer(clock: clock)
        peer.start()
        defer { peer.stop() }
        await fulfillment(of: [peer.ready], timeout: timeout)
        let port = try XCTUnwrap(peer.listener.port)
        let suite = "WatchSocketAuthentication.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let resume = ConversationResumeStore(defaults: defaults)
        let set = TokenSet(
            accessToken: peer.originalToken, refreshToken: "fixture-original-refresh", expiresIn: 3600, now: clock.now)
        XCTAssertTrue(
            resume.save(chatId: "11111111-1111-4111-8111-111111111111", for: try XCTUnwrap(set.conversationAccount)))
        let store = InMemoryTokenStore()
        store.save(StoredTokens(from: set))
        let model = WatchModel(conversationResumeStore: resume, tokenStore: store, authenticationNow: { clock.now })
        model.serverBase = URL(string: "http://127.0.0.1:\(port.rawValue)")!
        let registered = peer.expectRegistration()
        await model.bootstrap()
        await fulfillment(of: [registered], timeout: timeout)
        try await waitUntil("registered Watch model has current controls") {
            model.connected && model.guidanceControls.count == 2
        }
        do {
            try await body(model, store, clock, peer)
        } catch {
            await model.signOut(revokeRemote: false)
            throw error
        }
        await model.signOut(revokeRemote: false)
    }

    func testExpiredRefusalRotatesOnePhysicalSocketWithoutSubmittingTheDraft() async throws {
        try await withModel { model, store, clock, peer in
            model.pendingDictation = "Unsent wrist draft"
            clock.advance(7200)
            peer.holdRefresh()
            let refresh = peer.expectRefresh()
            let registered = peer.expectRegistration()
            peer.send(refusal)
            await fulfillment(of: [refresh], timeout: timeout)
            peer.send(refusal)
            peer.releaseRefresh()
            await fulfillment(of: [registered], timeout: timeout)
            XCTAssertEqual(peer.refreshCount, 1)
            XCTAssertEqual(peer.registrations.count, 2)
            let original = try XCTUnwrap(peer.registrations.first)
            let renewed = try XCTUnwrap(peer.registrations.dropFirst().first)
            XCTAssertNotEqual(original.socket, renewed.socket)
            XCTAssertNotEqual(original.generation, renewed.generation)
            XCTAssertEqual(peer.registrations.last?.token, store.load()?.accessToken)
            XCTAssertNotEqual(peer.registrations.last?.token, peer.originalToken)
            XCTAssertEqual(peer.brokerPayloads.first?["client"], .string(AstralConfig.watchClientId))
            XCTAssertEqual(peer.brokerPayloads.first?["refresh_token"], .string("fixture-original-refresh"))
            XCTAssertEqual(model.pendingDictation, "Unsent wrist draft")
            XCTAssertFalse(peer.events.contains { $0.frame.payload["action"] == .string("chat_message") })
        }
    }

    func testRESTTokenRotationRenewsTheRegisteredSocket() async throws {
        try await withModel { model, store, clock, peer in
            clock.advance(7200)
            let registered = peer.expectRegistration()
            _ = try await model.rest.chats()
            await fulfillment(of: [registered], timeout: timeout)
            XCTAssertEqual(peer.refreshCount, 1)
            XCTAssertEqual(peer.registrations.count, 2)
            XCTAssertEqual(peer.registrations.last?.token, store.load()?.accessToken)
            XCTAssertEqual(peer.restAuthorization.last, "Bearer \(try XCTUnwrap(store.load()?.accessToken))")
        }
    }

    func testRESTAndSocketRefusalShareOneHeldBrokerAttemptAndRegistration() async throws {
        try await withModel { model, store, clock, peer in
            clock.advance(7200)
            peer.holdRefresh()
            let refresh = peer.expectRefresh()
            let registered = peer.expectRegistration()
            let read = Task { try await model.rest.chats() }
            await fulfillment(of: [refresh], timeout: timeout)
            peer.send(refusal)
            peer.releaseRefresh()
            _ = try? await read.value
            await fulfillment(of: [registered], timeout: timeout)
            try await waitUntil("current shared-refresh declaration") {
                model.connected && model.guidanceControls.count == 2
            }
            XCTAssertEqual(peer.refreshCount, 1)
            XCTAssertEqual(peer.registrations.count, 2)
            XCTAssertEqual(peer.registrations.last?.token, store.load()?.accessToken)
            XCTAssertFalse(peer.events.contains { $0.frame.payload["action"] == .string("chat_message") })
        }
    }

    func testHeldRefreshCannotReturnCredentialsForAReplacedOwner() async throws {
        try await withModel { model, store, clock, peer in
            clock.advance(7200)
            peer.holdRefresh()
            let refresh = peer.expectRefresh()
            let read = Task { try await model.rest.chats() }
            await fulfillment(of: [refresh], timeout: timeout)
            model.bindConversationAccount(
                ConversationAccount(issuer: "https://issuer.example.test", subject: "new-owner")!)
            peer.releaseRefresh()
            _ = try? await read.value
            XCTAssertEqual(store.load()?.accessToken, peer.originalToken)
            XCTAssertFalse(peer.restAuthorization.contains { $0.hasPrefix("Bearer ") })
            XCTAssertEqual(peer.registrations.count, 1)
        }
    }

    func testHeldRefreshCannotReturnCredentialsForAReplacedConnection() async throws {
        try await withModel { model, store, clock, peer in
            clock.advance(7200)
            peer.holdRefresh()
            let refresh = peer.expectRefresh()
            let read = Task { try await model.rest.chats() }
            await fulfillment(of: [refresh], timeout: timeout)
            XCTAssertTrue(model.beginConversationConnection("77777777-7777-4777-8777-777777777777"))
            peer.releaseRefresh()
            _ = try? await read.value
            XCTAssertEqual(store.load()?.accessToken, peer.originalToken)
            XCTAssertFalse(peer.restAuthorization.contains { $0.hasPrefix("Bearer ") })
            XCTAssertEqual(peer.registrations.count, 1)
        }
    }

    func testHeldRefusalCannotSignOutAReplacedOwner() async throws {
        try await withModel { model, store, _, peer in
            peer.holdRefresh()
            peer.configureRefresh(status: 401)
            let refresh = peer.expectRefresh()
            peer.send(refusal)
            await fulfillment(of: [refresh], timeout: timeout)
            model.bindConversationAccount(
                ConversationAccount(issuer: "https://issuer.example.test", subject: "new-owner")!)
            let completed = peer.expectRefreshResponse()
            peer.releaseRefresh()
            await fulfillment(of: [completed], timeout: timeout)
            _ = try? await model.rest.chats()
            XCTAssertEqual(store.load()?.accessToken, peer.originalToken)
            XCTAssertEqual(peer.refreshCount, 1)
            XCTAssertEqual(peer.registrations.count, 1)
            XCTAssertEqual(model.phase, .signedIn)
        }
    }

    func testHeldRefreshCannotAdoptCredentialsAfterServerReplacement() async throws {
        try await withModel { model, store, clock, peer in
            clock.advance(7200)
            peer.holdRefresh()
            let refresh = peer.expectRefresh()
            let read = Task { try await model.rest.chats() }
            await fulfillment(of: [refresh], timeout: timeout)
            model.serverBase = URL(string: "http://127.0.0.1:1")!
            peer.releaseRefresh()
            _ = try? await read.value
            XCTAssertEqual(store.load()?.accessToken, peer.originalToken)
            XCTAssertFalse(peer.restAuthorization.contains { $0.hasPrefix("Bearer ") })
            XCTAssertEqual(peer.registrations.count, 1)
        }
    }

    func testRetainedRESTClientCannotSendBearerToItsRetiredServer() async throws {
        try await withModel { model, store, _, peer in
            let retained = model.rest
            model.serverBase = URL(string: "http://127.0.0.1:1")!
            _ = try await retained.chats()
            XCTAssertEqual(peer.restAuthorization.last, "")
            XCTAssertEqual(store.load()?.accessToken, peer.originalToken)
            XCTAssertEqual(peer.refreshCount, 0)
        }
    }

    func testRetainedRESTClientCannotAcquireAReplacementOwnersBearer() async throws {
        try await withModel { model, store, clock, peer in
            let retained = model.rest
            await model.signOut(revokeRemote: false)
            try await waitUntil("retired login task settled") {
                if case .unavailable = model.phase { return true }
                return false
            }
            let replacement = TokenSet(
                accessToken: peer.tokenForSubject("replacement-owner"), refreshToken: "fixture-replacement-refresh",
                expiresIn: 3600, now: clock.now)
            store.save(StoredTokens(from: replacement))
            let registered = peer.expectRegistration()
            await model.bootstrap()
            await fulfillment(of: [registered], timeout: timeout)
            try await waitUntil("replacement owner registered") {
                model.phase == .signedIn && model.connected && model.guidanceControls.count == 2
            }
            _ = try await retained.chats()
            XCTAssertEqual(peer.restAuthorization.last, "")
            XCTAssertEqual(store.load()?.accessToken, replacement.accessToken)
            XCTAssertEqual(peer.refreshCount, 0)
        }
    }

    func testHeldAuthorizedRecentsCannotPublishAfterServerReplacement() async throws {
        try await withModel { model, store, _, peer in
            let response = peer.holdRecents()
            let pending = Task { await model.refreshRecents() }
            await fulfillment(of: [response], timeout: timeout)
            XCTAssertTrue(model.recentsLoading)
            XCTAssertEqual(peer.restAuthorization.last, "Bearer \(try XCTUnwrap(store.load()?.accessToken))")
            model.serverBase = URL(string: "http://127.0.0.1:1")!
            peer.releaseRecents()
            await pending.value
            XCTAssertTrue(model.recents.isEmpty)
            XCTAssertFalse(model.recentsLoading)
        }
    }

    func testRetiredRecentsResponsePreservesANewerRequestsLoadingState() async throws {
        try await withModel { model, _, _, peer in
            let response = peer.holdRecents()
            let pending = Task { await model.refreshRecents() }
            await fulfillment(of: [response], timeout: timeout)
            model.serverBase = URL(string: "http://127.0.0.1:1")!
            let started = XCTestExpectation(description: "new server recent read held")
            var completion: CheckedContinuation<[ChatSummary], Never>?
            let current = Task {
                await model.refreshRecents {
                    await withCheckedContinuation { continuation in
                        completion = continuation
                        started.fulfill()
                    }
                }
            }
            await fulfillment(of: [started], timeout: timeout)
            peer.releaseRecents()
            await pending.value
            XCTAssertTrue(model.recents.isEmpty)
            XCTAssertTrue(model.recentsLoading)
            try XCTUnwrap(completion).resume(returning: [])
            await current.value
            XCTAssertFalse(model.recentsLoading)
        }
    }

    func testSignOutRetiresAHeldBrokerReply() async throws {
        try await withModel { model, store, clock, peer in
            clock.advance(7200)
            peer.holdRefresh()
            let refresh = peer.expectRefresh()
            let read = Task { try await model.rest.chats() }
            await fulfillment(of: [refresh], timeout: timeout)
            await model.signOut(revokeRemote: false)
            peer.releaseRefresh()
            _ = try? await read.value
            XCTAssertNil(store.load())
            XCTAssertFalse(peer.restAuthorization.contains { $0.hasPrefix("Bearer ") })
            XCTAssertEqual(peer.registrations.count, 1)
            XCTAssertNotEqual(model.phase, .signedIn)
        }
    }

    func testSameTokenRefusalDoesNotLoopOrRetainTheSession() async throws {
        try await withModel { model, store, _, peer in
            peer.returnSameToken()
            peer.send(refusal)
            try await waitUntil("refused same credential is retired") { store.load() == nil }
            XCTAssertEqual(peer.refreshCount, 1)
            XCTAssertEqual(peer.registrations.count, 1)
            XCTAssertNotEqual(model.phase, .signedIn)
        }
    }

    func testForeignBrokerAccountCannotReplaceTheStoredOwner() async throws {
        try await withModel { model, store, _, peer in
            peer.configureRefresh(status: 200, subject: "foreign-owner")
            peer.send(refusal)
            try await waitUntil("foreign credentials are rejected") { store.load() == nil }
            XCTAssertEqual(peer.refreshCount, 1)
            XCTAssertEqual(peer.registrations.count, 1)
            XCTAssertNotEqual(model.phase, .signedIn)
        }
    }

    func testTransientBrokerFailureKeepsTheDraftAndExposesRetryWithoutReplay() async throws {
        try await withModel { model, store, _, peer in
            model.pendingDictation = "Keep this draft"
            peer.configureRefresh(status: 503)
            peer.send(refusal)
            try await waitUntil("renewal failure is visible") { model.errorBanner != nil }
            XCTAssertEqual(store.load()?.accessToken, peer.originalToken)
            XCTAssertEqual(model.phase, .signedIn)
            XCTAssertEqual(model.pendingDictation, "Keep this draft")
            XCTAssertEqual(peer.registrations.count, 1)
            XCTAssertEqual(peer.refreshCount, 1)
            XCTAssertFalse(peer.events.contains { $0.frame.payload["action"] == .string("chat_message") })
        }
    }

    func testValidShortLivedRefreshIsRegisteredOnce() async throws {
        try await withModel { model, store, _, peer in
            peer.configureRefresh(status: 200, lifetime: 20)
            let registered = peer.expectRegistration()
            peer.send(refusal)
            await fulfillment(of: [registered], timeout: timeout)
            XCTAssertEqual(peer.refreshCount, 1)
            XCTAssertEqual(peer.registrations.count, 2)
            XCTAssertEqual(peer.registrations.last?.token, store.load()?.accessToken)
            XCTAssertEqual(model.phase, .signedIn)
        }
    }

    func testRejectedBrokerRetiresOnlyTheCurrentSession() async throws {
        try await withModel { model, store, _, peer in
            peer.configureRefresh(status: 401)
            peer.send(refusal)
            try await waitUntil("rejected session is retired") { store.load() == nil }
            XCTAssertEqual(peer.refreshCount, 1)
            XCTAssertEqual(peer.registrations.count, 1)
            XCTAssertNotEqual(model.phase, .signedIn)
        }
    }

    func testActuallyExpiredBrokerCredentialsAreRejected() async throws {
        try await withModel { model, store, _, peer in
            peer.configureRefresh(status: 200, lifetime: 0)
            peer.send(refusal)
            try await waitUntil("expired refreshed credentials are retired") { store.load() == nil }
            XCTAssertEqual(peer.refreshCount, 1)
            XCTAssertEqual(peer.registrations.count, 1)
            XCTAssertNotEqual(model.phase, .signedIn)
        }
    }

    func testRenewedRegistrationRefusalCannotStartAnotherRefresh() async throws {
        try await withModel { model, store, _, peer in
            peer.rejectNextRegistration()
            let registered = peer.expectRegistration()
            peer.send(refusal)
            await fulfillment(of: [registered], timeout: timeout)
            try await waitUntil("rejected replacement registration is retired") { store.load() == nil }
            XCTAssertEqual(peer.refreshCount, 1)
            XCTAssertEqual(peer.registrations.count, 2)
        }
    }

    func testRecoveryPreservesCanonicalSelectionReadAndConversation() async throws {
        try await withModel { model, _, _, peer in
            let advanced = try XCTUnwrap(
                model.guidanceControls.first { $0.action?.params == GuidanceRequest.selection.payload["params"] })
            model.openGuidance(advanced)
            try await waitUntil("initial Advanced read sent") {
                peer.events.filter { $0.frame.payload["action"] == .string("chrome_open") }.count == 1
            }
            let registered = peer.expectRegistration()
            peer.send(refusal)
            await fulfillment(of: [registered], timeout: timeout)
            try await waitUntil("current authorized Advanced read recovered") {
                peer.events.filter { $0.frame.payload["action"] == .string("chrome_open") }.count == 2
            }
            let reads = peer.events.filter { $0.frame.payload["action"] == .string("chrome_open") }
            XCTAssertEqual(reads.last?.frame.payload["payload"]?["surface"], .string("guidance"))
            XCTAssertEqual(reads.last?.frame.payload["payload"]?["params"], GuidanceRequest.selection.payload["params"])
            XCTAssertNotEqual(
                reads.first?.frame.payload["request_generation"], reads.last?.frame.payload["request_generation"])
            XCTAssertEqual(model.activeChatId, "11111111-1111-4111-8111-111111111111")
            XCTAssertFalse(peer.events.contains { $0.frame.payload["action"] == .string("chrome_turn_selection_set") })
        }
    }

    func testRetiredSelectionDeclarationNeverFallsBackToPrivateNotes() async throws {
        try await withModel { model, _, _, peer in
            model.openGuidance(
                try XCTUnwrap(
                    model.guidanceControls.first { $0.action?.params == GuidanceRequest.selection.payload["params"] }))
            try await waitUntil("initial Advanced read sent") {
                peer.events.filter { $0.frame.payload["action"] == .string("chrome_open") }.count == 1
            }
            peer.retireSelectionOffer()
            let registered = peer.expectRegistration()
            peer.send(refusal)
            await fulfillment(of: [registered], timeout: timeout)
            try await waitUntil("new current notes-only declaration") { model.guidanceControls.count == 1 }
            XCTAssertEqual(peer.events.filter { $0.frame.payload["action"] == .string("chrome_open") }.count, 1)
            XCTAssertTrue(model.guidanceFailed)
            XCTAssertNotNil(model.errorBanner)
        }
    }

    func testRecoveryReloadsOnlyTheCurrentlyOfferedDefaultWorkRead() async throws {
        try await withModel { model, _, _, peer in
            model.openWork(try XCTUnwrap(model.workControls.first))
            try await waitUntil("initial Work list read") {
                peer.events.filter { $0.frame.payload["action"] == .string("chrome_open") }.count == 1
            }
            let registered = peer.expectRegistration()
            peer.send(refusal)
            await fulfillment(of: [registered], timeout: timeout)
            try await waitUntil("authorized default Work read recovered") {
                peer.events.filter { $0.frame.payload["action"] == .string("chrome_open") }.count == 2
            }
            let reads = peer.events.filter { $0.frame.payload["action"] == .string("chrome_open") }
            XCTAssertEqual(reads.last?.frame.payload["payload"]?["surface"], .string("work"))
            XCTAssertEqual(reads.last?.frame.payload["payload"]?["params"], .object(["mode": .string("list")]))
            XCTAssertNotEqual(
                reads.first?.frame.payload["request_generation"], reads.last?.frame.payload["request_generation"])
        }
    }

    func testRecoveryNeverReplaysPrivateSearchOrWrite() async throws {
        let requests = [
            GuidanceRequest(
                action: "chrome_note_search", payload: .object(["fields": .object(["search": .string("local search")])])
            )!,
            GuidanceRequest(
                action: "chrome_note_toggle",
                payload: .object([
                    "note_id": .string("33333333-3333-4333-8333-333333333333"), "expected_revision": .number(1),
                    "enabled": .bool(true),
                ]))!,
        ]
        for request in requests {
            try await withModel { model, _, _, peer in
                model.openGuidance(try XCTUnwrap(model.guidanceControls.first))
                try await waitUntil("initial notes read") {
                    peer.events.filter { $0.frame.payload["action"] == .string("chrome_open") }.count == 1
                }
                let generation = try XCTUnwrap(
                    peer.events.last(where: { $0.frame.payload["action"] == .string("chrome_open") })?
                        .frame.payload["request_generation"]?.stringValue)
                let control: JSONValue =
                    request.action == "chrome_note_search"
                    ? .object([
                        "type": .string("param_picker"), "title": .string(""), "description": .string(""),
                        "fields": .array([
                            .object([
                                "name": .string("search"), "label": .string("Search notes"),
                                "kind": .string("text"), "default": .string(""),
                            ])
                        ]),
                        "submit_label": .string("Search"), "submit_action": .string(request.action),
                        "submit_payload": .object([:]),
                    ])
                    : .object([
                        "type": .string("button"), "label": .string("Explicit action"), "variant": .string("secondary"),
                        "disabled": .bool(false), "local": .bool(false), "action": .string(request.action),
                        "payload": request.payload,
                    ])
                peer.send(
                    String(
                        decoding: try JSONValue.object([
                            "type": .string("chrome_surface"), "surface_key": .string("guidance"),
                            "region": .string("modal"),
                            "mode": .string("replace"), "title": .string("Private notes"), "admin_only": .bool(false),
                            "request_generation": .string(generation), "components": .array([control]),
                        ]).encoded(), as: UTF8.self))
                try await waitUntil("authorized notes action loaded") { model.guidanceUpdate?.permits(request) == true }
                XCTAssertTrue(model.sendGuidanceRequest(action: request.action, payload: request.payload))
                try await waitUntil("explicit notes action sent once") {
                    peer.events.filter { $0.frame.payload["action"] == .string(request.action) }.count == 1
                }
                let registered = peer.expectRegistration()
                peer.send(refusal)
                await fulfillment(of: [registered], timeout: timeout)
                try await waitUntil("replacement declaration") { model.connected && model.guidanceControls.count == 2 }
                XCTAssertEqual(peer.events.filter { $0.frame.payload["action"] == .string(request.action) }.count, 1)
                XCTAssertEqual(peer.events.filter { $0.frame.payload["action"] == .string("chrome_open") }.count, 1)
                XCTAssertTrue(model.guidanceFailed)
                XCTAssertNotNil(model.errorBanner)
            }
        }
    }

    func testNewConversationDuringRecoveryDoesNotRestoreTheRetiredSurfaceOrDraft() async throws {
        try await withModel { model, _, _, peer in
            model.openGuidance(try XCTUnwrap(model.guidanceControls.first))
            try await waitUntil("initial notes read sent") {
                peer.events.filter { $0.frame.payload["action"] == .string("chrome_open") }.count == 1
            }
            peer.holdRefresh()
            let refresh = peer.expectRefresh()
            let registered = peer.expectRegistration()
            peer.send(refusal)
            await fulfillment(of: [refresh], timeout: timeout)
            model.newConversation()
            model.pendingDictation = "New conversation draft"
            peer.releaseRefresh()
            await fulfillment(of: [registered], timeout: timeout)
            try await waitUntil("new socket’s current declaration") { model.guidanceControls.count == 2 }
            XCTAssertFalse(model.guidanceVisible)
            XCTAssertEqual(model.pendingDictation, "New conversation draft")
            XCTAssertEqual(peer.events.filter { $0.frame.payload["action"] == .string("chrome_open") }.count, 1)
            XCTAssertFalse(peer.events.contains { $0.frame.payload["action"] == .string("chat_message") })
        }
    }
}

private final class WatchAuthenticationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func advance(_ seconds: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(seconds)
        lock.unlock()
    }
}

private final class WatchAuthenticationPeer: @unchecked Sendable {
    struct Registration {
        let socket: Int
        let token: String
        let generation: String?
    }
    struct Event {
        let socket: Int
        let frame: InboundFrame
    }
    private final class Connection {
        let socket: Int
        let network: NWConnection
        var upgraded = false
        var buffer = Data()
        init(socket: Int, network: NWConnection) {
            self.socket = socket
            self.network = network
        }
    }

    let ready = XCTestExpectation(description: "local identity and socket peer ready")
    let listener: NWListener
    let originalToken: String
    private let clock: WatchAuthenticationClock
    private let queue = DispatchQueue(label: "astral.watch-authentication.tests")
    private var connections: [Connection] = []
    private var observedRegistrations: [Registration] = []
    private var observedEvents: [Event] = []
    private var observedRefreshes = 0
    private var observedAuthorization: [String] = []
    private var observedBrokerPayloads: [JSONValue] = []
    private var sameToken = false
    private var offersSelection = true
    private var rejectsRegistration = false
    private var registrationExpectation: XCTestExpectation?
    private var refreshExpectation: XCTestExpectation?
    private var refreshResponseExpectation: XCTestExpectation?
    private var recentsExpectation: XCTestExpectation?
    private var holdsRecents = false
    private var pendingRecents: [Connection] = []
    private var holdsRefresh = false
    private var pendingRefresh: [Connection] = []
    private var refreshStatus = 200
    private var refreshedSubject = "owner"
    private var refreshLifetime: TimeInterval = 86400

    init(clock: WatchAuthenticationClock, jwtLifetime: TimeInterval = 3600) throws {
        self.clock = clock
        originalToken = Self.token("original", subject: "owner", expiry: clock.now.addingTimeInterval(jwtLifetime))
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    private static func token(_ marker: String, subject: String, expiry: Date) -> String {
        let payload: [String: Any] = [
            "iss": "https://issuer.example.test", "sub": subject, "jti": marker,
            "exp": expiry.timeIntervalSince1970,
        ]
        return "fixture." + PKCE.base64url(try! JSONSerialization.data(withJSONObject: payload)) + ".fixture"
    }

    var registrations: [Registration] { queue.sync { observedRegistrations } }
    var events: [Event] { queue.sync { observedEvents } }
    var refreshCount: Int { queue.sync { observedRefreshes } }
    var restAuthorization: [String] { queue.sync { observedAuthorization } }
    var brokerPayloads: [JSONValue] { queue.sync { observedBrokerPayloads } }
    func tokenForSubject(_ subject: String) -> String {
        Self.token("replacement", subject: subject, expiry: clock.now.addingTimeInterval(3600))
    }
    func returnSameToken() { queue.sync { sameToken = true } }
    func retireSelectionOffer() { queue.sync { offersSelection = false } }
    func rejectNextRegistration() { queue.sync { rejectsRegistration = true } }

    func expectRegistration() -> XCTestExpectation {
        queue.sync {
            let value = XCTestExpectation(description: "next registered credential")
            registrationExpectation = value
            return value
        }
    }

    func expectRefresh() -> XCTestExpectation {
        queue.sync {
            let value = XCTestExpectation(description: "refresh request accepted by local peer")
            refreshExpectation = value
            return value
        }
    }

    func expectRefreshResponse() -> XCTestExpectation {
        queue.sync {
            let value = XCTestExpectation(description: "held broker response delivered")
            refreshResponseExpectation = value
            return value
        }
    }

    func holdRecents() -> XCTestExpectation {
        queue.sync {
            holdsRecents = true
            let value = XCTestExpectation(description: "authorized recent-chat response held")
            recentsExpectation = value
            return value
        }
    }

    func releaseRecents() {
        queue.async {
            self.holdsRecents = false
            for connection in self.pendingRecents {
                self.respond(
                    connection, status: 200,
                    payload: .array([
                        .object([
                            "id": .string("44444444-4444-4444-8444-444444444444"), "title": .string("Synthetic recent"),
                        ])
                    ]))
            }
            self.pendingRecents = []
        }
    }

    func holdRefresh() { queue.sync { holdsRefresh = true } }
    func configureRefresh(status: Int, subject: String = "owner", lifetime: TimeInterval = 86400) {
        queue.sync {
            refreshStatus = status
            refreshedSubject = subject
            refreshLifetime = lifetime
        }
    }
    func releaseRefresh() {
        queue.async {
            self.holdsRefresh = false
            for connection in self.pendingRefresh { self.respondRefresh(connection) }
            self.pendingRefresh = []
        }
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in if case .ready = state { self?.ready.fulfill() } }
        listener.newConnectionHandler = { [weak self] network in
            guard let self else {
                network.cancel()
                return
            }
            let connection = Connection(socket: self.connections.count, network: network)
            self.connections.append(connection)
            network.start(queue: self.queue)
            self.receive(connection)
        }
        listener.start(queue: queue)
    }

    private func receive(_ connection: Connection) {
        connection.network.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, complete, error in
            guard let self, error == nil else {
                connection.network.cancel()
                return
            }
            if let data { connection.buffer.append(data) }
            if connection.upgraded { self.consumeSocket(connection) } else { self.consumeHTTP(connection) }
            if complete { connection.network.cancel() } else { self.receive(connection) }
        }
    }

    private func consumeHTTP(_ connection: Connection) {
        guard let boundary = connection.buffer.range(of: Data("\r\n\r\n".utf8)),
            let header = String(data: connection.buffer[..<boundary.lowerBound], encoding: .utf8)
        else { return }
        let lines = header.components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pieces = line.split(separator: ":", maxSplits: 1)
            if pieces.count == 2 { headers[pieces[0].lowercased()] = pieces[1].trimmingCharacters(in: .whitespaces) }
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard connection.buffer.count >= boundary.upperBound + length else { return }
        let body = connection.buffer.subdata(in: boundary.upperBound..<(boundary.upperBound + length))
        connection.buffer.removeFirst(boundary.upperBound + length)
        if let key = headers["sec-websocket-key"] {
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
                .base64EncodedString()
            connection.upgraded = true
            connection.network.send(
                content: Data(
                    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
                        .utf8),
                completion: .contentProcessed { _ in })
            consumeSocket(connection)
        } else if lines[0].contains("/api/auth/device/refresh ") {
            observedBrokerPayloads.append((try? JSONValue.parse(body)) ?? .null)
            observedRefreshes += 1
            refreshExpectation?.fulfill()
            refreshExpectation = nil
            if holdsRefresh { pendingRefresh.append(connection) } else { respondRefresh(connection) }
        } else {
            observedAuthorization.append(headers["authorization"] ?? "")
            if holdsRecents, lines[0].hasPrefix("GET /api/chats ") {
                pendingRecents.append(connection)
                recentsExpectation?.fulfill()
                recentsExpectation = nil
            } else {
                respond(connection, status: 200, payload: .array([]))
            }
        }
    }

    private func respondRefresh(_ connection: Connection) {
        let token =
            sameToken
            ? originalToken
            : Self.token(
                "rotated-\(observedRefreshes)", subject: refreshedSubject,
                expiry: clock.now.addingTimeInterval(refreshLifetime))
        respond(
            connection, status: refreshStatus,
            payload: refreshStatus == 200
                ? .object([
                    "access_token": .string(token), "refresh_token": .string("fixture-rotated-refresh"),
                    "expires_in": .number(refreshLifetime),
                ])
                : .object(["error": .string("fixture_denial")]))
        refreshResponseExpectation?.fulfill()
        refreshResponseExpectation = nil
    }

    private func respond(_ connection: Connection, status: Int, payload: JSONValue) {
        let body = try! payload.encoded()
        let header =
            "HTTP/1.1 \(status) Fixture\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.network.send(
            content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.network.cancel() })
    }

    private func consumeSocket(_ connection: Connection) {
        while connection.buffer.count >= 2 {
            let bytes = [UInt8](connection.buffer)
            let opcode = bytes[0] & 15
            let masked = bytes[1] & 128 != 0
            var length = Int(bytes[1] & 127)
            var offset = 2
            if length == 126 {
                guard bytes.count >= 4 else { return }
                length = Int(bytes[2]) * 256 + Int(bytes[3])
                offset = 4
            }
            guard length < 65536, length != 127 else {
                connection.network.cancel()
                return
            }
            let maskOffset = offset
            if masked { offset += 4 }
            guard bytes.count >= offset + length else { return }
            var body = Array(bytes[offset..<(offset + length)])
            if masked { for index in body.indices { body[index] ^= bytes[maskOffset + index % 4] } }
            connection.buffer.removeFirst(offset + length)
            if opcode == 8 {
                connection.network.cancel()
                return
            }
            guard opcode == 1, let text = String(bytes: body, encoding: .utf8), let frame = InboundFrame.parse(text)
            else { continue }
            if frame.name == "register_ui" {
                observedRegistrations.append(
                    Registration(
                        socket: connection.socket, token: frame.payload["token"]?.stringValue ?? "",
                        generation: frame.payload["connection_generation"]?.stringValue))
                registrationExpectation?.fulfill()
                registrationExpectation = nil
                if rejectsRegistration {
                    rejectsRegistration = false
                    send(#"{"type":"auth_required","reason":"expired"}"#, to: connection)
                } else {
                    send(#"{"type":"ready"}"#, to: connection)
                    send(menu(), to: connection)
                }
            } else {
                observedEvents.append(Event(socket: connection.socket, frame: frame))
            }
        }
    }

    private func send(_ text: String, to connection: Connection) {
        let content = Data(text.utf8)
        var header = Data([129])
        if content.count < 126 {
            header.append(UInt8(content.count))
        } else {
            header.append(contentsOf: [126, UInt8(content.count >> 8), UInt8(content.count & 255)])
        }
        connection.network.send(content: header + content, completion: .contentProcessed { _ in })
    }

    func send(_ text: String, socket: Int? = nil) {
        queue.async {
            if let connection = self.connections.last(where: { $0.upgraded && (socket == nil || $0.socket == socket) })
            {
                self.send(text, to: connection)
            }
        }
    }

    func disconnect(socket: Int) {
        queue.sync { connections.first { $0.socket == socket }?.network.cancel() }
    }

    private func menu() -> String {
        var controls: [JSONValue] = [
            .object([
                "key": .string("guidance"), "kind": .string("action"), "label": .string("Private notes"),
                "action": .object(["surface": .string("guidance"), "params": .object(["mode": .string("list")])]),
            ])
        ]
        controls.append(
            .object([
                "key": .string("work"), "kind": .string("action"), "label": .string("Work"),
                "action": .object(["surface": .string("work"), "params": .object(["mode": .string("list")])]),
            ]))
        if offersSelection {
            controls.append(
                .object([
                    "key": .string("advanced"), "kind": .string("action"), "label": .string("Advanced settings"),
                    "action": .object([
                        "surface": .string("guidance"), "params": .object(["view": .string("selection")]),
                    ]),
                ]))
        }
        return String(
            decoding: try! JSONValue.object([
                "type": .string("chrome_menu"),
                "model": .object(["version": .number(2), "topbar": .array(controls), "menu": .array([])]),
            ]).encoded(), as: UTF8.self)
    }

    func stop() {
        queue.sync {
            listener.cancel()
            for connection in connections { connection.network.cancel() }
        }
    }
}
