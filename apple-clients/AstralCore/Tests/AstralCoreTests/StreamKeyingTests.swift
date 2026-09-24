// Tests for the stream component_id keying rule: a workspace-bridged frame keys its canvas node by
// component_id from the first frame instead of a synthetic stream-<id> node, while seq dedupe stays on
// stream_id.

import XCTest

@testable import AstralCore

final class StreamKeyingTests: XCTestCase {

    private func frame(_ json: String) -> InboundFrame {
        InboundFrame.parse(json)!
    }

    private func chunk(
        seq: Int, componentId: String? = nil, terminal: Bool = false,
        components: String = #"[{"type":"text","content":"partial"}]"#
    ) -> InboundFrame {
        let identity = componentId.map { #""component_id":"\#($0)","# } ?? ""
        return frame(
            """
            {"type":"ui_stream_data","stream_id":"s1","session_id":"c1","seq":\(seq),
             \(identity)"components":\(components),"terminal":\(terminal)}
            """)
    }

    func testComponentIdKeysNodeFromFirstFrame() {
        var seq: [String: Int] = [:]
        let ops = streamFrameToOps(
            chunk(seq: 1, componentId: "wc_abc"),
            activeChat: "c1", seqState: &seq)
        XCTAssertEqual(ops.map(\.componentId), ["wc_abc"])
        XCTAssertEqual(ops[0].component?.componentId, "wc_abc")
    }

    func testSubscribedPlaceholderKeyedByIdentity() {
        let ack = subscribeAckOps(
            frame(
                #"{"type":"stream_subscribed","stream_id":"s1","tool_name":"live_chart","component_id":"wc_abc"}"#))
        XCTAssertEqual(ack.map(\.componentId), ["wc_abc"])
        let legacy = subscribeAckOps(
            frame(
                #"{"type":"stream_subscribed","stream_id":"s1","tool_name":"live_chart"}"#))
        XCTAssertEqual(legacy.map(\.componentId), ["stream-s1"])
    }

    func testSubscribedPlaceholderSkippedWhenIdentityAlreadyHeld() {
        let ack = subscribeAckOps(
            frame(
                #"{"type":"stream_subscribed","stream_id":"s1","tool_name":"live_chart","component_id":"wc_abc"}"#),
            existingIds: ["wc_abc"])
        XCTAssertTrue(ack.isEmpty)
    }

    func testSubscribedPlaceholderSkippedForHeldSyntheticNode() {
        let ack = subscribeAckOps(
            frame(
                #"{"type":"stream_subscribed","stream_id":"s1","tool_name":"live_chart"}"#),
            existingIds: ["stream-s1"])
        XCTAssertTrue(ack.isEmpty)
    }

    func testSubscribedPlaceholderStillBuiltWhenIdentityAbsent() {
        let ack = subscribeAckOps(
            frame(
                #"{"type":"stream_subscribed","stream_id":"s1","tool_name":"live_chart","component_id":"wc_abc"}"#),
            existingIds: ["wc_other", "stream-s1"])
        XCTAssertEqual(ack.map(\.componentId), ["wc_abc"])
    }

    func testAbsentFieldKeepsSyntheticNodeExactly() {
        var seq: [String: Int] = [:]
        let ops = streamFrameToOps(chunk(seq: 1), activeChat: "c1", seqState: &seq)
        XCTAssertEqual(ops.map(\.componentId), ["stream-s1"])
        XCTAssertEqual(ops[0].component?.componentId, "stream-s1")
        XCTAssertEqual(seq, ["s1": 1])
    }

    func testEmptyComponentIdFallsBackToSyntheticNode() {
        var seq: [String: Int] = [:]
        let ops = streamFrameToOps(
            chunk(seq: 1, componentId: ""),
            activeChat: "c1", seqState: &seq)
        XCTAssertEqual(ops.map(\.componentId), ["stream-s1"])
    }

    func testSeqDedupeStaysOnStreamId() {
        var seq: [String: Int] = [:]
        XCTAssertFalse(
            streamFrameToOps(
                chunk(seq: 2, componentId: "wc_abc"),
                activeChat: "c1", seqState: &seq
            ).isEmpty)
        XCTAssertEqual(seq, ["s1": 2])
        XCTAssertTrue(
            streamFrameToOps(
                chunk(seq: 1, componentId: "wc_abc"),
                activeChat: "c1", seqState: &seq
            ).isEmpty)
    }

    func testMultiComponentChunkContainerKeyedByIdentity() {
        var seq: [String: Int] = [:]
        let ops = streamFrameToOps(
            chunk(
                seq: 1, componentId: "wc_abc",
                components: #"[{"type":"text","content":"a"},{"type":"metric","value":"1"}]"#),
            activeChat: "c1", seqState: &seq)
        XCTAssertEqual(ops[0].component?.type, "container")
        XCTAssertEqual(ops[0].component?.componentId, "wc_abc")
    }

    func testErrorChunkLandsUnderIdentity() {
        var seq: [String: Int] = [:]
        let ops = streamFrameToOps(
            frame(
                """
                {"type":"ui_stream_data","stream_id":"s1","session_id":"c1","seq":1,
                 "component_id":"wc_abc","components":[],
                 "error":{"message":"agent died","retryable":false},"terminal":true}
                """), activeChat: "c1", seqState: &seq)
        XCTAssertEqual(ops.map(\.componentId), ["wc_abc"])
        XCTAssertEqual(ops[0].component?.type, "alert")
        XCTAssertNil(seq["s1"])
    }

    func testTerminalPersistUpsertReplacesInPlace() {
        var seq: [String: Int] = [:]
        var canvas: [AstralComponent] = []
        canvas = Canvas.apply(
            canvas,
            subscribeAckOps(
                frame(
                    #"{"type":"stream_subscribed","stream_id":"s1","tool_name":"live_chart","component_id":"wc_abc"}"#))
        )
        canvas = Canvas.apply(
            canvas,
            streamFrameToOps(
                chunk(seq: 1, componentId: "wc_abc"), activeChat: "c1", seqState: &seq))
        canvas = Canvas.apply(
            canvas,
            streamFrameToOps(
                chunk(
                    seq: 2, componentId: "wc_abc",
                    components: #"[{"type":"text","content":"last chunk"}]"#),
                activeChat: "c1", seqState: &seq))
        canvas = Canvas.apply(
            canvas,
            streamFrameToOps(
                chunk(seq: 3, componentId: "wc_abc", terminal: true, components: "[]"),
                activeChat: "c1", seqState: &seq))
        canvas = Canvas.apply(
            canvas,
            frame(
                """
                {"type":"ui_upsert","chat_id":"c1","ops":[
                  {"op":"upsert","component_id":"wc_abc",
                   "component":{"type":"card","component_id":"wc_abc","title":"Persisted"}}]}
                """
            ).upsertOps)
        XCTAssertEqual(canvas.map(\.componentId), ["wc_abc"])
        XCTAssertEqual(canvas[0].type, "card")
    }

    func testLegacyStreamWithoutFieldStaysOnSyntheticNode() {
        var seq: [String: Int] = [:]
        var canvas = Canvas.apply(
            [],
            streamFrameToOps(
                chunk(seq: 1, terminal: true), activeChat: "c1", seqState: &seq))
        XCTAssertEqual(canvas.map(\.componentId), ["stream-s1"])
        canvas = Canvas.apply(
            canvas,
            frame(
                """
                {"type":"ui_upsert","chat_id":"c1","ops":[
                  {"op":"upsert","component_id":"wc_abc",
                   "component":{"type":"card","component_id":"wc_abc","title":"Persisted"}}]}
                """
            ).upsertOps)
        XCTAssertEqual(canvas.map(\.componentId), ["stream-s1", "wc_abc"])
    }
}
