// Classifies every server-to-client WS frame type from the committed ui_protocol.json manifest as HANDLED or
// IGNORED, so ProtocolManifestTest fails the build when a new frame type isn't deliberately triaged.

package com.personalailabs.astraldeep.core.protocol

object ProtocolManifest {
    const val HANDLED = "handled"
    const val IGNORED = "ignored"

    val classification: Map<String, String> =
        mapOf(
            "rote_config" to IGNORED,
            "chrome_menu" to HANDLED,
            "user_preferences" to HANDLED,
            "system_config" to IGNORED,
            "agent_list" to HANDLED,
            "agent_registered" to IGNORED,
            "agent_host_inventory_reconciled" to IGNORED,
            "agent_host_registered" to IGNORED,
            "agent_host_registration_refused" to IGNORED,
            "auth_required" to HANDLED,
            "ui_render" to HANDLED,
            "ui_update" to IGNORED,
            "ui_upsert" to HANDLED,
            "ui_append" to IGNORED,
            "ui_stream_data" to HANDLED,
            "chrome_render" to IGNORED,
            "chrome_surface" to HANDLED,
            "chat_status" to HANDLED,
            "chat_step" to HANDLED,
            "chat_created" to HANDLED,
            "chat_loaded" to HANDLED,
            "chat_deleted" to IGNORED,
            "history_list" to HANDLED,
            "user_message_acked" to HANDLED,
            "task_started" to HANDLED,
            "task_completed" to HANDLED,
            "tool_progress" to HANDLED,
            "workspace_timeline_mode" to HANDLED,
            "conversation_snapshot" to HANDLED,
            "conversation_commit_ready" to HANDLED,
            "operation_status" to HANDLED,
            "agent_lifecycle" to HANDLED,
            "composer_state" to HANDLED,
            "voice_control_binding" to HANDLED,
            "voice_session_state" to HANDLED,
            "voice_turn_state" to HANDLED,
            "voice_submission_rejected" to HANDLED,
            "voice_transcript" to HANDLED,
            "voice_announcement_media" to HANDLED,
            "voice_local_announcement" to HANDLED,
            "voice_local_final_rejected" to HANDLED,
            "voice_local_session_ready" to HANDLED,
            "voice_local_turn_bound" to HANDLED,
            "heartbeat" to IGNORED,
            "stream_subscribed" to HANDLED,
            "stream_unsubscribed" to HANDLED,
            "stream_list" to IGNORED,
            "stream_data" to HANDLED,
            "stream_error" to HANDLED,
            "component_saved" to HANDLED,
            "component_save_error" to HANDLED,
            "saved_components_list" to HANDLED,
            "component_deleted" to HANDLED,
            "combine_status" to HANDLED,
            "combine_error" to HANDLED,
            "components_combined" to HANDLED,
            "components_condensed" to HANDLED,
            "agent_permissions" to IGNORED,
            "agent_permissions_updated" to IGNORED,
            "llm_config_ack" to IGNORED,
            "llm_usage_report" to IGNORED,
            "audit_append" to IGNORED,
            "agent_creation_progress" to IGNORED,
            "agent_tunnel" to IGNORED,
            "agent_bundle_deliver" to IGNORED,
            "agent_stop" to IGNORED,
            "agent_offline" to IGNORED,
            "computer_request" to IGNORED,
            "computer_session" to HANDLED,
            "computer_host" to HANDLED,
            "notification" to HANDLED,
            "error" to HANDLED,
        )

    fun isHandled(frameType: String): Boolean = classification[frameType] == HANDLED

    fun isClassified(frameType: String): Boolean = frameType in classification
}
