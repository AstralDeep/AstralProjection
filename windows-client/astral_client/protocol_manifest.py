"""Classifies every server-to-client WS frame as HANDLED or IGNORED for the desktop
client so a new, unclassified frame fails the build rather than silently dropping;
MainWindow._on_message routes HANDLED types.
"""

from __future__ import annotations

HANDLED = "handled"
IGNORED = "ignored"

CLIENT_LOCAL_ACTIONS: frozenset[str] = frozenset({"attach_existing", "computer_host_consent"})

CLASSIFICATION: dict[str, str] = {
    "rote_config": HANDLED,
    "chrome_menu": HANDLED,
    "user_preferences": HANDLED,
    "system_config": IGNORED,
    "agent_list": HANDLED,
    "agent_registered": HANDLED,
    "agent_host_inventory_reconciled": HANDLED,
    "agent_host_registered": HANDLED,
    "agent_host_registration_refused": HANDLED,
    "agent_bundle_deliver": HANDLED,
    "agent_tunnel": HANDLED,
    "agent_stop": HANDLED,
    "agent_offline": HANDLED,
    "computer_request": HANDLED,
    "computer_session": HANDLED,
    "computer_host": HANDLED,
    "auth_required": HANDLED,
    "ui_render": HANDLED,
    "ui_update": IGNORED,
    "ui_upsert": HANDLED,
    "ui_append": IGNORED,
    "ui_stream_data": HANDLED,
    "chrome_render": HANDLED,
    "chrome_surface": HANDLED,
    "chat_status": HANDLED,
    "chat_step": HANDLED,
    "chat_created": HANDLED,
    "chat_loaded": HANDLED,
    "chat_deleted": IGNORED,
    "history_list": HANDLED,
    "user_message_acked": HANDLED,
    "task_started": HANDLED,
    "task_completed": HANDLED,
    "tool_progress": HANDLED,
    "workspace_timeline_mode": HANDLED,
    "conversation_commit_ready": HANDLED,
    "conversation_snapshot": HANDLED,
    "operation_status": HANDLED,
    "agent_lifecycle": HANDLED,
    "composer_state": HANDLED,
    "voice_control_binding": HANDLED,
    "voice_session_state": HANDLED,
    "voice_turn_state": HANDLED,
    "voice_submission_rejected": HANDLED,
    "voice_transcript": HANDLED,
    "voice_announcement_media": HANDLED,
    "voice_local_announcement": HANDLED,
    "voice_local_final_rejected": HANDLED,
    "voice_local_session_ready": HANDLED,
    "voice_local_turn_bound": HANDLED,
    "heartbeat": IGNORED,
    "stream_subscribed": HANDLED,
    "stream_unsubscribed": HANDLED,
    "stream_list": IGNORED,
    "stream_data": HANDLED,
    "stream_error": HANDLED,
    "component_saved": HANDLED,
    "component_save_error": HANDLED,
    "saved_components_list": HANDLED,
    "component_deleted": HANDLED,
    "combine_status": HANDLED,
    "combine_error": HANDLED,
    "components_combined": HANDLED,
    "components_condensed": HANDLED,
    "agent_permissions": IGNORED,
    "agent_permissions_updated": IGNORED,
    "llm_config_ack": IGNORED,
    "llm_usage_report": IGNORED,
    "audit_append": IGNORED,
    "agent_creation_progress": IGNORED,
    "notification": HANDLED,
    "error": HANDLED,
}


def is_handled(frame_type: str) -> bool:
    return CLASSIFICATION.get(frame_type) == HANDLED


def is_classified(frame_type: str) -> bool:
    return frame_type in CLASSIFICATION
