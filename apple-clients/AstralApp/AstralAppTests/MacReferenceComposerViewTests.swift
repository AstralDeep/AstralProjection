// Mounts the composer reference section and the instructions indicator in a real surface window and
// reads the accessibility tree: stable identifiers, accessible names, denial copy, and suggestion
// rows rendered from a draft typed over actual granted folders.

#if os(macOS)
    import AppKit
    import AstralCore
    import SwiftUI
    import XCTest
    @testable import AstralDeep

    @MainActor
    final class MacReferenceComposerViewTests: XCTestCase {
        private var suites: [String] = []
        private let project = "00000000-0000-1000-8000-000000000001"

        override func tearDown() {
            for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
            suites.removeAll()
            super.tearDown()
        }

        private struct ComposerHost: View {
            @State var draft: String
            init(draft: String) { _draft = State(initialValue: draft) }
            var body: some View {
                InputBar(input: $draft)
            }
        }

        private func model() throws -> AppModel {
            let suite = "MacReferenceComposerViewTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let model = AppModel(
                conversationResumeStore: ConversationResumeStore(defaults: defaults),
                tokenStore: InMemoryTokenStore(), defaults: defaults)
            model.signedIn = true
            model.connected = true
            model.bindConversationAccount(
                try XCTUnwrap(ConversationAccount(issuer: "https://iam.example.test", subject: "reference-owner")))
            model.chromeMenu = try XCTUnwrap(ChromeMenuModel.fromJSON(SurfaceFixtures.json("chrome-console")))
            suites.append(suite)
            return model
        }

        private func mount(_ root: some View, model: AppModel) -> SurfaceMount {
            SurfaceMount(root, model: model, size: CGSize(width: 720, height: 320))
        }

        func testCompletionWithoutProjectGrantsShowsTheDenialStateWithStableIdentity() async throws {
            let model = try self.model()
            let mount = mount(ComposerHost(draft: "@"), model: model)
            defer { mount.window.close() }
            try await mount.settle()
            let elements = try mount.accessibility
            let unavailable = try XCTUnwrap(
                elements.first { $0.identifier == "composer-reference-unavailable" },
                elements.map(\.identifier).joined(separator: ","))
            XCTAssertTrue(unavailable.label?.contains("project") == true, unavailable.label ?? "")
        }

        func testChipsExposeAccessibleNamesAndStableIdentifiers() async throws {
            let model = try self.model()
            let mount = mount(
                ComposerHost(draft: "check @file:demo/notes.md and @folder:demo"), model: model)
            defer { mount.window.close() }
            try await mount.settle()
            let elements = try mount.accessibility
            let first = try XCTUnwrap(
                elements.first { $0.identifier == "composer-reference-chip-0" },
                elements.map(\.identifier).joined(separator: ","))
            XCTAssertEqual(first.label, "file reference demo/notes.md")
            let second = try XCTUnwrap(elements.first { $0.identifier == "composer-reference-chip-1" })
            XCTAssertEqual(second.label, "folder reference demo")
            XCTAssertNotNil(elements.first { $0.identifier == "composer-reference-chip-remove-0" })
            XCTAssertNotNil(elements.first { $0.identifier == "composer-reference-chip-preview-0" })
        }

        func testTypingAnAtOverGrantedFoldersOffersRowIdentifiersAndNames() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
            try String("x").write(to: root.appendingPathComponent("src/a.swift"), atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: root) }
            let io = MacComputerTestWorkspaceGrants()
            io.selection = [root]
            var bytes: [String: Data] = [:]
            let persistence = MacProjectGrantPersistence(
                read: { bytes[$0] }, write: { key, data in bytes[key] = data })
            let store = MacProjectGrants(grants: io.port, persistence: persistence)
            store.bind(server: URL(string: "https://example.com")!, account: "owner", device: "mac")
            try store.reconcile(projectIds: [project])
            try store.choose(project: project)

            let suite = "MacReferenceComposerViewTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let host = MacComputerHost(projectGrants: store)
            let model = AppModel(
                conversationResumeStore: ConversationResumeStore(defaults: defaults),
                tokenStore: InMemoryTokenStore(), defaults: defaults, computerHost: host)
            model.signedIn = true
            model.connected = true
            model.bindConversationAccount(
                try XCTUnwrap(ConversationAccount(issuer: "https://iam.example.test", subject: "reference-owner")))
            model.chromeMenu = try XCTUnwrap(ChromeMenuModel.fromJSON(SurfaceFixtures.json("chrome-console")))
            model.projects.bind(
                scope: "owner",
                client: RestClient(
                    serverBase: URL(string: "https://example.test")!, tokenProvider: { nil },
                    transport: { _ in (200, Data(#"{"projects":[],"next_cursor":null}"#.utf8)) }))
            model.projects.negotiate(true)
            suites.append(suite)

            let mount = mount(
                ComposerHost(draft: "@\(root.lastPathComponent)/src/a"), model: model)
            defer { mount.window.close() }
            try await mount.settle()
            let elements = try mount.accessibility
            let row = try XCTUnwrap(
                elements.first { $0.identifier == "composer-reference-option-0" },
                elements.map(\.identifier).joined(separator: ","))
            XCTAssertEqual(row.label, "Reference file \(root.lastPathComponent)/src/a.swift")
        }

        func testInstructionsIndicatorCarriesAccessibleStateAndViewerIdentity() async throws {
            let model = try self.model()
            let mount = mount(MacProjectInstructionsIndicator(), model: model)
            defer { mount.window.close() }
            try await mount.settle()
            let elements = try mount.accessibility
            let indicator = try XCTUnwrap(
                elements.first { $0.identifier == "project-instructions-indicator" },
                elements.map(\.identifier).joined(separator: ","))
            XCTAssertEqual(indicator.label, "Project instructions")
            XCTAssertEqual(indicator.value, "None loaded")
        }
    }
#endif
