"""Exercises native capability snapshots, bundled typography and current-connection console actions.
These checks keep Windows negotiation and composer transport aligned with the shared protocol.
"""

import asyncio
import json
import shutil
import uuid
from pathlib import Path
from types import SimpleNamespace

import pytest
from PySide6.QtCore import QRect
from PySide6.QtGui import QInputDevice
from PySide6.QtWidgets import QWidget

from astral_client import protocol, theme
from astral_client.protocol import OrchestratorClient, WindowsProtocolError, device_caps
from astral_client.protocol_manifest import is_handled


CONNECTION = "c91d27b9-cd27-4a73-bdf6-a1e428b38fbd"


def input_devices(monkeypatch, *kinds):
    devices = [QInputDevice(f"Input {index}", index + 1, kind) for index, kind in enumerate(kinds)]
    monkeypatch.setattr(QInputDevice, "devices", lambda: devices)
    return devices


def window_snapshot(ratio=1.0, width=390, height=844):
    screen = SimpleNamespace(geometry=lambda: QRect(0, 0, 1920, 1080), devicePixelRatio=lambda: ratio)
    return SimpleNamespace(width=lambda: width, height=lambda: height, screen=lambda: screen)


@pytest.mark.parametrize("ratio", [1.0, 1.25, 1.5, 2.0])
def test_logical_viewport_is_not_multiplied_by_display_scale(qapp, monkeypatch, ratio):
    input_devices(monkeypatch, QInputDevice.DeviceType.Mouse)
    caps = device_caps(window=window_snapshot(ratio), supported_types=["button", "text"], console=True)
    assert (caps["viewport_width"], caps["viewport_height"]) == (390, 844)
    assert (caps["screen_width"], caps["screen_height"]) == (1920, 1080)
    assert caps["pixel_ratio"] == ratio
    assert caps["console_contract"] == "console/v2"
    assert caps["pointer_type"] == "fine" and caps["has_touch"] is False
    assert caps["connection_type"] == "unknown"


def test_real_qt_window_reports_actual_current_size_and_screen(qapp, monkeypatch):
    input_devices(monkeypatch)
    window = QWidget()
    window.resize(320, 740)
    caps = device_caps(window=window)
    assert (caps["viewport_width"], caps["viewport_height"]) == (320, 740)
    assert caps["screen_width"] == window.screen().geometry().width()
    assert caps["pixel_ratio"] == window.screen().devicePixelRatio()
    window.resize(834, 1194)
    assert device_caps(window=window)["viewport_width"] == 834
    assert "console_contract" not in caps
    window.close()


@pytest.mark.parametrize("fine", ["Mouse", "TouchPad", "Stylus", "Airbrush", "Puck"])
def test_multiple_input_devices_are_aggregated_not_selected(qapp, monkeypatch, fine):
    kinds = QInputDevice.DeviceType
    input_devices(monkeypatch, kinds.TouchScreen, kinds.Keyboard, getattr(kinds, fine))
    caps = device_caps()
    assert caps["has_touch"] and caps["has_keyboard"]
    assert caps["pointer_type"] == "fine"


def test_touch_keyboard_and_no_pointer_have_distinct_snapshots(qapp, monkeypatch):
    kinds = QInputDevice.DeviceType
    input_devices(monkeypatch, kinds.TouchScreen)
    caps = device_caps()
    assert caps["has_touch"] and not caps["has_keyboard"] and caps["pointer_type"] == "coarse"
    input_devices(monkeypatch, kinds.Keyboard)
    caps = device_caps()
    assert caps["has_keyboard"] and not caps["has_touch"] and caps["pointer_type"] == "none"
    input_devices(monkeypatch)
    caps = device_caps()
    assert not caps["has_keyboard"] and not caps["has_touch"] and caps["pointer_type"] == "none"


def test_unavailable_input_query_and_disconnected_device_fail_closed(qapp, monkeypatch):
    def unavailable():
        raise RuntimeError("Input device was disconnected")

    monkeypatch.setattr(QInputDevice, "devices", unavailable)
    assert device_caps()["pointer_type"] == "none"
    mouse = QInputDevice("Mouse", 1, QInputDevice.DeviceType.Mouse)
    monkeypatch.setattr(QInputDevice, "devices", lambda: [SimpleNamespace(type=unavailable), mouse])
    assert device_caps()["pointer_type"] == "fine"
    window = window_snapshot()
    window.screen = lambda: SimpleNamespace(geometry=unavailable)
    caps = device_caps(window=window)
    assert caps["screen_width"] == 390 and caps["pixel_ratio"] == 1


@pytest.mark.parametrize("ratio", [float("nan"), float("inf"), -1, 0, 17, True, "2"])
def test_invalid_screen_scale_does_not_reach_registration(qapp, ratio):
    caps = device_caps(window=window_snapshot(ratio))
    assert caps["pixel_ratio"] == 1
    assert json.loads(json.dumps(caps, allow_nan=False))["pixel_ratio"] == 1


def test_unavailable_screen_and_invalid_dimensions_use_bounded_fallback(qapp):
    window = window_snapshot(width=0, height=20000)
    window.screen = lambda: None
    caps = device_caps(window=window)
    assert caps["screen_width"] == caps["viewport_width"] == 1280
    assert caps["screen_height"] == caps["viewport_height"] == 860
    window = window_snapshot()
    window.screen = lambda: SimpleNamespace(geometry=lambda: QRect(), devicePixelRatio=lambda: 1)
    assert device_caps(window=window)["screen_width"] == 390


def test_no_qt_application_does_not_claim_hardware(monkeypatch):
    monkeypatch.setattr(protocol, "QGuiApplication", SimpleNamespace(instance=lambda: None))
    caps = device_caps(768, 1024)
    assert caps["screen_width"] == 768 and caps["screen_height"] == 1024
    assert caps["pointer_type"] == "none" and caps["has_keyboard"] is False


def test_native_type_negotiation_and_audio_snapshot_are_bounded_and_copied(qapp):
    voice = {"has_microphone": True, "has_audio_output": False, "transport": "livekit"}
    caps = device_caps(1024, 768, ["text", "button", "text", "action_group", "Text", None, "x" * 65], voice)
    assert caps["supported_types"] == ["action_group", "button", "text"]
    assert caps["voice"] == voice
    voice["has_microphone"] = False
    assert caps["voice"]["has_microphone"] is True
    assert "supported_types" not in device_caps(supported_types=["text"] * 257)
    assert "supported_types" not in device_caps(supported_types="text")
    assert "voice" not in device_caps(voice_capability="voice")


def test_console_registration_is_explicit_and_accepts_rote(qapp):
    client = OrchestratorClient("ws://127.0.0.1:9/ws", "synthetic", device_caps(console=True))
    caps = client._register_frame()["capabilities"]
    assert {"guidance_notes_v1", "guidance_selection_v1"} <= set(caps)
    assert "guidance_notes_v1" not in OrchestratorClient("ws://127.0.0.1:9/ws", "synthetic")._register_frame()["capabilities"]
    assert is_handled("rote_config")


@pytest.fixture
def font_app(qapp):
    previous = qapp.font()
    qapp.setProperty("astralOpenSansLoaded", False)
    yield qapp
    qapp.setFont(previous)
    qapp.setProperty("astralOpenSansLoaded", False)


def test_source_font_sets_real_open_sans_family_and_avoids_duplicate_load(font_app, monkeypatch):
    assert theme.configure_fonts(font_app)
    assert font_app.font().family() == "Open Sans"
    assert font_app.font().pixelSize() == 14
    monkeypatch.setattr(theme.QFontDatabase, "addApplicationFont", lambda _: pytest.fail("Duplicate load"))
    assert theme.configure_fonts(font_app)
    assert "'Open Sans'" in theme.build_stylesheet()


def test_frozen_app_loads_font_from_pyinstaller_assets(font_app, tmp_path, monkeypatch):
    fonts = tmp_path / "assets" / "fonts"
    fonts.mkdir(parents=True)
    source = Path(theme.__file__).resolve().parents[2] / "contracts" / "assets" / "fonts"
    shutil.copyfile(source / "open-sans-latin.ttf", fonts / "open-sans-latin.ttf")
    monkeypatch.setattr(theme.sys, "_MEIPASS", str(tmp_path), raising=False)
    assert theme.configure_fonts(font_app)
    assert font_app.font().family() == "Open Sans"


@pytest.mark.parametrize("invalid", ["missing", "wrong_family"])
def test_unavailable_font_reports_failure_without_marking_it_loaded(font_app, monkeypatch, tmp_path, caplog, invalid):
    monkeypatch.setattr(theme.sys, "_MEIPASS", str(tmp_path), raising=False)
    if invalid == "wrong_family":
        monkeypatch.setattr(theme.QFontDatabase, "addApplicationFont", lambda _: 0)
        monkeypatch.setattr(theme.QFontDatabase, "applicationFontFamilies", lambda _: ["Other"])
    assert not theme.configure_fonts(font_app)
    assert not font_app.property("astralOpenSansLoaded")
    assert "could not be loaded" in caplog.text


class Socket:
    def __init__(self):
        self.frames = []
        self.fail = False

    async def send(self, text):
        if self.fail:
            raise OSError("Connection closed")
        self.frames.append(json.loads(text))


@pytest.fixture
def transport(qapp):
    client = OrchestratorClient("ws://127.0.0.1:9/ws", "synthetic", device_caps(console=True))
    client._loop = loop = asyncio.new_event_loop()
    client._ws = Socket()
    client._connected = True
    client.connection_generation = CONNECTION
    yield client, loop
    if not loop.is_closed():
        flush(loop)
        loop.close()


def flush(loop):
    for _ in range(3):
        loop.run_until_complete(asyncio.sleep(0))


def selection():
    return {"version": 1, "agent": None, "skills": [],
            "notes": [{"note_id": str(uuid.uuid4()), "revision": 1}]}


def test_device_refresh_preserves_registration_and_supersedes_obsolete_resize(transport):
    client, loop = transport
    statuses = []
    client.status.connect(statuses.append)
    voice = {"has_microphone": True, "transport": "livekit"}
    first = device_caps(320, 740, ["text"], voice, console=True)
    assert client.update_device(first)
    latest = device_caps(1440, 900, ["text"], voice, console=True)
    assert client.update_device(latest)
    latest["viewport_width"] = 999
    flush(loop)
    assert len(client._ws.frames) == 1
    frame = client._ws.frames[0]
    assert frame["action"] == "update_device"
    assert frame["session_id"] is None
    for identity in ("submission_id", "request_generation"):
        assert uuid.UUID(frame[identity]).version == 4
        assert frame[identity] == frame["payload"][identity]
    assert frame["connection_generation"] == CONNECTION
    assert frame["payload"]["device"]["viewport_width"] == 1440
    assert frame["payload"]["device"]["voice"] == voice
    assert client._register_frame()["device"]["viewport_width"] == 1440
    assert not client._pending
    assert not statuses


@pytest.mark.parametrize("retired", [False, True])
def test_device_send_errors_only_report_the_current_connection(transport, retired):
    client, loop = transport
    statuses = []
    client.status.connect(statuses.append)
    client._ws.fail = True
    assert client.update_device(device_caps(390, 844, console=True))
    if retired:
        client.connection_generation = str(uuid.uuid4())
    flush(loop)
    assert statuses == ([] if retired else ["device_update_failed"])


def test_disconnected_resize_updates_next_registration_without_queue(transport):
    client, loop = transport
    client._connected = False
    assert not client.update_device(device_caps(390, 844))
    flush(loop)
    assert not client._ws.frames and not client._pending
    assert client._register_frame()["device"]["viewport_width"] == 390


@pytest.mark.parametrize("value", [None, {"device_type": "browser"}, {"device_type": "windows", "x": float("nan")}, {"device_type": "windows", "x": "a" * 65536}])
def test_invalid_device_update_fails_closed(transport, value):
    client, _ = transport
    with pytest.raises(WindowsProtocolError):
        client.update_device(value)
    assert not client._pending and not client._ws.frames


def test_guidance_frames_are_current_correlated_and_strip_claimed_authority(transport):
    client, loop = transport
    request = str(uuid.uuid4())
    body = {"surface": "guidance", "params": {"view": "selection"}, "owner_id": "other", "token": "untrusted", "request_generation": "stale"}
    assert client.send_current_guidance("chrome_open", body, request)
    body["params"]["view"] = "changed"
    flush(loop)
    frame = client._ws.frames[0]
    assert frame["session_id"] is None
    assert frame["payload"]["params"] == {"view": "selection"}
    assert frame["connection_generation"] == CONNECTION
    assert frame["request_generation"] == frame["payload"]["request_generation"] == request
    assert frame["submission_id"] == frame["payload"]["submission_id"]
    assert "owner_id" not in frame["payload"] and "token" not in frame["payload"]
    assert not client._pending


@pytest.mark.parametrize("changed", ["owner", "socket", "loop", "connection", "stopped", "auth_hold", "disconnected", "retired", "new_request", "predicate_failure"])
def test_guidance_rechecks_owner_transport_and_generation_at_physical_send(transport, changed):
    client, loop = transport
    socket = client._ws
    request = str(uuid.uuid4())
    current = [True]

    def is_current():
        if not current[0] and changed == "predicate_failure":
            raise RuntimeError("Owner unavailable")
        return current[0]

    assert client.send_current_guidance("chrome_open", {"surface": "guidance"}, request, is_current=is_current)
    if changed in {"owner", "predicate_failure"}:
        current[0] = False
    elif changed == "socket":
        client._ws = Socket()
    elif changed == "loop":
        client._loop = None
    elif changed == "connection":
        client.connection_generation = str(uuid.uuid4())
    elif changed == "stopped":
        client._stop = True
    elif changed == "auth_hold":
        client._auth_hold = True
    elif changed == "disconnected":
        client._connected = False
    elif changed == "retired":
        client.retire_guidance(request)
    else:
        client.send_current_guidance("chrome_close", {"surface": "guidance"}, str(uuid.uuid4()))
    flush(loop)
    assert all(frame["request_generation"] != request for frame in socket.frames)
    assert not client._pending


def test_guidance_failed_socket_and_closed_loop_never_replay(transport):
    client, loop = transport
    statuses = []
    client.status.connect(statuses.append)
    client._ws.fail = True
    request = str(uuid.uuid4())
    assert client.send_current_guidance("chrome_note_search", {"fields": {"search": "notes"}}, request)
    flush(loop)
    assert statuses == ["guidance_failed:" + request]
    loop.close()
    assert not client.send_current_guidance("chrome_close", {"surface": "guidance"}, request)
    assert not client._pending


def test_guidance_submission_callback_can_retire_owner_before_scheduling(transport):
    client, loop = transport
    request = str(uuid.uuid4())
    client.submission.connect(lambda _: client.retire_guidance(request))
    assert not client.send_current_guidance("chrome_open", {"surface": "guidance"}, request)
    client.retire_guidance(str(uuid.uuid4()))
    flush(loop)
    assert not client._ws.frames and not client._pending


@pytest.mark.parametrize("action,payload", [("unknown", {}), ("chrome_open", []), ("chrome_open", {"surface": "work"}), ("chrome_note_save", {"value": float("nan")}), ("chrome_note_save", {"value": "a" * 65536}), ("chrome_turn_selection_set", {"version": 5})])
def test_invalid_guidance_is_rejected_before_transmission(transport, action, payload):
    client, _ = transport
    with pytest.raises(WindowsProtocolError):
        client.send_current_guidance(action, payload, str(uuid.uuid4()))
    assert not client._pending and not client._ws.frames


@pytest.mark.parametrize("action,payload", [("chrome_open", {"surface": "guidance"}), ("chrome_note_save", {}), ("chrome_turn_selection_set", {}), ("update_device", {"device": {}})])
def test_generic_transport_rejects_current_connection_actions(transport, action, payload):
    client, _ = transport
    client.send_event(action, payload)
    frame = {"type": "ui_event", "action": action, "payload": payload}
    client._queue_frame(json.dumps(frame))
    assert not client._ws.frames and not client._pending


def test_valid_selection_and_background_are_ordinary_authorized_chat_payloads(transport):
    client, loop = transport
    chosen = selection()
    expected = json.loads(json.dumps(chosen))
    client.send_chat("Run this", selection=chosen, background=True)
    chosen["notes"].clear()
    flush(loop)
    frame = client._ws.frames[0]
    assert frame["action"] == "chat_message"
    assert frame["payload"]["selection"] == expected
    assert frame["payload"]["async_mode"] is True
    assert frame["payload"]["snapshot_purpose"] == "commit"
    assert frame["connection_generation"] == CONNECTION
    assert client.send_current_guidance("chrome_turn_selection_set", expected, str(uuid.uuid4()))
    flush(loop)
    assert client._ws.frames[-1]["payload"]["notes"] == expected["notes"]


def test_empty_selection_preserves_plain_chat_shape(transport):
    client, loop = transport
    chosen = selection()
    chosen["notes"] = []
    client.send_chat("Plain", selection=chosen)
    flush(loop)
    payload = client._ws.frames[0]["payload"]
    assert "selection" not in payload and "async_mode" not in payload


@pytest.mark.parametrize("options", [{"selection": {"version": 1}}, {"background": "true"}])
def test_invalid_selection_or_background_does_not_submit(transport, options):
    client, _ = transport
    with pytest.raises(WindowsProtocolError):
        client.send_chat("No submission", **options)
    assert not client._pending and not client._ws.frames
