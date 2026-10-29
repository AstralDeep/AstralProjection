"""Validates the published notification vocabulary and packaged provider configuration; native lifecycle behavior is exercised by the owning Kotlin and Swift suites."""

import json
import plistlib
import tomllib
from pathlib import Path
from xml.etree import ElementTree

from astralprojection.chrome.notifications import ROUTING_FIELDS

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = json.loads((ROOT / "contracts/ui_protocol.json").read_text())
CONTRACT = MANIFEST["presentation_contracts"]["push_navigation"]
CLIENTS = {"web", "windows", "android", "ios", "macos", "watch"}


def test_push_admission_and_routing_contracts_share_the_approved_vocabulary():
    assert CONTRACT["version"] == 2
    assert set(CONTRACT["clients"]) == CLIENTS
    routing = MANIFEST["presentation_contracts"]["notifications_routing"]
    assert set(routing["clients"]) == CLIENTS
    assert routing["builder"] == "astralprojection.chrome.notifications.build_notifications_view(state,error=None)"
    assert routing["routing_fields"] == list(ROUTING_FIELDS)
    assert set(routing["actions"]) <= set(MANIFEST["accept_actions"])
    assert routing["actions"]["chrome_notification_open"] == ["entry_id"]
    assert routing["actions"]["chrome_notification_preferences"] == ["expected_revision", *ROUTING_FIELDS]
    assert routing["actions"]["chrome_notification_quiet_hours"] == [
        "expected_revision", "enabled", "start_minute", "end_minute", "tz_offset_minutes",
    ]
    for action in ("chrome_notification_acknowledge", "chrome_notification_delete"):
        assert routing["actions"][action] == ["entry_id", "expected_revision"]


def test_contract_documents_generation_fences_and_actual_provider_limits():
    destination = CONTRACT["destination"]
    assert destination["ack"]["fields"] == {
        "device_id": "the enrolled device_id", "notification_id": "the delivered notification identity",
    }
    assert "expected_token_generation" in destination["revoke"]["precondition"]
    assert "expected_destination_revision" in destination["revoke"]["precondition"]
    assert "expected_destination_revision" in destination["enroll"]["fields"]
    assert "distinct from local" in destination["enroll"]["response"]
    assert destination["presence"]["fields"] == ["device_id", "connection_generation", "sequence", "foreground"]
    assert "push.delivery.queued" in CONTRACT["presentation"]["background"]
    assert "cannot be retracted" in CONTRACT["presentation"]["background"]
    assert "no provider notification block" in CONTRACT["payload"]["note"]
    assert "execute tools" in CONTRACT["navigation"]["forbidden"]
    assert "never navigates from a URL" in CONTRACT["navigation"]["resolution"]
    for client in ("web", "windows", "macos", "watch"):
        assert "no OS push registration" in CONTRACT["clients"][client]


def test_android_packages_one_private_real_provider_service_without_auto_init():
    manifest = ElementTree.parse(ROOT / "android-client/app/src/main/AndroidManifest.xml").getroot()
    name = "{http://schemas.android.com/apk/res/android}name"
    value = "{http://schemas.android.com/apk/res/android}value"
    exported = "{http://schemas.android.com/apk/res/android}exported"
    assert any(x.get(name) == "android.permission.POST_NOTIFICATIONS" for x in manifest.findall("uses-permission"))
    app = manifest.find("application")
    services = [x for x in app.findall("service") if x.get(name) == ".push.AstralFirebaseMessagingService"]
    assert len(services) == 1 and services[0].get(exported) == "false"
    assert services[0].find("intent-filter/action").get(name) == "com.google.firebase.MESSAGING_EVENT"
    metadata = {x.get(name): x.get(value) for x in app.findall("meta-data")}
    assert metadata["firebase_messaging_auto_init_enabled"] == "false"
    assert metadata["firebase_analytics_collection_enabled"] == "false"
    catalog = tomllib.loads((ROOT / "android-client/gradle/libs.versions.toml").read_text())
    assert catalog["libraries"]["firebase-messaging"]["module"] == "com.google.firebase:firebase-messaging"
    version = catalog["versions"]["firebaseMessaging"]
    lock = (ROOT / "android-client/app/gradle.lockfile").read_text()
    assert f"com.google.firebase:firebase-messaging:{version}=" in lock


def test_apple_uses_build_configuration_bound_apns_environment():
    entitlements = plistlib.loads((ROOT / "apple-clients/AstralApp/AstralApp-iOS.entitlements").read_bytes())
    assert entitlements["aps-environment"] == "$(ASTRAL_APS_ENVIRONMENT)"
    project = (ROOT / "apple-clients/AstralApp/AstralApp.xcodeproj/project.pbxproj").read_text()
    assert "ASTRAL_APS_ENVIRONMENT = development;" in project
    assert "ASTRAL_APS_ENVIRONMENT = production;" in project
