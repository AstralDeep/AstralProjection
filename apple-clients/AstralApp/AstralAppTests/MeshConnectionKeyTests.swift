// Verifies pasted-key entry: the key is cleared and never logged, sharing defaults to all devices, and only the owner's form can write one.
// It runs the key model and the model-provider editor against the in-memory kernel with fake keys built at run time.

import XCTest

@testable import AstralDeep

@MainActor
final class MeshConnectionKeyTests: XCTestCase {
    private static let keyServer = "https://keyed.example/mcp"
    private static let tool = MeshConnectionTool(name: "search", hash: "sha256:" + String(repeating: "a", count: 64))

    private func fakeKey() -> String { "fake-" + UUID().uuidString + "-" + UUID().uuidString }

    private func harness() async -> MeshRuntimeHarness {
        let h = MeshRuntimeHarness()
        await h.runtime.open()
        h.kernel.connectionBook.registerServer(Self.keyServer, .init(tools: [Self.tool]))
        return h
    }

    private func keyed(_ h: MeshRuntimeHarness) async throws -> MeshConnection {
        let proposal = try await h.runtime.proposeKeyConnection(
            endpoint: Self.keyServer, name: "Keyed", local: false, key: fakeKey(), recipients: nil)
        return try await h.runtime.approveConnection(
            proposal: proposal.proposal, flow: "private", toolNames: ["search"])
    }

    private func writes(_ h: MeshRuntimeHarness) -> [String] {
        let names: Set<String> = [
            "proposeKeyConnection", "proposeA2AConnection", "proposeHttpApiConnection", "proposeModelConnection",
            "setConnectionKey", "approveConnection", "setModelProvider", "removeConnection",
        ]
        return h.kernel.calls.map(\.name).filter { names.contains($0) }
    }

    func testTheKeyIsClearedAfterSaveAndNeverLogged() async throws {
        let h = await harness()
        defer { h.cleanUp() }
        let connection = try await keyed(h)
        let model = MeshConnectionKeyModel(service: h.runtime, target: .existing(connection: connection.id))
        let secret = fakeKey()
        model.key = secret
        XCTAssertFalse(model.description.contains(secret))
        await model.save()
        XCTAssertEqual(model.phase, .saved)
        XCTAssertEqual(model.key, "")
        XCTAssertEqual(h.kernel.calls.filter { $0.name == "setConnectionKey" }.count, 1)
        XCTAssertFalse(h.kernel.calls.contains { $0.detail.contains(secret) })
        XCTAssertFalse(MeshConnectionSecret(name: "key", value: secret).debugDescription.contains(secret))
    }

    func testAFailedSaveClearsTheKeyAndShowsNoSecret() async throws {
        let h = await harness()
        defer { h.cleanUp() }
        let connection = try await keyed(h)
        let model = MeshConnectionKeyModel(service: h.runtime, target: .existing(connection: connection.id))
        let secret = fakeKey()
        model.key = secret
        h.kernel.failure = .storage("The key could not be stored.")
        await model.save()
        XCTAssertEqual(model.phase, .entering)
        XCTAssertEqual(model.key, "")
        XCTAssertEqual(model.problem, "The key could not be stored.")
        XCTAssertFalse(model.problem?.contains(secret) ?? false)
    }

    func testSharingDefaultsToAllDevicesAndCanBeNarrowed() async throws {
        let h = await harness()
        defer { h.cleanUp() }
        let connection = try await keyed(h)
        let model = MeshConnectionKeyModel(service: h.runtime, target: .existing(connection: connection.id))
        XCTAssertNil(model.recipients)
        model.key = fakeKey()
        await model.save()
        await h.runtime.settle()
        XCTAssertEqual(h.runtime.connections.first?.thisDevice.state, "signed_in")
        let narrowed = MeshConnectionKeyModel(service: h.runtime, target: .existing(connection: connection.id))
        narrowed.key = fakeKey()
        narrowed.recipients = ["sha256:" + String(repeating: "c", count: 64)]
        await narrowed.save()
        await h.runtime.settle()
        XCTAssertEqual(h.runtime.connections.first?.thisDevice.state, "not_signed_in")
    }

    func testAnEmptyKeyOrAnEmptySelectionCannotBeSaved() async throws {
        let h = await harness()
        defer { h.cleanUp() }
        let model = MeshConnectionKeyModel(service: h.runtime, target: .existing(connection: "x"))
        XCTAssertFalse(model.canSave)
        model.key = "   "
        XCTAssertFalse(model.canSave)
        model.key = fakeKey()
        XCTAssertTrue(model.canSave)
        model.recipients = []
        XCTAssertFalse(model.canSave)
        await model.save()
        XCTAssertTrue(writes(h).isEmpty)
    }

    func testNothingIsWrittenUntilTheOwnerSaves() async throws {
        let h = await harness()
        defer { h.cleanUp() }
        let model = MeshConnectionKeyModel(service: h.runtime, target: .server)
        model.endpoint = Self.keyServer
        model.key = fakeKey()
        model.recipients = nil
        XCTAssertTrue(writes(h).isEmpty)
        await model.save()
        XCTAssertEqual(writes(h), ["proposeKeyConnection"])
        XCTAssertEqual(model.phase, .proposed)
        XCTAssertEqual(model.proposal?.scheme, "key")
        XCTAssertEqual(model.proposal?.tools.map(\.name), ["search"])
    }

    func testAnHttpApiCarriesItsHeaderAndFormat() async throws {
        let h = await harness()
        defer { h.cleanUp() }
        let model = MeshConnectionKeyModel(service: h.runtime, target: .httpApi)
        model.endpoint = "https://api.example.com/v1"
        model.header = "X-Api-Key"
        model.format = .plain
        model.key = fakeKey()
        await model.save()
        let proposal = try XCTUnwrap(model.proposal)
        XCTAssertEqual(proposal.kind, "http-api")
        XCTAssertEqual(proposal.keyHeader, "X-Api-Key")
        XCTAssertEqual(proposal.keyFormat, "{key}")
        model.clear()
        let refused = MeshConnectionKeyModel(service: h.runtime, target: .httpApi)
        refused.endpoint = "https://api.example.com/v1"
        refused.header = "Bad Header"
        refused.key = fakeKey()
        XCTAssertFalse(refused.canSave)
    }

    func testHeaderNamesFollowTheKernelRule() {
        XCTAssertTrue(MeshConnectionKeyModel.validHeader("Authorization"))
        XCTAssertTrue(MeshConnectionKeyModel.validHeader("X-Api-Key"))
        XCTAssertFalse(MeshConnectionKeyModel.validHeader(""))
        XCTAssertFalse(MeshConnectionKeyModel.validHeader("1abc"))
        XCTAssertFalse(MeshConnectionKeyModel.validHeader("a b"))
        XCTAssertFalse(MeshConnectionKeyModel.validHeader(String(repeating: "a", count: 65)))
    }

    func testExistingProvidersAreListedAndOpeningWritesNothing() async throws {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let saved = await h.runtime.saveProvider(baseURL: "https://old.example.test/v1", model: "old", key: fakeKey())
        XCTAssertNil(saved)
        let before = writes(h)
        await h.runtime.open()
        await h.runtime.refreshProviders()
        XCTAssertEqual(h.runtime.providers.map(\.model), ["old"])
        XCTAssertEqual(writes(h), before)
    }

    func testANewModelEntryIsWrittenAsAModelConnection() async throws {
        let h = MeshRuntimeHarness()
        defer { h.cleanUp() }
        await h.runtime.open()
        let editor = MeshProviderEditor()
        editor.baseURL = "https://models.example.test/v1"
        editor.model = "tiny"
        editor.key = fakeKey()
        await editor.save(in: h.runtime)
        XCTAssertTrue(editor.saved)
        XCTAssertEqual(editor.key, "")
        XCTAssertEqual(writes(h), ["proposeModelConnection", "approveConnection"])
        XCTAssertEqual(h.runtime.providers.map(\.model), ["tiny"])
        XCTAssertEqual(h.runtime.connections.first?.kind, "model")
    }
}
