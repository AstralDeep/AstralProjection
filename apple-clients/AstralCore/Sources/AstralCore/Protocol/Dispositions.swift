// The parity matrix as code: an explicit handled, fallback, or ignored disposition for every push-frame and
// component type, per Apple client, checked against the wire manifest by a drift-guard test.

import Foundation

public enum FrameDisposition: Equatable, Sendable {
    case handled
    case ignored(String)
}

public enum ComponentDisposition: Equatable, Sendable {
    case native
    case fallback(String)
}

public struct ClientDispositions: Sendable {
    public let client: String
    public let frames: [String: FrameDisposition]
    public let components: [String: ComponentDisposition]
    public let voiceActions: Set<String>

    public var nativeComponentTypes: [String] {
        components.compactMap { key, value in
            if case .native = value { return key }
            return nil
        }.sorted()
    }

    private static let commonHandled: [String] = [
        "agent_lifecycle",
        "auth_required", "chat_created", "chat_deleted", "chat_loaded", "chat_status",
        "chat_step", "composer_state", "conversation_commit_ready", "conversation_snapshot", "error",
        "operation_status", "stream_error", "ui_append", "ui_render",
        "ui_stream_data", "ui_update", "ui_upsert",
        "user_message_acked",
        "voice_announcement_media", "voice_control_binding", "voice_session_state",
        "voice_local_announcement", "voice_local_final_rejected", "voice_local_session_ready",
        "voice_local_turn_bound", "voice_submission_rejected", "voice_transcript", "voice_turn_state",
    ]

    private static let commonIgnored: [String: String] = [
        "agent_permissions": "acks for web workspace verbs; natives re-discover",
        "agent_permissions_updated": "acks for web workspace verbs; natives re-discover",
        "agent_registered": "agent lifecycle acks have no native surface (matches Android)",
        "agent_host_inventory_reconciled": "host-only inventory result; author-only clients ignore",
        "agent_host_registered": "structured host acknowledgement; Apple targets are author-only until feature 059",
        "agent_host_registration_refused": "host-only registration refusal; author-only clients ignore",
        "agent_bundle_deliver":
            "BYO code delivery — only a hosting desktop receives it; author-only clients ignore (matches Android)",
        "agent_offline": "BYO host-liveness signal — no native host surface; author-only (matches Android)",
        "agent_stop": "BYO host frame — Apple clients never host a user agent (matches Android)",
        "agent_tunnel":
            "BYO agent frames — relayed only by a hosting desktop; author-only clients ignore (matches Android)",
        "audit_append": "admin audit surface is web-only (044); natives fetch audit via REST",
        "computer_host":
            "076 presence of another of the owner's computers — surface refresh pending the Apple follow-up",
        "computer_request":
            "076 host-only verb request — addressed to the desktop; controllers ignore (matches Android)",
        "computer_session": "076 remote-control session change — surface refresh pending the Apple follow-up",
        "chrome_render": "raw-HTML chrome region is web-only; natives use chrome_surface",
        "heartbeat": "keepalive; the transport layer answers (matches Windows/Android)",
        "llm_config_ack": "natives use the LLM chrome-surface round trip (044)",
        "llm_usage_report": "no native usage surface (044)",
        "rote_config": "natives are full-capability; profile info unused (044)",
        "stream_list": "no native stream-browser surface (matches Windows/Android)",
        "stream_unsubscribed": "terminal state arrives via ui_stream_data done flag",
        "system_config": "dashboard data; natives use agent_list (044)",
    ]

    private static func frames(
        extraHandled: [String],
        extraIgnored: [String: String]
    ) -> [String: FrameDisposition] {
        var table: [String: FrameDisposition] = [:]
        for name in commonHandled { table[name] = .handled }
        for (name, reason) in commonIgnored { table[name] = .ignored(reason) }
        for name in extraHandled { table[name] = .handled }
        for (name, reason) in extraIgnored { table[name] = .ignored(reason) }
        return table
    }

    public static let ios = ClientDispositions(
        client: "ios",
        frames: frames(
            extraHandled: [
                "agent_list", "chrome_menu", "chrome_surface",
                "combine_error", "combine_status", "component_deleted",
                "component_save_error", "component_saved",
                "components_combined", "components_condensed", "history_list",
                "notification", "saved_components_list", "stream_data",
                "stream_subscribed", "task_completed", "task_started",
                "rote_config", "tool_progress", "user_preferences", "workspace_timeline_mode",
            ],
            extraIgnored: [
                "agent_creation_progress": "agentic-creation drafting UX is web-only for now (matches Android)"
            ]),
        components: fullComponentSet(fallbacks: [
            "audio": "web-only media, server degrade ladder (044 channel decision)",
            "generative": "web-only media (044 channel decision)",
        ]),
        voiceActions: Set(allVoiceControlActions))

    public static let macos = ClientDispositions(
        client: "macos",
        frames: ios.frames,
        components: fullComponentSet(fallbacks: [
            "audio": "web-only media, server degrade ladder (044 channel decision)",
            "generative": "web-only media (044 channel decision)",
        ]),
        voiceActions: Set(allVoiceControlActions))

    public static let watch = ClientDispositions(
        client: "watch",
        frames: frames(
            extraHandled: ["notification", "chrome_menu", "chrome_surface", "rote_config", "user_preferences"],
            extraIgnored: [
                "agent_creation_progress": "no drafting UX on the wrist",
                "agent_list": "agent management happens on phone/desktop/web",
                "combine_error": "workspace verbs are larger-screen affordances (055 carve-out)",
                "combine_status": "workspace verbs are larger-screen affordances (055 carve-out)",
                "component_deleted": "workspace verbs are larger-screen affordances (055 carve-out)",
                "component_save_error": "workspace verbs are larger-screen affordances (055 carve-out)",
                "component_saved": "workspace verbs are larger-screen affordances (055 carve-out)",
                "components_combined": "workspace verbs are larger-screen affordances (055 carve-out)",
                "components_condensed": "workspace verbs are larger-screen affordances (055 carve-out)",
                "history_list": "recents come from REST (bounded list)",
                "saved_components_list": "workspace verbs are larger-screen affordances (055 carve-out)",
                "stream_data": "no live-stream nodes on the wrist",
                "stream_subscribed": "no live-stream nodes on the wrist",
                "task_completed": "async detachment is a larger-screen affordance",
                "task_started": "async detachment is a larger-screen affordance",
                "tool_progress": "chat_status text is the wrist progress channel",
                "workspace_timeline_mode": "timeline is a larger-screen surface",
            ]),
        components: watchComponentSet(),
        voiceActions: Set(allVoiceControlActions))

    private static func fullComponentSet(fallbacks: [String: String]) -> [String: ComponentDisposition] {
        var table: [String: ComponentDisposition] = [:]
        for name in allComponentTypes { table[name] = .native }
        for (name, reason) in fallbacks { table[name] = .fallback(reason) }
        return table
    }

    private static func watchComponentSet() -> [String: ComponentDisposition] {
        let native: Set<String> = [
            "alert", "badge", "button", "card", "chat_history", "container", "divider", "keyvalue",
            "list", "metric", "progress", "skeleton", "text",
        ]
        var table: [String: ComponentDisposition] = [:]
        for name in allComponentTypes {
            if native.contains(name) {
                table[name] = .native
            } else {
                table[name] = .fallback("outside the watch profile; server degrades or client text-falls-back")
            }
        }
        return table
    }

    public static let allComponentTypes: [String] = [
        "action_group", "donut_chart", "gauge", "pipeline_stepper", "radar_chart", "stat_group",
        "alert", "audio", "badge", "bar_chart", "button", "card",
        "chat_history", "code", "collapsible", "color_picker", "container",
        "divider", "download_card", "file_download", "file_upload",
        "generative", "grid", "hero", "image", "input", "keyvalue",
        "line_chart", "list", "metric", "param_picker", "pie_chart",
        "plotly_chart", "progress", "rating", "skeleton", "table", "tabs",
        "text", "theme_apply", "timeline",
    ]

    public static let allPushTypes: [String] = [
        "agent_bundle_deliver", "agent_creation_progress", "agent_host_inventory_reconciled",
        "agent_host_registered", "agent_host_registration_refused", "agent_lifecycle",
        "agent_list", "agent_offline", "agent_permissions",
        "agent_permissions_updated", "agent_registered", "agent_stop",
        "agent_tunnel", "audit_append",
        "auth_required", "chat_created", "chat_deleted", "chat_loaded",
        "chat_status", "chat_step", "chrome_menu", "chrome_render",
        "chrome_surface", "combine_error", "combine_status",
        "component_deleted", "component_save_error", "component_saved",
        "components_combined", "components_condensed", "composer_state",
        "computer_host", "computer_request", "computer_session", "conversation_commit_ready",
        "conversation_snapshot",
        "error", "heartbeat", "history_list", "llm_config_ack",
        "llm_usage_report", "notification", "operation_status",
        "rote_config", "saved_components_list", "stream_data", "stream_error",
        "stream_list", "stream_subscribed", "stream_unsubscribed",
        "system_config", "task_completed", "task_started", "tool_progress",
        "ui_append", "ui_render", "ui_stream_data", "ui_update", "ui_upsert",
        "user_message_acked", "user_preferences", "voice_announcement_media", "voice_local_announcement",
        "voice_control_binding", "voice_session_state", "voice_submission_rejected",
        "voice_local_final_rejected", "voice_local_session_ready", "voice_local_turn_bound",
        "voice_transcript", "voice_turn_state", "workspace_timeline_mode",
    ]

    public static let allVoiceControlActions: [String] = [
        "voice_microphone_set", "voice_sensitive_recap_request", "voice_session_end",
        "voice_session_start", "voice_session_takeover", "voice_speech_mute_set",
        "voice_speech_stop", "voice_visible_chat_update",
    ]
}
