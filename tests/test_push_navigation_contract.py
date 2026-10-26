"""Drift guards for the owner-bound mobile push navigation contract: the manifest's
push_navigation vocabulary, the payload bounds both phone clients implement, the enrollment
and tap behaviors in the Android and Apple sources, and the in-app-only disposition for the
non-phone clients."""

import json
import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = json.loads((ROOT / "contracts" / "ui_protocol.json").read_text(encoding="utf-8"))
CONTRACT = MANIFEST["presentation_contracts"]["push_navigation"]

ANDROID = ROOT / "android-client"
APPLE = ROOT / "apple-clients"
ANDROID_CORE_PUSH = ANDROID / "core/src/main/kotlin/com/personalailabs/astraldeep/core/push"
ANDROID_APP_PUSH = ANDROID / "app/src/main/kotlin/com/personalailabs/astraldeep/app/push"
APPLE_CORE_PUSH = APPLE / "AstralCore/Sources/AstralCore/Push"
APPLE_APP = APPLE / "AstralApp/AstralApp"

CLIENTS = ("web", "windows", "android", "ios", "macos", "watch")
PHONE_CLIENTS = ("android", "ios")
DENIAL_CODES = ("401", "400", "403", "404", "410", "429", "503")
LEVELS = ("info", "warning", "error")
SOURCE_IDS = ("chat_id", "job_id", "activity_id", "assignment_id")
IDENTITY_PATTERN = re.compile(r"^[A-Za-z0-9._:-]{8,128}$")
CONTROL_CHARACTERS = re.compile(r"[\x00-\x1f\x7f]")

APPROVAL_MARKERS = (
    "accept_action",
    "authorize_action",
    "dispatch(",
    "dispatchAction",
    "runTool",
    "executeTool",
)


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _android_sources() -> dict[str, str]:
    return {
        "machine": _read(ANDROID_CORE_PUSH / "NotificationPushAdapter.kt"),
        "payload": _read(ANDROID_CORE_PUSH / "PushPayload.kt"),
        "binding": _read(ANDROID_APP_PUSH / "AndroidNotificationAdapter.kt"),
        "rest": _read(ANDROID_APP_PUSH / "PushDestinationRest.kt"),
        "runtime": _read(ANDROID_APP_PUSH / "PushRuntime.kt"),
        "activity": _read(ANDROID / "app/src/main/kotlin/com/personalailabs/astraldeep/app/MainActivity.kt"),
        "manifest": _read(ANDROID / "app/src/main/AndroidManifest.xml"),
    }


def _apple_sources() -> dict[str, str]:
    return {
        "machine": _read(APPLE_CORE_PUSH / "PushMachine.swift"),
        "rest": _read(APPLE / "AstralCore/Sources/AstralCore/API/PushRest.swift"),
        "service": _read(APPLE_APP / "PushNotificationService.swift"),
        "model": _read(APPLE_APP / "AppModel.swift"),
        "entitlements": _read(APPLE / "AstralApp/AstralApp-iOS.entitlements"),
    }


def test_contract_declares_closed_clients_denials_and_levels() -> None:
    assert CONTRACT["version"] == 1
    assert set(CONTRACT["clients"]) == set(CLIENTS)
    assert set(CONTRACT["destination"]["denials"]) == set(DENIAL_CODES)
    assert CONTRACT["payload"]["level"] == "info|warning|error; absent means info"
    assert set(CONTRACT["payload"]["source_ids"]) == set(SOURCE_IDS)
    assert set(CONTRACT["destination"]["revoke"]["triggers"]) == {
        "sign-out",
        "account change",
        "permission revocation",
        "provider token becoming permanently unavailable",
    }
    for phone in PHONE_CLIENTS:
        assert CONTRACT["clients"][phone]
    for in_app_client in ("web", "windows", "macos", "watch"):
        assert "no OS push registration" in CONTRACT["clients"][in_app_client]


def test_contract_forbids_action_approval_and_tool_execution_from_taps() -> None:
    forbidden = CONTRACT["navigation"]["forbidden"]
    for marker in ("approve", "execute tools"):
        assert marker in forbidden
    resolution = CONTRACT["navigation"]["resolution"]
    assert "never navigates from a URL inside the provider message" in resolution


@pytest.mark.parametrize(
    ("data", "expected_reason"),
    [
        ({"notification_id": "short"}, "notification_id"),
        ({"notification_id": "bad id!"}, "notification_id"),
        ({"notification_id": "notif-0001", "title": ""}, "notification_text"),
        ({"notification_id": "notif-0001", "title": "t" * 129}, "title"),
        ({"notification_id": "notif-0001", "body": "b" * 257}, "body"),
        ({"notification_id": "notif-0001", "title": "t", "body": "bad\x07text"}, "body"),
        ({"notification_id": "notif-0001", "title": "t", "level": "verbose"}, "level"),
        (
            {"notification_id": "notif-0001", "title": "t", "chat_id": "c" * 129},
            "chat_id",
        ),
    ],
)
def test_payload_bound_vectors_reject_out_of_contract_messages(data, expected_reason) -> None:
    machine = _android_sources()["machine"]
    payload = _android_sources()["payload"]
    assert 'Regex("^[A-Za-z0-9._:-]{8,128}$")' in payload
    assert "MAX_TITLE_CHARS = 128" in payload
    assert "MAX_BODY_CHARS = 256" in payload
    assert "MAX_CHAT_ID_CHARS = 128" in payload
    for reason in ("REASON_TITLE", "REASON_BODY", "REASON_LEVEL", "REASON_CHAT_ID"):
        assert reason in payload
    assert '".{0}"' not in machine

    apple_machine = _apple_sources()["machine"]
    assert PushNavigationVectors(data).malformed_reason() == expected_reason
    assert 'notificationIdPattern = "^[A-Za-z0-9._:-]{8,128}$"' in apple_machine
    assert "maxTitleChars = 128" in apple_machine
    assert "maxBodyChars = 256" in apple_machine
    assert "maxChatIdChars = 128" in apple_machine
    assert CONTRACT["payload"]["notification_id"] == IDENTITY_PATTERN.pattern


class PushNavigationVectors:
    def __init__(self, data: dict[str, str]) -> None:
        self.data = data

    def malformed_reason(self) -> str | None:
        identity = self.data.get("notification_id")
        if identity is None or not IDENTITY_PATTERN.fullmatch(identity):
            return "notification_id"
        title = self.data.get("title")
        body = self.data.get("body")
        if not (title or "").strip() and not (body or "").strip():
            return "notification_text"
        if title is not None and (len(title) > 128 or CONTROL_CHARACTERS.search(title)):
            return "title"
        if body is not None and (len(body) > 256 or CONTROL_CHARACTERS.search(body)):
            return "body"
        level = self.data.get("level") or "info"
        if level not in LEVELS:
            return "level"
        chat_id = self.data.get("chat_id")
        if chat_id is not None and (len(chat_id) > 128 or CONTROL_CHARACTERS.search(chat_id)):
            return "chat_id"
        return None


def test_android_sources_implement_the_destination_runtime() -> None:
    sources = _android_sources()
    assert 'uses-permission android:name="android.permission.POST_NOTIFICATIONS"' in sources["manifest"]
    assert 'const val PLATFORM = "android"' in sources["machine"]
    assert 'const val DEFAULT = "astral_push"' in sources["machine"]
    assert 'const val ALERTS = "astral_push_alerts"' in sources["machine"]
    assert "/api/push/destinations" in sources["rest"]
    assert "/api/push/ack" in sources["rest"]
    assert "409 -> PushEnrollOutcome.Rejected(false" in sources["rest"]
    assert "429 -> PushEnrollOutcome.Rejected(true" in sources["rest"]
    assert "response.code == 410 -> PushAckOutcome.DestinationRevoked" in sources["rest"]
    assert "response.code == 404 -> PushRevokeOutcome.Revoked" in sources["rest"]
    assert "push_channel_name" in _read(ANDROID / "app/src/main/res/values/strings.xml")
    assert "push_alert_channel_name" in _read(ANDROID / "app/src/main/res/values/strings.xml")


def test_android_taps_authenticate_before_acknowledging_and_never_approve() -> None:
    sources = _android_sources()
    runtime = sources["runtime"]
    assert "push_tap_notification_id" in runtime
    assert "EXTRA_PROVIDER_NOTIFICATION_ID" in runtime
    assert 'if (tokenProvider().isNullOrBlank()) return' in runtime
    assert "machine().seedAccepted(listOf(tapped))" in runtime
    assert "rest.acknowledge(tokenProvider(), identity.deviceId, tapped)" in runtime
    assert "onAccountChanged" in runtime and "onSignedOut" in runtime
    assert "rest.revoke(access, identity.deviceId)" in runtime
    assert "onLifecycle(PushLifecycle.Foreground)" in runtime
    assert "onLifecycle(PushLifecycle.Background)" in runtime
    for marker in APPROVAL_MARKERS:
        assert marker not in runtime
        assert marker not in sources["rest"]
        assert marker not in sources["binding"]


def test_android_activity_wires_lifecycle_cleanup_and_dedup() -> None:
    sources = _android_sources()
    activity = sources["activity"]
    assert "pushRuntime.start()" in activity
    assert "pushRuntime.handleTap(intent)" in activity
    assert "pushRuntime.onSignedOut(access)" in activity
    assert "pushRuntime.onAccountChanged(authToken.value)" in activity
    assert "pushRuntime.onLifecycleActive()" in activity
    assert "pushRuntime.onLifecycleInactive()" in activity
    assert "pushRuntime.onAuthenticated()" in activity
    assert "pushPermissionLauncher.launch(android.Manifest.permission.POST_NOTIFICATIONS)" in activity
    assert "shouldOfferPermissionRequest" in _android_sources()["runtime"]
    assert "PushPermissionState.NotDetermined" in _android_sources()["runtime"]
    assert 's.copy(\n                            banner = "$text — open it from History",' in _read(
        ANDROID / "app/src/main/kotlin/com/personalailabs/astraldeep/app/ui/AppViewModel.kt"
    )


def test_apple_sources_implement_the_destination_runtime() -> None:
    sources = _apple_sources()
    assert 'var platform: String { "ios" }' in sources["machine"]
    assert "/api/push/destinations" in sources["rest"]
    assert "case 410: return .destinationRevoked" in sources["rest"]
    assert "200...299, 404: return .revoked" in sources["rest"]
    assert "case 409: return .rejected(transient: false, code: \"destination_capacity\")" in sources["rest"]
    assert "aps-environment" in sources["entitlements"]
    assert "UNUserNotificationCenterDelegate" in sources["service"]
    assert "registerForRemoteNotifications()" in sources["service"]
    assert "removeAllDeliveredNotifications()" in sources["service"]
    assert "static func flattened" in sources["service"]
    assert 'for key in ["notification_id", "title", "body", "level", "chat_id"]' in sources["service"]


def test_apple_taps_authenticate_through_the_owner_session_and_never_approve() -> None:
    sources = _apple_sources()
    service = sources["service"]
    assert "tokenProvider" in service
    assert "machine.onSystemDelivery" in service
    assert "machine.onForegroundDelivery" in service
    assert "rest.acknowledge" in service
    assert "ownerSessionEnded(access:" in service
    model = sources["model"]
    assert "pushNotifications?.ownerSessionEnded(access: tokens?.accessToken)" in model
    assert "pushNotifications?.ownerSessionEnded(access: nil)" in model
    assert "func presentPushInApp(_ payload: PushPayload)" in model
    assert "text += \" — open it from History\"" in model
    for marker in APPROVAL_MARKERS:
        assert marker not in service
        assert marker not in sources["rest"]


def test_both_clients_share_the_server_selected_level_mapping() -> None:
    android_banner = _read(ANDROID / "app/src/main/kotlin/com/personalailabs/astraldeep/app/ui/AppViewModel.kt")
    apple_model = _apple_sources()["model"]
    level_expression = 'takeIf { it == "error" || it == "warning" } ?: "info"'
    assert level_expression in android_banner
    assert 'payload.level == "error"' in apple_model
    assert 'payload.level == "warning"' in apple_model
    assert "static let levelError = \"error\"" in _apple_sources()["machine"]
    assert 'LEVEL_ERROR = "error"' in _android_sources()["payload"]


def test_non_phone_clients_keep_the_in_app_only_disposition() -> None:
    service_worker = _read(ROOT / "backend/webrender/static/service-worker.js")
    assert "Notification" not in service_worker
    assert "pushManager" not in service_worker
    web_client = _read(ROOT / "backend/webrender/static/client.js")
    assert "case \"notification\":" in web_client
    assert "showToast(" in web_client
    windows = list((ROOT / "windows-client/astral_client").rglob("*.py"))
    assert windows
    for path in windows:
        assert "PushNotification" not in _read(path)
    for client, note in CONTRACT["clients"].items():
        if client in PHONE_CLIENTS:
            continue
        assert "in-app" in note


def test_dedup_contract_matches_both_ledgers() -> None:
    android_machine = _android_sources()["machine"]
    apple_machine = _apple_sources()["machine"]
    assert "DEFAULT_ACCEPTED_CAPACITY = 64" in android_machine
    assert "acceptedCapacity: Int = 64" in apple_machine
    dedup = CONTRACT["presentation"]["deduplication"]
    assert "bounded receipt ledger" in dedup
    assert "dismissal removes the entry" in dedup
    assert "fun onDismissed" in android_machine
    assert "func onDismissed" in apple_machine


def test_foreground_presentation_uses_the_authenticated_frame_slot() -> None:
    foreground = CONTRACT["presentation"]["foreground"]
    assert "single in-app banner slot" in foreground
    android_machine = _android_sources()["machine"]
    apple_machine = _apple_sources()["machine"]
    assert "PushLifecycle.Foreground ->" in android_machine
    assert "ShowInApp(payload)" in android_machine
    assert "lifecycle == .foreground && !systemPresents" in apple_machine
