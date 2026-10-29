// Verifies that the Mac guide adapts server-provided topics into persistent navigation.
// Content, selected state and exact actions remain server-owned, including disabled and stale controls.

#if os(macOS)
    import AstralCore
    import XCTest
    @testable import AstralDeep

    @MainActor final class MacGuideSurfaceTests: XCTestCase {
        func testDocumentRetainsArticleAndServerOfferedTopics() throws {
            let source = Self.components(selected: "second")
            let document = try XCTUnwrap(MacGuideDocument(components: source))
            XCTAssertEqual(document.article, Array(source.dropLast(2)))
            XCTAssertEqual(document.navigationTitle, "Sections")
            XCTAssertEqual(document.sections.map(\.id), ["first", "second"])
            XCTAssertEqual(document.sections.map(\.label), ["Quick reference", "Everyday actions"])
            XCTAssertEqual(document.selectedID, "second")
            XCTAssertEqual(document.selectedIndex, 1)
            XCTAssertEqual(
                document.sections[0].payload,
                ["surface": .string("guide"), "params": .object(["section": .string("first")])])
        }

        func testUnknownAmbiguousAndNonGuideStructuresKeepTheOrdinaryRenderer() {
            XCTAssertNil(MacGuideDocument(components: []))
            XCTAssertNil(MacGuideDocument(components: Array(Self.components().dropLast())))
            XCTAssertNil(MacGuideDocument(components: Self.components(selected: "unknown")))
            XCTAssertNil(MacGuideDocument(components: Self.components(surface: "audit")))
            var source = Self.components()
            source[source.count - 1] = AstralComponent(
                json: .object([
                    "type": .string("container"),
                    "children": .array([
                        source.last!.children[0].raw, source.last!.children[0].raw,
                    ]),
                ]))!
            XCTAssertNil(MacGuideDocument(components: source))
        }

        func testTopicNavigationUsesOnlyCurrentEnabledServerActions() throws {
            let model = AppModel(
                tokenStore: InMemoryTokenStore(), defaults: UserDefaults(suiteName: UUID().uuidString)!)
            model.signedIn = true
            model.connected = true
            model.screen = .surface
            model.pendingSurfaceKey = "guide"
            model.pendingSurface = .init(surfaceKey: "guide", title: "User guide", components: Self.components())
            var sent: [JSONValue] = []
            model.outboundTap = { if let frame = try? JSONValue.parse(Data($0.utf8)) { sent.append(frame) } }
            model.openGuideSection("second")
            XCTAssertEqual(model.pendingSurfaceParams["section"], .string("second"))
            XCTAssertTrue(
                sent.contains {
                    $0["action"] == .string("chrome_open") && $0["payload"]?["params"]?["section"] == .string("second")
                })
            sent = []
            model.pendingSurface = .init(
                surfaceKey: "guide", title: "User guide", components: Self.components(disabled: true))
            model.openGuideSection("second")
            model.openGuideSection("not-offered")
            XCTAssertTrue(sent.isEmpty)
            model.pendingSurfaceKey = "audit"
            model.openGuideSection("first")
            XCTAssertTrue(sent.isEmpty)
            model.pendingSurfaceKey = "guide"
            model.pendingSurface = .init(surfaceKey: "guide", title: "User guide", components: Self.components())
            model.pendingSurfaceParams = .object(["section": .string("first")])
            model.goTo(.chat)
            sent = []
            let retained = model.pendingSurfaceParams
            model.openGuideSection("second")
            XCTAssertTrue(sent.isEmpty)
            XCTAssertEqual(model.pendingSurfaceParams, retained)
            XCTAssertEqual(model.screen, .chat)
        }

        static func components(
            selected: String = "first", surface: String = "guide", disabled: Bool = false, longArticle: Bool = false
        ) -> [AstralComponent] {
            var values: [JSONValue] = [
                .object(["type": .string("text"), "content": .string("Guide article"), "variant": .string("h2")])
            ]
            if longArticle {
                values += (0..<70).map { index in
                    .object([
                        "type": .string("text"),
                        "content": .string("Body paragraph \(index). Read the guide without losing navigation."),
                        "variant": .string("body"),
                    ])
                }
            }
            values.append(
                .object([
                    "type": .string("text"), "content": .string("End of guide article"), "variant": .string("body"),
                ]))
            values.append(.object(["type": .string("text"), "content": .string("Sections"), "variant": .string("h3")]))
            values.append(
                .object([
                    "type": .string("container"), "direction": .string("column"),
                    "children": .array(
                        ["first", "second"].enumerated().map { index, id in
                            .object([
                                "type": .string("button"),
                                "label": .string(index == 0 ? "Quick reference" : "Everyday actions"),
                                "variant": .string(selected == id ? "primary" : "secondary"),
                                "action": .string("chrome_open"),
                                "disabled": .bool(index == 1 && disabled),
                                "payload": .object([
                                    "surface": .string(surface), "params": .object(["section": .string(id)]),
                                ]),
                            ])
                        }),
                ]))
            return values.map { AstralComponent(json: $0)! }
        }
    }
#endif
