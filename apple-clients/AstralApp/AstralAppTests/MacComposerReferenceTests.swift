// Exercises the composer reference engine against real temporary granted folders: token scanning,
// grant-fenced completion, exclusion denials, unavailable states, insertion, and bounded previews.

#if os(macOS)
    import AstralCore
    import Observation
    import XCTest
    @testable import AstralDeep

    @MainActor final class MacComposerReferenceTests: XCTestCase {
        let project = "00000000-0000-1000-8000-000000000001"
        private var root: URL!
        private var store: MacProjectGrants!

        override func setUp() async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
            try String("print(1)").write(
                to: root.appendingPathComponent("src/main.swift"), atomically: true, encoding: .utf8)
            try String("guide").write(
                to: root.appendingPathComponent("docs/guide.md"), atomically: true, encoding: .utf8)
            try String("secret").write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
            try String("secret").write(to: root.appendingPathComponent("server.key"), atomically: true, encoding: .utf8)
            let grants = MacComputerTestWorkspaceGrants()
            grants.selection = [root]
            var bytes: [String: Data] = [:]
            let persistence = MacProjectGrantPersistence(
                read: { bytes[$0] }, write: { key, data in bytes[key] = data })
            store = MacProjectGrants(grants: grants.port, persistence: persistence)
            store.bind(server: URL(string: "https://example.com")!, account: "owner", device: "mac")
            try store.reconcile(projectIds: [project])
            try store.choose(project: project)
        }

        override func tearDown() async throws {
            store.bind(server: nil, account: nil, device: "mac")
            try? FileManager.default.removeItem(at: root)
        }

        private func engine(available: Bool = true) -> MacComposerReferences {
            MacComposerReferences(grants: store, hostAvailable: { available })
        }

        func testTokenScanRecognizesKindsRangesAndMalformedPaths() {
            let text = "see @file:src/main.swift and @folder:src plus @diff:demo @folder:../escape"
            let tokens = MacReferenceToken.scan(text)
            XCTAssertEqual(tokens.map(\.kind), [.file, .folder, .diff, .folder])
            XCTAssertEqual(tokens.map(\.path), ["src/main.swift", "src", "demo", "../escape"])
            XCTAssertEqual(String(text[tokens[0].range]), "@file:src/main.swift")
            XCTAssertTrue(tokens[3].malformed)
            XCTAssertFalse(tokens[0].malformed)
        }

        func testTokenScanIgnoresAtSignsInsideWordsAndWithoutKind() {
            let tokens = MacReferenceToken.scan("mail me at owner@example.com or @plain")
            XCTAssertTrue(tokens.isEmpty)
        }

        func testTriggerRequiresWordBoundaryAtTheDraftTail() {
            XCTAssertNil(MacComposerReferences.trigger(in: "hello @world "))
            XCTAssertNil(MacComposerReferences.trigger(in: "contact@example"))
            let query = MacComposerReferences.trigger(in: "check @src/ma")
            XCTAssertEqual(query?.text, "src/ma")
            XCTAssertEqual(query?.prefix, "check @")
            XCTAssertEqual(MacComposerReferences.trigger(in: "@")?.text, "")
        }

        func testCompletionNeedsAProjectWithGrantsAndListsOnlyGrantedEntries() throws {
            let references = engine()
            guard case .unavailable(let message) = references.evaluate(query: "", project: nil) else {
                return XCTFail("completion without a project must be unavailable")
            }
            XCTAssertTrue(message.contains("project"), message)
            let rootName = root.lastPathComponent
            guard case .suggestions(let top) = references.evaluate(query: "", project: project) else {
                return XCTFail("expected suggestions once the project grants exist")
            }
            XCTAssertEqual(
                Set(top.map(\.id)),
                ["diff|\(rootName)", "folder|\(rootName)", "folder|\(rootName)/src", "folder|\(rootName)/docs"])
            guard case .suggestions(let filtered) = references.evaluate(
                query: "\(rootName)/src/ma", project: project)
            else { return XCTFail("expected filtered suggestions") }
            XCTAssertEqual(filtered.map(\.tokenPath), ["\(rootName)/src/main.swift"])
            guard case .suggestions(let diff) = references.evaluate(query: "dif", project: project) else {
                return XCTFail("expected the diff suggestion")
            }
            XCTAssertEqual(diff.map(\.kind), [.diff])
            XCTAssertEqual(diff.first?.tokenPath, rootName)
        }

        func testCompletionNeverOffersExcludedPathsEvenWhenTypedInFull() {
            let references = engine()
            guard case .unavailable(let message) = references.evaluate(query: ".env", project: project) else {
                return XCTFail("excluded names must not complete")
            }
            XCTAssertTrue(message.contains("No matching"), message)
            guard case .unavailable(let keyMessage) = references.evaluate(query: "server.key", project: project) else {
                return XCTFail("key files must not complete")
            }
            XCTAssertTrue(keyMessage.contains("No matching"), keyMessage)
            guard case .unavailable(let parentMessage) = references.evaluate(query: "../escape", project: project)
            else { return XCTFail("relative parent paths must not complete") }
            XCTAssertTrue(parentMessage.contains("relative parent"), parentMessage)
        }

        func testCompletionReportsUnavailableStatesForOfflineHostAndRevokedGrants() {
            let offline = engine(available: false)
            guard case .unavailable(let hostMessage) = offline.evaluate(query: "", project: project) else {
                return XCTFail("offline host must be unavailable")
            }
            XCTAssertTrue(hostMessage.contains("not running computer tools"), hostMessage)
            try? store.clear(project: project)
            let references = engine()
            guard case .unavailable(let grantMessage) = references.evaluate(query: "", project: project) else {
                return XCTFail("revoked grants must be unavailable")
            }
            XCTAssertTrue(grantMessage.contains("Choose folders"), grantMessage)
        }

        func testInsertReplacesTheTriggerWithTokenAndTrailingSpace() throws {
            let references = engine()
            let draft = "look at @\(root.lastPathComponent)/src"
            references.refresh(draft: draft, project: project)
            guard case .suggestions(let candidates) = references.completion else {
                return XCTFail("expected suggestions")
            }
            let target = try XCTUnwrap(candidates.first { $0.tokenPath == "\(root.lastPathComponent)/src" })
            XCTAssertEqual(
                references.insert(target), "look at @folder:\(root.lastPathComponent)/src ")
            references.dismiss()
            XCTAssertNil(references.query)
        }

        func testPreviewReadsBoundedFileContentAndListsFoldersThroughTheGrantBoundary() async {
            let references = engine()
            let rootName = root.lastPathComponent
            let fileToken = MacReferenceToken(
                kind: .file, path: "\(rootName)/src/main.swift", range: "".startIndex..<"".endIndex)
            guard case .success(.file(let text, let truncated, let bytes)) = await references.preview(
                fileToken, project: project)
            else { return XCTFail("expected a file preview") }
            XCTAssertEqual(text, "print(1)")
            XCTAssertFalse(truncated)
            XCTAssertEqual(bytes, 8)
            let folderToken = MacReferenceToken(
                kind: .folder, path: rootName, range: "".startIndex..<"".endIndex)
            guard case .success(.folder(let names, _)) = await references.preview(folderToken, project: project)
            else { return XCTFail("expected a folder preview") }
            XCTAssertTrue(names.contains("src"))
            XCTAssertTrue(names.contains("docs"))
            XCTAssertFalse(names.contains(".env"))
            XCTAssertFalse(names.contains("server.key"))
            let diffToken = MacReferenceToken(
                kind: .diff, path: rootName, range: "".startIndex..<"".endIndex)
            guard case .success(.diff(let diffRoot)) = await references.preview(diffToken, project: project) else {
                return XCTFail("expected a diff description")
            }
            XCTAssertEqual(diffRoot, rootName)
        }

        func testPreviewDeniesExcludedFilesAndUnknownRoots() async {
            let references = engine()
            let rootName = root.lastPathComponent
            let excluded = MacReferenceToken(
                kind: .file, path: "\(rootName)/server.key", range: "".startIndex..<"".endIndex)
            guard case .failure(let denial) = await references.preview(excluded, project: project) else {
                return XCTFail("excluded files must not preview")
            }
            XCTAssertTrue(denial.contains("excluded"), denial)
            let unknown = MacReferenceToken(
                kind: .file, path: "elsewhere/notes.md", range: "".startIndex..<"".endIndex)
            guard case .failure = await references.preview(unknown, project: project) else {
                return XCTFail("unknown roots must not resolve")
            }
        }
    }
#endif
