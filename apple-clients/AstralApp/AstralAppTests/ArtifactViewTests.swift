// Tests for ArtifactView.swift: artifact shape decoding, section and depth bounds, adaptive grid columns, ref
// resolution against the canvas, newest-artifact canvas focus, the browser-pane arrival switch, the rendered
// page's grid collapse and its stable accessibility identifiers.

import AstralCore
import SwiftUI
import XCTest

@testable import AstralDeep

@MainActor
final class ArtifactViewTests: XCTestCase {
    private func component(_ json: String) throws -> AstralComponent {
        try XCTUnwrap(AstralComponent(json: JSONValue.parse(Data(json.utf8))))
    }

    private func nested(depth: Int) -> String {
        depth == 0
            ? #"{"type":"text","content":"leaf"}"#
            : #"{"type":"container","children":["# + nested(depth: depth - 1) + "]}"
    }

    func testDecodesTheServerShapeAndIgnoresUnknownValues() throws {
        let artifact = try component(
            #"""
            {"type":"artifact","id":"art_loop","component_id":"art_loop","title":"  Loop Design ","kind":"Report",
             "subtitle":"Self improving","summary":"What the loop learns","version":3,
             "sections":[{"id":"s1","heading":"Signals","layout":"grid-2","children":[{"type":"metric","title":"PRs","value":"80"},{"type":"metric","title":"Merged","value":"61"}]},
                         {"heading":"Plan","layout":"masonry","children":[{"type":"text","content":"Next"}]}, 7],
             "actions":[{"label":"Copy page","action":"copy"},{"action":"export"},{"label":"Twice","action":"copy"},{"label":"Run","action":"execute"}]}
            """#)
        let document = ArtifactDocument(component: artifact)
        XCTAssertEqual(document.id, "art_loop")
        XCTAssertEqual(document.title, "Loop Design")
        XCTAssertEqual(document.kind, "report")
        XCTAssertEqual(document.subtitle, "Self improving")
        XCTAssertEqual(document.summary, "What the loop learns")
        XCTAssertEqual(document.version, 3)
        XCTAssertEqual(document.sections.map(\.id), ["s1", "s2"])
        XCTAssertEqual(document.sections.map(\.heading), ["Signals", "Plan"])
        XCTAssertEqual(document.sections.map(\.layout), [.grid2, .stack])
        XCTAssertEqual(document.sections[0].children.map(\.component.type), ["metric", "metric"])
        XCTAssertEqual(
            document.actions,
            [.init(label: "Copy page", action: .copy), .init(label: "Export", action: .export)])
        XCTAssertTrue(document.plainText.hasPrefix("Loop Design\nSelf improving\nWhat the loop learns\n\nSignals"))
        XCTAssertTrue(document.plainText.contains("PRs — 80"))

        let other = ArtifactDocument(
            component: try component(#"{"type":"artifact","title":"X","kind":"poster","version":0}"#))
        XCTAssertNil(other.kind)
        XCTAssertNil(other.version)
        XCTAssertTrue(other.sections.isEmpty)
        XCTAssertEqual(ArtifactView.filename(" Loop: Design / v2 "), "loop-design-v2.html")
        XCTAssertEqual(ArtifactView.filename("…"), "astraldeep-artifact.html")
    }

    func testTwelveSectionsAtDepthThreeRenderAsGivenAndExcessIsClamped() throws {
        let child = nested(depth: 2)
        let sections = (1...12).map { #"{"id":"s\#($0)","heading":"H\#($0)","children":["# + child + "]}" }
        let artifact = try component(
            #"{"type":"artifact","id":"a","title":"T","sections":["# + sections.joined(separator: ",") + "]}")
        let document = ArtifactDocument(component: artifact)
        XCTAssertEqual(document.sections.count, 12)
        let given = try JSONValue.parse(Data(child.utf8))
        for section in document.sections {
            XCTAssertEqual(section.children.count, 1)
            XCTAssertEqual(section.children[0].component.raw, given, section.id)
        }

        let thirteen = try component(
            #"{"type":"artifact","sections":["#
                + (1...13).map { #"{"id":"s\#($0)","children":[]}"# }.joined(separator: ",") + "]}")
        XCTAssertEqual(ArtifactDocument(component: thirteen).sections.map(\.id).last, "s12")

        let deep = ArtifactDocument(
            component: try component(#"{"type":"artifact","sections":[{"children":["# + nested(depth: 4) + "]}]}"))
        var node = try XCTUnwrap(deep.sections.first?.children.first?.component)
        var depth = 1
        while let next = node.children.first {
            node = next
            depth += 1
        }
        XCTAssertEqual(depth, ArtifactDocument.maximumDepth)
        XCTAssertEqual(node.raw["children"], .array([]))

        let crowded = (1...70).map { #"{"type":"text","content":"\#($0)"}"# }.joined(separator: ",")
        let budgeted = ArtifactDocument(
            component: try component(
                #"{"type":"artifact","sections":[{"children":["# + crowded + #"]},{"children":[{"type":"text"}]}]}"#))
        XCTAssertEqual(budgeted.sections[0].children.count, ArtifactDocument.maximumDescendants)
        XCTAssertTrue(budgeted.sections[1].children.isEmpty)

        let long = String(repeating: "é", count: 130)
        XCTAssertEqual(
            ArtifactDocument(component: try component(#"{"type":"artifact","title":"\#(long)"}"#)).title
                .unicodeScalars.count, 120)
    }

    func testGridLayoutsCollapseToOneColumnUnderTheBreakpoint() {
        XCTAssertEqual(ArtifactDocument.Layout.grid3.columns(width: 900), 3)
        XCTAssertEqual(ArtifactDocument.Layout.grid2.columns(width: 900), 2)
        XCTAssertEqual(ArtifactDocument.Layout.stack.columns(width: 900), 1)
        XCTAssertEqual(ArtifactDocument.Layout.grid3.columns(width: 560), 3)
        XCTAssertEqual(ArtifactDocument.Layout.grid3.columns(width: 559), 1)
        XCTAssertEqual(ArtifactDocument.Layout.grid2.columns(width: 0), 1)
        XCTAssertEqual(ArtifactDocument.Layout.grid2.columns(width: .infinity), 1)
    }

    func testRefChildrenResolveAgainstTheCanvasOnceAndUnresolvedOrNestedArtifactsDrop() throws {
        let table = try component(#"{"type":"table","component_id":"wc_t1","headers":["a"],"rows":[["1"]]}"#)
        let artifact = try component(
            #"""
            {"type":"artifact","component_id":"art","sections":[{"id":"s1","children":[
              {"type":"ref","component_id":"wc_t1"},{"type":"ref","component_id":"missing"},
              {"type":"ref","component_id":"wc_t1"},{"type":"html_artifact","html":"<p>x</p>"},
              {"type":"card","content":[{"type":"ref","component_id":"wc_t1"}]}]}]}
            """#)
        let canvas = [table, artifact]
        let document = ArtifactDocument(component: artifact, references: ArtifactDocument.references(in: canvas))
        let children = try XCTUnwrap(document.sections.first?.children)
        XCTAssertEqual(children.map(\.component.type), ["table", "card"])
        XCTAssertEqual(children.map(\.index), [0, 4])
        XCTAssertEqual(children[0].component, table)
        XCTAssertTrue(children[1].component.children.isEmpty)
        XCTAssertEqual(document.referencedIds, ["wc_t1"])
        XCTAssertEqual(CanvasArtifactFocus.hidden(in: canvas, focus: 1), ["wc_t1"])
        XCTAssertTrue(ArtifactDocument.references(in: [table, table]).isEmpty)
    }

    func testTheNewestArtifactOwnsTheCanvasFocus() throws {
        let text = try component(#"{"type":"text","content":"hi"}"#)
        let first = try component(#"{"type":"artifact","component_id":"a1","version":1}"#)
        let page = try component(#"{"type":"html_artifact","component_id":"h1","version":2,"html":"<p>x</p>"}"#)
        XCTAssertNil(CanvasArtifactFocus.index(in: [text]))
        XCTAssertNil(CanvasArtifactFocus.identity(of: [text]))
        XCTAssertEqual(CanvasArtifactFocus.index(in: [first, text, page, text]), 2)
        XCTAssertEqual(CanvasArtifactFocus.identity(of: [first, page]), "html_artifact:h1:2")
        XCTAssertEqual(CanvasArtifactFocus.identity(of: [first]), "artifact:a1:1")
    }

    func testArrivalWhileTheBrowserPaneIsShownChipsThenSwitchesWhenTheRunEnds() {
        var arrival = ArtifactArrival()
        XCTAssertFalse(arrival.canvasChanged("artifact:a:1", browserPresented: false, running: true))
        XCTAssertFalse(arrival.unseen)
        XCTAssertFalse(arrival.canvasChanged("artifact:a:2", browserPresented: true, running: true))
        XCTAssertTrue(arrival.unseen)
        XCTAssertFalse(arrival.runChanged(running: true))
        XCTAssertTrue(arrival.runChanged(running: false))
        XCTAssertFalse(arrival.unseen)
        XCTAssertFalse(arrival.runChanged(running: false))

        XCTAssertFalse(arrival.canvasChanged("artifact:a:2", browserPresented: true, running: true))
        XCTAssertFalse(arrival.unseen)
        XCTAssertFalse(arrival.canvasChanged("artifact:a:3", browserPresented: true, running: true))
        arrival.browserChanged(presented: false)
        XCTAssertFalse(arrival.unseen)
        XCTAssertFalse(arrival.runChanged(running: false))

        XCTAssertTrue(arrival.canvasChanged("html_artifact:h:1", browserPresented: true, running: false))
        XCTAssertFalse(arrival.unseen)
        XCTAssertFalse(arrival.canvasChanged(nil, browserPresented: true, running: true))
    }

    #if os(macOS)
        private func mount(_ json: String, width: CGFloat) throws -> (NSWindow, NSHostingView<AnyView>) {
            let model = AppModel(tokenStore: InMemoryTokenStore())
            let theme = ThemeStore()
            let view = NSHostingView(
                rootView: AnyView(
                    ArtifactView(component: try component(json))
                        .environment(model).environment(theme)
                        .frame(width: width).fixedSize(horizontal: false, vertical: true)))
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: width, height: 1400), styleMask: .borderless,
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            return (window, view)
        }

        private func settledHeight(_ view: NSView) async throws -> CGFloat {
            var height: CGFloat = -1
            for _ in 0..<20 {
                view.layoutSubtreeIfNeeded()
                let next = view.fittingSize.height
                if next == height { return next }
                height = next
                try await Task.sleep(for: .milliseconds(50))
            }
            return height
        }

        func testRenderedGridCollapsesInANarrowSlotAndIdentifiersStayStable() async throws {
            let metrics = (1...3).map { #"{"type":"metric","title":"M\#($0)","value":"\#($0)"}"# }
                .joined(separator: ",")
            let json =
                #"{"type":"artifact","id":"art_x","title":"Loop Design","kind":"analysis","version":2,"sections":[{"id":"sig","heading":"Signals","layout":"grid-3","children":["#
                + metrics + #"]},{"id":"plan","heading":"Plan","children":[{"type":"text","content":"Next"}]}]}"#
            let (wide, wideView) = try mount(json, width: 900)
            let (narrow, narrowView) = try mount(json, width: 420)
            defer {
                for window in [wide, narrow] {
                    window.contentView = nil
                    window.close()
                }
            }
            let wideHeight = try await settledHeight(wideView)
            let narrowHeight = try await settledHeight(narrowView)
            XCTAssertGreaterThan(narrowHeight, wideHeight + 100)
            XCTAssertEqual(ArtifactAccessibility.title("art_x"), "artifact.art_x.title")
            XCTAssertEqual(ArtifactAccessibility.section("art_x", "sig"), "artifact.art_x.section.sig")
            XCTAssertEqual(ArtifactAccessibility.control("art_x", "copy"), "artifact.art_x.copy")
            XCTAssertEqual(ArtifactAccessibility.root("art_x"), "artifact.art_x")
        }
    #endif
}
