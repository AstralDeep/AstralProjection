// Verifies that model text cannot render links or images, that surfaces keep only handle-free properties, and that branch trees and presentation text are stable.
// It also checks the app mode store, provider-free helpers and the QR renderer that the mesh screens rely on.

@testable import AstralDeep
import AstralCore
import XCTest

final class MeshChatMappingTests: XCTestCase {
    private func hasLinkOrImage(_ markdown: String) -> Bool {
        InlineMarkdown.attributed(MeshModelText.neutralize(markdown)).runs.contains {
            $0.link != nil || $0.imageURL != nil
        }
    }

    func testNeutralizedTextHasNoLinksImagesOrAutolinks() {
        let attacks = [
            "[click](https://evil.example/steal?d=secret)",
            "<https://evil.example/x>",
            "![pixel](https://evil.example/p.png)",
            "[ref][1]\n\n[1]: https://evil.example",
            "[shortcut]\n\n[shortcut]: https://evil.example",
            "\\[x](https://evil.example)",
            "https://evil.example/a?b=c",
            "HTTPS://EVIL.EXAMPLE",
            "www.evil.example",
            "mail me@evil.example",
            "mailto:me@evil.example",
            "[a](<https://evil.example>)",
            "**[bold](https://evil.example)**",
            "[![nested](https://evil.example/i.png)](https://evil.example)",
            "ftp://evil.example/file",
        ]
        for attack in attacks { XCTAssertFalse(hasLinkOrImage(attack), attack) }
        XCTAssertTrue(
            InlineMarkdown.attributed("[click](https://example.com)").runs.contains { $0.link != nil },
            "control: the raw text does produce a link")
        XCTAssertTrue(
            InlineMarkdown.attributed("see https://example.com now").runs.contains { $0.link != nil },
            "control: a bare address does produce a link")
    }

    func testNeutralizedTextShowsTheOriginalCharacters() {
        let text = "See [docs](https://x.example) and ![alt](https://y.example/i.png) <b>bold</b> www.z.example a@b.example"
        let shown = String(InlineMarkdown.attributed(MeshModelText.neutralize(text)).characters)
        XCTAssertEqual(shown.replacingOccurrences(of: String(MeshModelText.joiner), with: ""), text)
    }

    func testNeutralizeLeavesPlainTextUnchanged() {
        XCTAssertEqual(MeshModelText.neutralize("plain **bold** and `code` 3.5: yes"), "plain **bold** and `code` 3.5: yes")
        XCTAssertEqual(MeshModelText.neutralize(""), "")
    }

    private func surface(_ nodes: [MeshSurfaceNode], root: String = "root") -> MeshSurface {
        MeshSurface(surfaceId: "s1", root: root, nodes: Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) }))
    }

    func testSurfaceMapsToNestedComponentsWithNeutralizedText() {
        let components = MeshSurfaceMapper.components(
            for: surface([
                MeshSurfaceNode(id: "root", type: "container", props: [:], children: ["t"], provenance: "model"),
                MeshSurfaceNode(
                    id: "t", type: "text", props: ["content": .string("[a](https://x.example)")], children: [],
                    provenance: "model"),
            ]))
        XCTAssertEqual(components.count, 1)
        XCTAssertEqual(components[0].type, "container")
        let child = components[0].children.first
        XCTAssertEqual(child?.textContent, MeshModelText.neutralize("[a](https://x.example)"))
        XCTAssertEqual(child?.componentId, "t")
    }

    func testSurfaceDropsHandlesBindingsAndRawUrls() {
        let components = MeshSurfaceMapper.components(
            for: surface([
                MeshSurfaceNode(
                    id: "root", type: "image",
                    props: [
                        "src": .object(["$handle": .string("h1")]), "href": .string("https://evil.example"),
                        "url": .string("https://evil.example"), "alt": .string("chart"),
                        "caption": .object(["$bind": .object(["event": .string("e"), "path": .string("/x")])]),
                        "nested": .object(["src": .string("https://evil.example"), "ok": .string("fine")]),
                    ], children: [], provenance: "tool")
            ]))
        let raw = components[0].raw
        XCTAssertNil(raw["src"])
        XCTAssertNil(raw["href"])
        XCTAssertNil(raw["url"])
        XCTAssertNil(raw["caption"])
        XCTAssertEqual(raw["alt"]?.stringValue, "chart")
        XCTAssertNil(raw["nested"]?.objectValue?["src"])
        XCTAssertEqual(raw["nested"]?.objectValue?["ok"]?.stringValue, "fine")
    }

    func testSurfaceActionBecomesACapabilityThePressHandlerUnderstands() {
        let components = MeshSurfaceMapper.components(
            for: surface([
                MeshSurfaceNode(
                    id: "root", type: "button",
                    props: ["label": .string("Send"), "action": .object(["capability": .string("cap1")])],
                    children: [], provenance: "model")
            ]))
        XCTAssertEqual(components[0].raw["capability"]?.stringValue, "cap1")
        XCTAssertEqual(components[0].raw["action"]?.stringValue, "mesh_act")
        XCTAssertEqual(components[0].componentId, "root")
    }

    func testSurfaceCannotOverrideItsStructureAndStopsAtCyclesAndDepth() {
        let hostile = surface([
            MeshSurfaceNode(
                id: "root", type: "container",
                props: ["type": .string("script"), "children": .string("x"), "component_id": .string("other")],
                children: ["a"], provenance: "model"),
            MeshSurfaceNode(id: "a", type: "text", props: [:], children: ["root"], provenance: "model"),
        ])
        let components = MeshSurfaceMapper.components(for: hostile)
        XCTAssertEqual(components[0].type, "container")
        XCTAssertEqual(components[0].componentId, "root")
        XCTAssertEqual(components[0].children.count, 1)
        XCTAssertTrue(components[0].children[0].children.isEmpty)
        var chain: [MeshSurfaceNode] = []
        for index in 0..<40 {
            chain.append(
                MeshSurfaceNode(
                    id: index == 0 ? "root" : "n\(index)", type: "container", props: [:],
                    children: index == 39 ? [] : ["n\(index + 1)"], provenance: "model"))
        }
        var depth = 0
        var cursor = MeshSurfaceMapper.components(for: surface(chain)).first
        while let node = cursor {
            depth += 1
            cursor = node.children.first
        }
        XCTAssertEqual(depth, 32)
        XCTAssertTrue(MeshSurfaceMapper.components(for: surface([], root: "missing")).isEmpty)
    }

    @MainActor
    func testChatRowsNeutralizeModelTextButNotOwnerText() {
        let view = MeshChatView(
            chatId: "c", title: "t",
            messages: [
                MeshRuntimeHarness.message("a", parent: nil, text: "[mine](x)", at: 1),
                MeshRuntimeHarness.message(
                    "b", parent: "a", author: .assistant, text: "[theirs](https://x.example)", at: 2),
                MeshRuntimeHarness.message("c", parent: "b", author: .tool, text: "![i](u)", at: 3),
            ], branches: [], surfaces: [], labels: [], status: .idle)
        let rows = MeshChatMapper.rows(for: view, head: nil, streaming: "[s](u)")
        XCTAssertEqual(rows.map(\.turn.role), ["user", "assistant", "reasoning", "assistant"])
        XCTAssertEqual(rows[0].turn.text, "[mine](x)")
        XCTAssertEqual(rows[1].turn.text, MeshModelText.neutralize("[theirs](https://x.example)"))
        XCTAssertEqual(rows[2].turn.text, MeshModelText.neutralize("![i](u)"))
        XCTAssertEqual(rows[3].turn.text, MeshModelText.neutralize("[s](u)"))
        XCTAssertNotEqual(rows[1].turn.text, "[theirs](https://x.example)")
        XCTAssertNil(rows[3].message)
    }

    func testBranchTreeDefaultsToLatestLeafAndFindsSiblings() {
        let messages = [
            MeshRuntimeHarness.message("a", parent: nil, at: 1),
            MeshRuntimeHarness.message("b", parent: "a", at: 2),
            MeshRuntimeHarness.message("c", parent: "a", at: 3),
            MeshRuntimeHarness.message("d", parent: "b", at: 4),
        ]
        XCTAssertEqual(MeshChatTree.defaultHead(of: messages), "d")
        XCTAssertEqual(MeshChatTree.path(to: "c", in: messages).map(\.eventId), ["a", "c"])
        XCTAssertEqual(MeshChatTree.siblings(of: messages[1], in: messages).map(\.eventId), ["b", "c"])
        XCTAssertEqual(MeshChatTree.leaf(descendingFrom: "b", in: messages), "d")
        XCTAssertEqual(MeshChatTree.path(to: "zzz", in: messages).count, 0)
        XCTAssertTrue(MeshChatTree.path(to: nil, in: []).isEmpty)
    }

    func testBranchTreeSurvivesACycleInCorruptData() {
        let messages = [
            MeshRuntimeHarness.message("a", parent: "b", at: 1), MeshRuntimeHarness.message("b", parent: "a", at: 2),
        ]
        XCTAssertEqual(MeshChatTree.path(to: "a", in: messages).count, 2)
    }

    func testPresentationWording() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(MeshPresentation.lastSeen(nil, now: now), "Not seen yet")
        XCTAssertEqual(MeshPresentation.lastSeen(now.addingTimeInterval(-5), now: now), "Seen just now")
        XCTAssertTrue(MeshPresentation.lastSeen(now.addingTimeInterval(-600), now: now).hasPrefix("Last seen"))
        XCTAssertEqual(MeshPresentation.syncLine(.synced), "Synced with your other devices.")
        XCTAssertEqual(MeshPresentation.syncLine(.alone), "This is your only device. Nothing to sync.")
        XCTAssertTrue(MeshPresentation.syncLine(.waiting(device: "Sam's iPhone", since: nil)).hasPrefix("Waiting for Sam's iPhone."))
        XCTAssertEqual(MeshPresentation.groupedCode("12345678"), "1234 5678")
        XCTAssertEqual(MeshPresentation.groupedCode("123"), "123")
        for refusal in [MeshAllowance.Refusal.periodExhausted, .effectClassExhausted, .modelSpendExhausted, .soloNeedsConsent, .stale, .stopped, .notAMember] {
            XCTAssertFalse(MeshPresentation.refusal(refusal).isEmpty)
        }
    }

    @MainActor
    func testAppModeStorePersistsTheChoice() {
        let suite = "mesh.mode." + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = UserDefaults(suiteName: suite)!
        let store = AppModeStore(defaults: defaults)
        XCTAssertNil(store.mode)
        XCTAssertFalse(store.usesMesh)
        store.choose(.mesh)
        XCTAssertTrue(AppModeStore(defaults: defaults).usesMesh)
        store.choose(.node)
        XCTAssertEqual(AppModeStore(defaults: defaults).mode, .node)
    }

    func testLocalToolsRefuseUnknownCalls() {
        let tools = DeviceLocalTools()
        XCTAssertTrue(tools.list().isEmpty)
        XCTAssertThrowsError(try tools.call(name: "rm", argumentsJSON: "{}", ticket: Data()))
    }

    func testRuntimeErrorsAreDescribedWithoutLeakingInternals() {
        XCTAssertEqual(MeshRuntime.describe(MeshKernelError.notFound), "That item is no longer on this device.")
        XCTAssertEqual(MeshRuntime.describe(CocoaError(.fileReadUnknown)), "Something went wrong. Try again.")
        XCTAssertEqual(MeshRuntime.describe(EnrollmentSignInError.nonceMismatch), "Sign-in could not be completed.")
    }
}
