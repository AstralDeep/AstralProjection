// Verifies MeshRuntime against an in-memory kernel: opening, enrollment, pairing, chats and branches, turns, consent, models, allowance, sync state and voice.
// Each test drives kernel changes through the listener so the published state is checked the way the screens read it.

@testable import AstralDeep
import AstralCore
import XCTest

final class MeshRuntimeTests: XCTestCase {
    func testOpenLoadsStatusChatsAndStartsNetwork() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        XCTAssertEqual(h.runtime.phase, .ready)
        XCTAssertTrue(h.runtime.hasMesh)
        XCTAssertEqual(h.runtime.members.count, 1)
        XCTAssertEqual(h.kernel.calls.first?.name, "startNetwork")
        XCTAssertEqual(h.runtime.kernelVersion, "in-memory")
    }

    func testOpenFailureIsReportedAndRetryable() async {
        let h = MeshRuntimeHarness(factoryError: .unavailable("No runtime"))
        defer { h.cleanUp() }
        await h.runtime.open()
        XCTAssertEqual(h.runtime.phase, .failed("No runtime"))
        await h.runtime.open()
        XCTAssertEqual(h.runtime.phase, .failed("No runtime"))
    }

    func testBuildWithoutRuntimeFailsHonestly() async {
        let defaults = UserDefaults(suiteName: "mesh.unavailable." + UUID().uuidString)!
        let runtime = MeshRuntime(
            makeKernel: { _, _, _, _, _ in throw MeshKernelError.unavailable("This build does not include the mesh runtime yet.") },
            makeKeys: {
                try DeviceKeys(
                    store: MeshMemorySecretStore(), defaults: UserDefaults(suiteName: "mesh.k." + UUID().uuidString)!,
                    preferHardware: false)
            },
            consent: ConsentCoordinator(), onDeviceModel: FakeOnDeviceModel(), tools: DeviceLocalTools(),
            dataDirectory: FileManager.default.temporaryDirectory, deviceLabel: "Mac", deviceKind: .desktop,
            enrollment: { _ in "" }, defaults: defaults)
        await runtime.open()
        guard case .failed(let message) = runtime.phase else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("mesh runtime"))
    }

    func testNetworkFailureKeepsRuntimeOpenWithNotice() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        h.kernel.failure = .unavailable("Offline")
        await h.runtime.refreshChats()
        XCTAssertEqual(h.runtime.notice, "Offline")
        XCTAssertEqual(h.runtime.phase, .ready)
    }

    func testCreateMeshSignsInWithKernelNonceAndShowsRecoveryWords() async {
        let h = MeshRuntimeHarness(hasMesh: false)
        defer { h.cleanUp() }
        await h.runtime.open()
        XCTAssertFalse(h.runtime.hasMesh)
        await h.runtime.createMesh()
        XCTAssertEqual(h.tokens.seen, ["nonce-1"])
        XCTAssertEqual(h.kernel.calls.map(\.name).filter { $0.hasSuffix("MeshCreation") }.count, 2)
        XCTAssertTrue(h.kernel.calls.contains(.init(name: "completeMeshCreation", detail: "id-token")))
        guard case .recovery(let words) = h.runtime.creation else { return XCTFail("expected recovery words") }
        XCTAssertEqual(words.count, 24)
        XCTAssertTrue(h.runtime.hasMesh)
    }

    func testCreateMeshStopsWhenSignInFails() async {
        let h = MeshRuntimeHarness(hasMesh: false, enrollment: { _ in throw EnrollmentSignInError.cancelled })
        defer { h.cleanUp() }
        await h.runtime.open()
        await h.runtime.createMesh()
        XCTAssertEqual(h.runtime.creation, .failed("Sign-in was cancelled."))
        XCTAssertFalse(h.kernel.calls.contains { $0.name == "completeMeshCreation" })
        XCTAssertFalse(h.runtime.hasMesh)
        h.runtime.dismissCreationFailure()
        XCTAssertEqual(h.runtime.creation, .idle)
    }

    func testRecoveryConfirmationNeedsTheRightWords() async {
        let h = MeshRuntimeHarness(hasMesh: false)
        defer { h.cleanUp() }
        await h.runtime.open()
        await h.runtime.createMesh()
        XCTAssertFalse(h.runtime.confirmRecoveryWritten(answers: ["word7", "nope"]))
        XCTAssertFalse(h.runtime.confirmRecoveryWritten(answers: ["word7"]))
        guard case .recovery = h.runtime.creation else { return XCTFail("words must stay until confirmed") }
        XCTAssertTrue(h.runtime.confirmRecoveryWritten(answers: [" WORD7 ", "word18"]))
        XCTAssertEqual(h.runtime.creation, .idle)
    }

    func testRecoveryConfirmationPositionsAreCheckedAgainstTheList() {
        let words = (1...24).map { "w\($0)" }
        XCTAssertTrue(MeshRecoveryConfirmation.verify(words: words, answers: ["w7", "w18"]))
        XCTAssertFalse(MeshRecoveryConfirmation.verify(words: words, answers: ["w18", "w7"]))
        XCTAssertFalse(MeshRecoveryConfirmation.verify(words: ["a"], answers: ["a", "a"]))
    }

    func testJoinShowsOfferThenCompletesWhenRosterArrives() async {
        let h = MeshRuntimeHarness(hasMesh: false)
        defer { h.cleanUp() }
        await h.runtime.open()
        await h.runtime.beginJoin()
        guard case .offered(let offer) = h.runtime.join else { return XCTFail("expected an offer") }
        XCTAssertEqual(offer.shortCode, "12345678")
        XCTAssertEqual(offer.payload, "astral-pair:v1:offer")
        XCTAssertNotNil(offer.expiresAt)
        h.kernel.completeJoin()
        await h.runtime.settle()
        XCTAssertEqual(h.runtime.join, .joined)
        XCTAssertTrue(h.runtime.hasMesh)
    }

    func testCancelJoinReturnsToChoices() async {
        let h = MeshRuntimeHarness(hasMesh: false)
        defer { h.cleanUp() }
        await h.runtime.open()
        await h.runtime.beginJoin()
        h.runtime.cancelJoin()
        XCTAssertEqual(h.runtime.join, .idle)
    }

    func testAddDeviceShowsComparisonThenApprovesThroughKernel() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        await h.runtime.previewAddDevice(payload: "  astral-pair:v1:offer \n")
        guard case .previewing(let preview, let payload) = h.runtime.addDevice else { return XCTFail("preview") }
        XCTAssertEqual(preview.comparisonCode, "4821 9307")
        XCTAssertEqual(payload, "astral-pair:v1:offer")
        await h.runtime.approveAddDevice()
        XCTAssertEqual(h.runtime.addDevice, .added("New phone"))
        XCTAssertEqual(h.runtime.members.count, 2)
    }

    func testAddDeviceDeniedConsentDoesNotAddAndSaysSo() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        h.kernel.consentGate = { throw MeshKernelError.consentDenied }
        await h.runtime.previewAddDevice(payload: "astral-pair:v1:offer")
        await h.runtime.approveAddDevice()
        XCTAssertEqual(h.runtime.addDevice, .failed("Adding the device was not approved."))
        XCTAssertEqual(h.runtime.members.count, 1)
    }

    func testAddDeviceRejectsEmptyOversizedAndMalformedPayloads() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        await h.runtime.previewAddDevice(payload: "   ")
        XCTAssertEqual(h.runtime.addDevice, .failed("That is not a pairing code from one of your devices."))
        await h.runtime.previewAddDevice(payload: String(repeating: "a", count: 9000))
        XCTAssertEqual(h.runtime.addDevice, .failed("That is not a pairing code from one of your devices."))
        await h.runtime.previewAddDevice(payload: "garbage")
        XCTAssertEqual(h.runtime.addDevice, .failed("pairing.malformed"))
        await h.runtime.approveAddDevice()
        XCTAssertFalse(h.kernel.calls.contains { $0.name == "approvePairing" })
    }

    func testRemoveDeviceNeverRemovesThisDevice() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        await h.runtime.previewAddDevice(payload: "astral-pair:v1:offer")
        await h.runtime.approveAddDevice()
        let other = h.runtime.members.first { !$0.isThisDevice }!
        let this = h.runtime.members.first { $0.isThisDevice }!
        await h.runtime.removeDevice(this)
        XCTAssertEqual(h.runtime.members.count, 2)
        await h.runtime.removeDevice(other)
        XCTAssertEqual(h.runtime.members.count, 1)
    }

    func testEmergencyStopMarksMeshStoppedAndBlocksSending() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        _ = await h.runtime.newChat()
        await h.runtime.raiseStop()
        XCTAssertTrue(h.runtime.status.stopped)
        let sent = await h.runtime.send("hello")
        XCTAssertFalse(sent)
        XCTAssertEqual(h.runtime.notice, "The mesh is stopped.")
        XCTAssertFalse(h.kernel.calls.contains { $0.name == "sendMessage" })
    }

    func testSendRunsATurnAndStreamsAssistantText() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        _ = await h.runtime.newChat()
        let sent = await h.runtime.send("hi")
        XCTAssertTrue(sent)
        await h.runtime.settle()
        let rows = h.runtime.displayRows
        XCTAssertEqual(rows.map(\.turn.role), ["user", "assistant"])
        XCTAssertEqual(rows.last?.turn.text, "Hello there")
        XCTAssertEqual(h.runtime.currentTurn?.running, false)
        XCTAssertEqual(h.runtime.currentTurn?.streamingText, "")
        XCTAssertEqual(rows.first?.message?.delivery, .recorded)
    }

    func testSendWithoutAChatCreatesOneTitledFromTheMessage() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let sent = await h.runtime.send("Plan my week\nwith details")
        XCTAssertTrue(sent)
        await h.runtime.settle()
        XCTAssertEqual(h.runtime.currentChat?.title, "Plan my week")
        XCTAssertEqual(h.runtime.chats.count, 1)
    }

    func testMessageStaysQueuedWhenTheTurnCannotRun() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        _ = await h.runtime.newChat()
        h.kernel.turnError = .refused("No model is reachable.")
        let sent = await h.runtime.send("offline hello")
        XCTAssertTrue(sent)
        await h.runtime.settle()
        XCTAssertEqual(h.runtime.displayRows.first?.message?.delivery, .queued)
        XCTAssertEqual(h.runtime.currentTurn?.failure, "No model is reachable.")
        XCTAssertEqual(h.runtime.currentTurn?.running, false)
        XCTAssertEqual(h.runtime.chats.first?.queuedCount, 1)
    }

    func testEmptyAndFailedSendsAreNotAccepted() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        _ = await h.runtime.newChat()
        let empty = await h.runtime.send("   ")
        XCTAssertFalse(empty)
        h.kernel.failure = .storage("Disk is full")
        let failed = await h.runtime.send("hello")
        XCTAssertFalse(failed)
        XCTAssertEqual(h.runtime.notice, "Disk is full")
    }

    func testToolActivityIsPublishedWhileTheTurnRuns() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        _ = await h.runtime.newChat()
        h.kernel.turnScript = [
            .started, .toolStarted(id: "t1", name: "search", cancelSafe: true),
            .toolFinished(id: "t1", succeeded: true), .toolStarted(id: "t2", name: "send_mail", cancelSafe: false),
            .toolFinished(id: "t2", succeeded: false), .finished,
        ]
        _ = await h.runtime.send("go")
        await h.runtime.settle()
        XCTAssertEqual(
            h.runtime.currentTurn?.tools.map(\.state), [.succeeded, .failed])
        XCTAssertEqual(h.runtime.currentTurn?.tools.map(\.name), ["search", "send_mail"])
    }

    func testBranchesFollowTheLatestLeafAndSelectionContinuesThatBranch() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let chat = h.kernel.seedChat(
            title: "Forked",
            messages: [
                MeshRuntimeHarness.message("a", parent: nil, at: 1),
                MeshRuntimeHarness.message("b", parent: "a", author: .assistant, at: 2),
                MeshRuntimeHarness.message("c", parent: "b", at: 3),
                MeshRuntimeHarness.message("d", parent: "b", at: 4),
            ])
        await h.runtime.refreshChats()
        await h.runtime.openChat(chat)
        XCTAssertEqual(h.runtime.displayRows.map(\.turn.id), ["a", "b", "d"])
        XCTAssertEqual(h.runtime.chats.first?.branchCount, 1)
        h.runtime.selectBranch(head: "c")
        XCTAssertEqual(h.runtime.displayRows.map(\.turn.id), ["a", "b", "c"])
        _ = await h.runtime.send("continue c")
        XCTAssertTrue(h.kernel.calls.contains(.init(name: "sendMessage", detail: "continue c|c")))
        await h.runtime.settle()
        XCTAssertEqual(h.runtime.displayRows.map(\.turn.id).prefix(3), ["a", "b", "c"])
    }

    func testBranchFromMessageForksAndTheNextMessageIsASibling() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let chat = h.kernel.seedChat(
            title: "Chat",
            messages: [
                MeshRuntimeHarness.message("a", parent: nil, at: 1),
                MeshRuntimeHarness.message("b", parent: "a", author: .assistant, at: 2),
            ])
        await h.runtime.openChat(chat)
        let first = h.runtime.currentChat!.messages[0]
        await h.runtime.branchFrom(message: first)
        XCTAssertTrue(h.kernel.calls.contains(.init(name: "fork", detail: "a")))
        XCTAssertEqual(h.runtime.displayRows.map(\.turn.id), ["a"])
        _ = await h.runtime.send("another way")
        XCTAssertTrue(h.kernel.calls.contains(.init(name: "sendMessage", detail: "another way|a")))
        await h.runtime.settle()
        XCTAssertEqual(h.runtime.displayRows.first?.turn.id, "a")
        XCTAssertEqual(h.runtime.displayRows.dropFirst().first?.turn.text, "another way")
        XCTAssertEqual(h.runtime.currentChat?.branches.count, 2)
    }

    func testPendingConsentIsListedAndDenyAlwaysWorks() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        let sink = RecordingSpeechSink()
        h.runtime.speechSink = sink
        await h.runtime.open()
        let request = MeshPendingConsent(
            requestId: "r1", chatId: nil, kind: .action, canonicalAction: Data("x".utf8),
            canonicalArguments: Data("{}".utf8), signingInput: Data("y".utf8))
        h.kernel.setPending([request])
        await h.runtime.settle()
        XCTAssertEqual(h.runtime.pendingConsents.map(\.requestId), ["r1"])
        XCTAssertNil(h.runtime.prompt(for: request))
        XCTAssertEqual(sink.risky.last, true)
        h.kernel.consentGate = { throw MeshKernelError.consentDenied }
        await h.runtime.deny(request)
        XCTAssertTrue(h.runtime.pendingConsents.isEmpty)
        XCTAssertEqual(sink.risky.last, false)
        XCTAssertTrue(h.kernel.calls.contains(.init(name: "resolveConsent", detail: "r1:deny")))
    }

    func testReviewApprovesThroughTheKernelAndDeniedBiometricsSettleAsDenied() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let request = MeshPendingConsent(
            requestId: "r2", chatId: nil, kind: .roster, canonicalAction: Data(), canonicalArguments: Data(),
            signingInput: Data())
        h.kernel.setPending([request])
        await h.runtime.settle()
        h.kernel.consentGate = { throw HostSigningError.consentDenied(.denied) }
        await h.runtime.review(request)
        XCTAssertTrue(h.kernel.calls.contains(.init(name: "resolveConsent", detail: "r2:approve")))
        XCTAssertTrue(h.kernel.calls.contains(.init(name: "resolveConsent", detail: "r2:deny")))
        XCTAssertTrue(h.runtime.pendingConsents.isEmpty)
        XCTAssertNil(h.runtime.notice)
    }

    func testReviewFailureOtherThanDenialIsReportedAndRequestStays() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let request = MeshPendingConsent(
            requestId: "r3", chatId: nil, kind: .action, canonicalAction: Data(), canonicalArguments: Data(),
            signingInput: Data())
        h.kernel.setPending([request])
        await h.runtime.settle()
        h.kernel.consentGate = { throw HostSigningError.digestMismatch }
        await h.runtime.review(request)
        XCTAssertEqual(h.runtime.notice, "The approval did not match the request, so nothing was signed.")
        XCTAssertFalse(h.kernel.calls.contains(.init(name: "resolveConsent", detail: "r3:deny")))
    }

    func testProviderInputValidation() {
        func result(_ url: String, _ model: String = "m", _ key: String = "k") -> MeshProviderInputError? {
            if case .failure(let error) = MeshProviderInput.validate(baseURL: url, model: model, key: key) {
                return error
            }
            return nil
        }
        XCTAssertNil(result("https://api.example.com/v1"))
        XCTAssertNil(result("http://localhost:11434/v1"))
        XCTAssertNil(result("http://127.0.0.1:8080"))
        XCTAssertEqual(result("http://api.example.com/v1"), .insecureURL)
        XCTAssertEqual(result("ftp://api.example.com"), .invalidURL)
        XCTAssertEqual(result("not a url"), .invalidURL)
        XCTAssertEqual(result("https://user:pw@api.example.com"), .invalidURL)
        XCTAssertEqual(result("https://api.example.com", "  "), .missingModel)
        XCTAssertEqual(result("https://api.example.com", "m", ""), .missingKey)
    }

    func testSavingAProviderSendsItToTheKernelOnceAndShowsNoKey() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let rejected = await h.runtime.saveProvider(baseURL: "http://api.example.com", model: "m", key: "secret")
        XCTAssertEqual(rejected, .insecureURL)
        XCTAssertFalse(h.kernel.calls.contains { $0.name == "setModelProvider" })
        let accepted = await h.runtime.saveProvider(baseURL: "https://api.example.com/v1", model: "gpt", key: "secret")
        XCTAssertNil(accepted)
        XCTAssertEqual(h.runtime.providers.map(\.model), ["gpt"])
        XCTAssertTrue(h.runtime.providers.allSatisfy(\.hasKey))
        XCTAssertFalse(h.kernel.calls.contains { $0.detail.contains("secret") })
    }

    func testAllowanceAndSyncRefreshFromListenerEvents() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        XCTAssertEqual(h.runtime.syncSummary, .alone)
        h.kernel.setAllowance(
            MeshAllowance(
                share: .solo, periodEndsAt: nil, lines: [.init(effectClass: "writes", remaining: 3, limit: 50)],
                modelTokensRemaining: 10, modelTokensLimit: 100, blocked: .soloNeedsConsent))
        h.kernel.setMembers([
            MeshMember(
                memberId: "me", label: "This", kind: .desktop, isThisDevice: true, attested: true, lastSeen: nil,
                path: .none),
            MeshMember(
                memberId: "ph", label: "Phone", kind: .pocket, isThisDevice: false, attested: false,
                lastSeen: Date(timeIntervalSince1970: 100), path: .relay),
        ])
        h.kernel.setSync(
            MeshSyncState(
                devices: [
                    MeshDeviceSync(
                        memberId: "ph", label: "Phone", state: .unreachable, lastSeen: Date(timeIntervalSince1970: 100),
                        path: .none)
                ], updatedAt: nil))
        await h.runtime.settle()
        XCTAssertEqual(h.runtime.allowance?.blocked, .soloNeedsConsent)
        XCTAssertEqual(h.runtime.syncSummary, .waiting(device: "Phone", since: Date(timeIntervalSince1970: 100)))
        h.kernel.setSync(
            MeshSyncState(
                devices: [
                    MeshDeviceSync(memberId: "ph", label: "Phone", state: .synced, lastSeen: nil, path: .direct)
                ], updatedAt: nil))
        await h.runtime.settle()
        XCTAssertEqual(h.runtime.syncSummary, .synced)
    }

    func testOutcomeUnknownIsShownAndTheOwnerCanLeaveItOrCheckFirst() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        _ = await h.runtime.newChat()
        let outcome = MeshUnknownOutcome(stepId: "s1", tool: "send_mail", summary: "Send the report")
        h.kernel.turnScript = [.started, .outcomeUnknown(outcome), .finished]
        _ = await h.runtime.send("mail it")
        await h.runtime.settle()
        XCTAssertEqual(h.runtime.currentTurn?.unknown, [outcome])
        XCTAssertTrue(h.runtime.outcomeNeedsAttention(outcome))
        await h.runtime.resolveUnknown(outcome, choice: .leaveAsUnknown)
        XCTAssertFalse(h.runtime.outcomeNeedsAttention(outcome))
        XCTAssertEqual(h.defaults.stringArray(forKey: "astral.mesh.acknowledged-outcomes"), ["s1"])
        let before = h.kernel.calls.filter { $0.name == "runTurn" }.count
        let other = MeshUnknownOutcome(stepId: "s2", tool: "delete_file", summary: "")
        await h.runtime.resolveUnknown(other, choice: .checkFirst)
        await h.runtime.settle()
        XCTAssertEqual(h.kernel.calls.filter { $0.name == "runTurn" }.count, before + 1)
        XCTAssertTrue(
            h.kernel.calls.contains { $0.name == "sendMessage" && $0.detail.contains("check whether delete_file") })
    }

    func testOutcomeUnknownFromTheLogIsRestoredAfterReopen() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let chat = h.kernel.seedChat(title: "Crashed", messages: [MeshRuntimeHarness.message("a", parent: nil, at: 1)])
        let outcome = MeshUnknownOutcome(stepId: "s9", tool: "post", summary: "Post update")
        h.kernel.setChatStatus(chatId: chat, .outcomeUnknown(outcome))
        await h.runtime.openChat(chat)
        XCTAssertEqual(h.runtime.currentTurn?.unknown, [outcome])
    }

    func testInterruptIsSentOnceForARunningTurn() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let chat = await h.runtime.newChat()!
        h.kernel.turnScript = [.started]
        _ = await h.runtime.send("long")
        await h.runtime.settle()
        XCTAssertEqual(h.runtime.currentTurn?.running, true)
        await h.runtime.interrupt()
        await h.runtime.interrupt()
        XCTAssertEqual(h.kernel.calls.filter { $0.name == "interrupt" }.count, 1)
        XCTAssertEqual(h.kernel.calls.last { $0.name == "interrupt" }?.detail, chat)
    }

    func testSteerGoesToTheKernel() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        _ = await h.runtime.newChat()
        await h.runtime.steer("shorter please")
        XCTAssertTrue(h.kernel.calls.contains(.init(name: "steer", detail: "shorter please")))
    }

    func testCloseStopsTheNetworkAndClearsState() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        _ = await h.runtime.newChat()
        await h.runtime.close()
        XCTAssertEqual(h.runtime.phase, .closed)
        XCTAssertFalse(h.runtime.hasMesh)
        XCTAssertTrue(h.runtime.chats.isEmpty)
        XCTAssertTrue(h.kernel.calls.contains { $0.name == "stopNetwork" })
    }

    func testSurfaceActionsReachTheKernel() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        await h.runtime.act(surfaceId: "s", componentId: "c", capability: "cap")
        XCTAssertTrue(h.kernel.calls.contains(.init(name: "act", detail: "s/c/cap")))
        XCTAssertNil(h.runtime.notice)
    }

    func testSurfaceInputsSendTheirValueAndARefusalShowsItsCode() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        await h.runtime.act(surfaceId: "s", componentId: "c", capability: "cap", args: ["value": .string("hi")])
        XCTAssertTrue(h.kernel.calls.contains { $0.name == "act" && $0.detail.hasPrefix("s/c/cap?value=") })
        h.kernel.actResult = MeshActResult(status: "refused", code: "gate.permission_denied", text: "")
        await h.runtime.act(surfaceId: "s", componentId: "c", capability: "cap")
        XCTAssertEqual(h.runtime.notice, KernelMapping.failureText(code: "gate.permission_denied", fallback: "That action did not run."))
        XCTAssertTrue(h.runtime.notice?.contains("safety check") == true)
        h.runtime.notice = nil
        h.kernel.actResult = MeshActResult(status: "error", code: nil, text: "boom")
        await h.runtime.act(surfaceId: "s", componentId: "c", capability: "cap")
        XCTAssertEqual(h.runtime.notice, "That action did not run. (error)")
    }

    func testAHaltedMeshCanBeResumedThroughTheConsentGate() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        await h.runtime.raiseStop()
        XCTAssertTrue(h.runtime.status.stopped)
        h.kernel.consentGate = { throw MeshKernelError.consentDenied }
        await h.runtime.resume()
        XCTAssertTrue(h.runtime.status.stopped)
        XCTAssertEqual(h.runtime.notice, "The approval was denied.")
        h.kernel.consentGate = {}
        h.runtime.notice = nil
        await h.runtime.resume()
        XCTAssertFalse(h.runtime.status.stopped)
        XCTAssertNil(h.runtime.notice)
        XCTAssertEqual(h.kernel.calls.filter { $0.name == "resumeStop" }.count, 2)
    }
}
