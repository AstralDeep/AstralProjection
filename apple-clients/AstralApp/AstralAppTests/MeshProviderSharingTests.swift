// Verifies model-provider save receipts and recipient controls without exposing stored credentials.
// Runtime writes use the same in-memory Kernel contract as the provider form.

import AstralKernel
import XCTest

@testable import AstralDeep

final class MeshProviderSharingTests: XCTestCase {
    func testProviderMetadataUsesNativeCustodyAndAudienceFacts() {
        let info = ModelProviderInfo(
            name: "provider", baseUrl: "https://provider.example.test/v1", models: ["model"], fallbackOrder: 0,
            selfHosted: false, recipients: ["phone"], hasCredentials: false, availableOnDevice: false)
        let mapped = KernelMapping.provider(info, lowestOrder: 0)
        XCTAssertFalse(mapped.hasKey)
        XCTAssertFalse(mapped.availableOnDevice)
        XCTAssertEqual(mapped.recipients, ["phone"])
        var stored = info
        stored.hasCredentials = true
        stored.availableOnDevice = true
        stored.recipients = nil
        let all = KernelMapping.provider(stored, lowestOrder: 0)
        XCTAssertTrue(all.hasKey)
        XCTAssertTrue(all.availableOnDevice)
        XCTAssertNil(all.recipients)
    }

    func testFailedProviderWriteDoesNotReturnASavedReceipt() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        h.kernel.failure = .storage("The provider could not be sealed.")
        let problem = await h.runtime.saveProvider(
            baseURL: "https://provider.example.test/v1", model: "model", key: "entered-key")
        XCTAssertEqual(problem?.message, "The provider could not be sealed.")
        XCTAssertTrue(h.runtime.providers.isEmpty)
    }

    func testAllDevicesRemainsTheDefaultAndExplicitRecipientsReachTheKernel() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let all = await h.runtime.saveProvider(
            baseURL: "https://provider.example.test/v1", model: "model", key: "entered-key")
        XCTAssertNil(all)
        XCTAssertNil(h.runtime.providers.first?.recipients)
        XCTAssertEqual(h.runtime.providers.first?.hasKey, true)
        XCTAssertEqual(h.runtime.providers.first?.availableOnDevice, true)
        let member = h.runtime.members[0].memberId
        let selected = await h.runtime.saveProvider(
            baseURL: "https://provider.example.test/v1", model: "model", key: "entered-key", recipients: [member])
        XCTAssertNil(selected)
        XCTAssertEqual(h.runtime.providers.first?.recipients, [member])
    }

    func testEmptyRecipientSelectionIsDeniedBeforeWriting() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let result = await h.runtime.saveProvider(
            baseURL: "https://provider.example.test/v1", model: "model", key: "entered-key", recipients: [])
        XCTAssertNotNil(result)
        XCTAssertFalse(h.kernel.calls.contains { $0.name == "setModelProvider" })
    }

    func testAConcurrentSaveIsRefusedUntilTheFirstNativeWriteCompletes() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let gate = ResumeWriteGate()
        defer { gate.release() }
        h.kernel.providerSaveGate = { if !gate.entered { gate.wait() } }
        let first = Task {
            await h.runtime.saveProvider(baseURL: "https://provider.example.test/v1", model: "first", key: "first-key")
        }
        let entered = await eventually { gate.entered }
        XCTAssertTrue(entered)
        let second = await h.runtime.saveProvider(
            baseURL: "https://provider.example.test/v1", model: "second", key: "second-key")
        XCTAssertNotNil(second)
        XCTAssertEqual(h.kernel.calls.filter { $0.name == "setModelProvider" }.count, 1)
        gate.release()
        let completed = await first.value
        XCTAssertNil(completed)
        XCTAssertEqual(h.runtime.providers.map(\.model), ["first"])
    }

    func testEditingSharingUsesInternalResealingAndCanExcludeThisDevice() async throws {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let peer = MeshMember(
            memberId: "peer", label: "Phone", kind: .pocket, isThisDevice: false, lastSeen: nil,
            path: .none)
        h.kernel.setMembers(h.runtime.members + [peer])
        _ = await h.runtime.saveProvider(
            baseURL: "https://provider.example.test/v1", model: "model", key: "entered-key")
        let provider = try XCTUnwrap(h.runtime.providers.first)
        let result = await h.runtime.setProviderRecipients(provider, recipients: [peer.memberId])
        let updated = try result.get()
        XCTAssertEqual(updated.recipients, [peer.memberId])
        XCTAssertTrue(updated.hasKey)
        XCTAssertFalse(updated.availableOnDevice)
        XCTAssertTrue(h.runtime.providers.isEmpty)
        XCTAssertEqual(h.kernel.calls.filter { $0.name == "setModelProvider" }.count, 1)
        XCTAssertEqual(h.kernel.calls.filter { $0.name == "setModelProviderRecipients" }.count, 1)
    }

    func testTheEditorRetainsTheEnteredKeyAndSelectionOnFailure() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let editor = MeshProviderEditor()
        editor.providerName = "provider"
        editor.baseURL = "https://provider.example.test/v1"
        editor.model = "model"
        editor.key = "entered-key"
        editor.recipients = [h.runtime.members[0].memberId]
        h.kernel.failure = .storage("The provider could not be sealed.")
        await editor.save(in: h.runtime)
        XCTAssertEqual(editor.key, "entered-key")
        XCTAssertEqual(editor.recipients, [h.runtime.members[0].memberId])
        XCTAssertFalse(editor.saved)
        XCTAssertNotNil(editor.problem)
        h.kernel.failure = nil
        await editor.save(in: h.runtime)
        XCTAssertEqual(editor.key, "")
        XCTAssertTrue(editor.saved)
        editor.model = "edited"
        XCTAssertFalse(editor.saved)
    }

    func testFailedSharingSaveKeepsThePreviousNativeAudience() async throws {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        _ = await h.runtime.saveProvider(
            baseURL: "https://provider.example.test/v1", model: "model", key: "entered-key")
        let provider = try XCTUnwrap(h.runtime.providers.first)
        h.kernel.failure = .refused("Sharing was not saved.")
        let result = await h.runtime.setProviderRecipients(provider, recipients: ["missing-device"])
        guard case .failure(let problem) = result else { return XCTFail("A refused reseal cannot become Saved") }
        XCTAssertEqual(problem.message, "Sharing was not saved.")
        XCTAssertNil(h.runtime.providers.first?.recipients)
        XCTAssertFalse(h.runtime.savingProvider)
    }

    func testAKeyEditedDuringAnAcceptedSaveIsNotCleared() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let editor = MeshProviderEditor()
        editor.providerName = "provider"
        editor.baseURL = "https://provider.example.test/v1"
        editor.model = "submitted"
        editor.key = "submitted-key"
        let gate = ResumeWriteGate()
        defer { gate.release() }
        h.kernel.providerSaveGate = { if !gate.entered { gate.wait() } }
        let saving = Task { await editor.save(in: h.runtime) }
        let entered = await eventually { gate.entered }
        XCTAssertTrue(entered)
        editor.key = "new-draft-key"
        editor.model = "new-draft-model"
        await editor.save(in: h.runtime)
        XCTAssertEqual(h.kernel.calls.filter { $0.name == "approveConnection" }.count, 1)
        gate.release()
        await saving.value
        XCTAssertEqual(editor.key, "new-draft-key")
        XCTAssertEqual(editor.model, "new-draft-model")
        XCTAssertFalse(editor.saved)
        XCTAssertEqual(h.runtime.providers.map(\.model), ["submitted"])
    }

    func testProviderNameFollowsTheKernelNameRule() {
        func problem(_ name: String) -> MeshProviderInputError? {
            if case .failure(let error) = MeshProviderInput.validate(
                name: name, baseURL: "https://api.example.com/v1", model: "m", key: "k")
            {
                return error
            }
            return nil
        }
        for valid in ["openai", "my-provider_2", "  Padded  ", "UPPER", "0", String(repeating: "a", count: 64)] {
            XCTAssertNil(problem(valid), valid)
        }
        let tooLong = String(repeating: "a", count: 65)
        for invalid in ["", "   ", "my.provider", "two words", "caf\u{E9}", "\u{130}", "a/b", tooLong] {
            XCTAssertEqual(problem(invalid), .invalidName, invalid)
        }
        XCTAssertEqual(MeshProviderInputError.invalidName.message, "Use 1 to 64 lowercase letters, numbers, - or _.")
        XCTAssertEqual(MeshProviderInput.normalizedName("  Open-AI "), "open-ai")
    }

    func testSavingSendsTheEnteredNameAsBothNameAndProvider() async {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let rejected = await h.runtime.saveModelConnection(
            name: "Bad.Name", baseURL: "https://api.example.com/v1", model: "m", key: "k", recipients: nil)
        XCTAssertEqual(rejected, .invalidName)
        XCTAssertFalse(h.kernel.calls.contains { $0.name == "proposeModelConnection" })
        let accepted = await h.runtime.saveModelConnection(
            name: " My-LLM ", baseURL: "https://api.example.com/v1", model: "m", key: "k", recipients: nil)
        XCTAssertNil(accepted)
        XCTAssertTrue(h.kernel.calls.contains(.init(name: "proposeModelConnection", detail: "my-llm/my-llm")))
        XCTAssertEqual(h.runtime.connections.first?.name, "my-llm")
    }

    func testTheEditorLowercasesTheNameFlagsProblemsAndGatesSave() {
        let editor = MeshProviderEditor()
        XCTAssertNil(editor.nameProblem)
        XCTAssertFalse(editor.canSave)
        editor.providerName = "OpenAI"
        XCTAssertEqual(editor.providerName, "openai")
        XCTAssertTrue(editor.canSave)
        editor.providerName = "open.ai"
        XCTAssertEqual(editor.nameProblem, .invalidName)
        XCTAssertFalse(editor.canSave)
    }

    func testThePlaceholdersAreOpenAIStyleHints() {
        XCTAssertEqual(MeshProviderPlaceholder.name, "openai")
        XCTAssertEqual(MeshProviderPlaceholder.baseURL, "https://api.openai.com/v1")
        XCTAssertEqual(MeshProviderPlaceholder.model, "gpt-4o")
        XCTAssertEqual(MeshProviderPlaceholder.key, "sk-...")
        let editor = MeshProviderEditor()
        XCTAssertEqual([editor.providerName, editor.baseURL, editor.model, editor.key], ["", "", "", ""])
    }
}
