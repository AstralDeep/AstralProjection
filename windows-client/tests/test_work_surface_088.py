"""Work responses are current reads, never queued or unsolicited content."""

import asyncio
import json
import uuid
from pathlib import Path

import pytest
from test_message_routing import win as window_fixture  # noqa: F401 - pytest fixture registration
from astral_client.protocol import OrchestratorClient, WindowsProtocolError
from PySide6.QtCore import Qt
from PySide6.QtWidgets import QLabel


@pytest.fixture(name="win")
def work_window(request):
    return request.getfixturevalue("window_fixture")


def test_unsolicited_work_cannot_open_or_pin_dialog(win):
    for mode in ("replace", "mandatory"):
        win._on_chrome_surface(
            {"surface_key": "work", "title": "Private result", "components": [], "mode": mode}
        )
        assert win._surface_dialog is None


def test_disconnected_work_read_is_not_ordinary_queued_event(win):
    win._open_surface("work", "Recent work")
    win._emit("chrome_open", {"surface": "work", "params": {"mode": "list"}})
    win._retry_surface("work", {"mode": "list"})
    assert win.client.sent == []


CONNECTION = "22222222-2222-4222-8222-222222222222"


def ready(win):
    win.client.connection_generation = CONNECTION
    win._resume_store.storage_key = "synthetic-owner"
    sent = []
    win.client.send_current_work_read = lambda params, generation, **kwargs: (
        sent.append((dict(params), generation)) or True
    )
    return sent


def frame(generation, title="Selected excerpts", **extra):
    return {
        "surface_key": "work",
        "request_generation": generation,
        "title": title,
        "components": [{"type": "text", "content": title}],
        **extra,
    }


def test_latest_read_only_accepts_exact_response_and_consumes_it(win):
    sent = ready(win)
    win._open_surface("work", "Recent work")
    first = sent[-1][1]
    win._emit("chrome_open", {"surface": "work", "params": {"mode": "detail"}})
    second = sent[-1][1]
    assert first != second and uuid.UUID(second).version == 4
    assert win._surface_dialog._params == {"mode": "detail"}
    win._on_chrome_surface(frame(first, "stale private content"))
    assert win._surface_dialog._title.text() == "Recent work"
    win._on_chrome_surface(frame(second))
    assert win._surface_dialog._title.text() == "Selected excerpts"
    assert win._work_read is None
    win._on_chrome_surface(frame(second, "duplicate"))
    assert win._surface_dialog._title.text() == "Selected excerpts"


@pytest.mark.parametrize("phase", ["pending", "displayed", "timeout"])
@pytest.mark.parametrize("notice", ["close", "error", "mandatory", "other"])
def test_uncorrelated_legacy_chrome_cannot_replace_selected_work(win, phase, notice):
    sent = ready(win)
    win._open_surface("work", "Recent work")
    if phase == "displayed":
        win._on_chrome_surface(frame(sent[-1][1]))
        assert win._work_read is None
    elif phase == "timeout":
        win._surface_dialog._on_timeout()
    dialog = win._surface_dialog
    before = (
        dialog._title.text(),
        dialog.isVisible(),
        dialog._mandatory,
        win._banner.text(),
        win._work_read,
    )
    message = (
        {"surface_key": "", "components": []}
        if notice == "close"
        else {
            "surface_key": "error" if notice == "error" else "theme",
            "title": "Uncorrelated notice",
            "components": [],
            "mode": "mandatory" if notice == "mandatory" else "replace",
        }
    )
    win._on_chrome_surface(message)
    assert (
        dialog._title.text(),
        dialog.isVisible(),
        dialog._mandatory,
        win._banner.text(),
        win._work_read,
    ) == before
    win._open_surface("theme", "Theme")
    win._on_chrome_surface({"surface_key": "theme", "title": "Theme loaded", "components": []})
    assert dialog._title.text() == "Theme loaded"
    win._on_chrome_surface({"surface_key": "", "components": []})
    assert not dialog.isVisible()


def test_canonical_work_result_uses_complete_literal_qt_labels(win):
    root = Path(__file__).resolve().parents[2]
    fixture = json.loads((root / "contracts/fixtures/work_088/read_surface.json").read_text())
    message = fixture["frames"]["result"]
    # Keep the actual canonical builder shapes and variants while exercising
    # source-controlled text, with no Markdown/HTML/link rendering authority.
    literal = '**literal** [source](https://example.invalid) <b>HTML</b> & "text"\nSecond line'
    expected = []

    def inspect(component):
        kind = component.get("type")
        if kind == "text":
            expected.append(component["content"])
        if kind == "card":
            component["title"] = literal
            expected.append(literal)
        if kind == "keyvalue":
            expected.extend(str(item["value"]) for item in component["items"])
        for value in component.values():
            if isinstance(value, list):
                for child in value:
                    if isinstance(child, dict):
                        inspect(child)

    message["components"][1]["content"] = literal
    for component in message["components"]:
        inspect(component)
    sent = ready(win)
    win._open_surface("work", "Recent work")
    message["request_generation"] = sent[-1][1]
    win._on_chrome_surface(message)
    labels = win._surface_dialog._inner.findChildren(QLabel)
    for text in expected:
        matches = [label for label in labels if label.text() == text]
        assert matches, "canonical text must remain complete, including long source URLs"
        assert all(label.textFormat() == Qt.TextFormat.PlainText for label in matches)
    assert any(len(text) > 512 and text.startswith("https://") for text in expected)


@pytest.mark.parametrize(
    "change",
    [
        "close",
        "escape",
        "other_surface",
        "owner",
        "client",
        "connection",
        "disconnect",
        "auth",
        "rotation",
        "new_chat",
    ],
)
def test_retirement_never_reopens_old_work(win, change):
    sent = ready(win)
    win._open_surface("work", "Recent work")
    old = sent[-1][1]
    if change == "close":
        win._surface_dialog.close()
    elif change == "escape":
        win._surface_dialog.reject()
    elif change == "other_surface":
        win._open_surface("theme", "Theme")
    elif change == "owner":
        win._resume_store.storage_key = "other-owner"
    elif change == "client":
        win.client = type(win.client)()
    elif change == "connection":
        win.client.connection_generation = str(uuid.uuid4())
    elif change == "disconnect":
        win._on_status("closed:synthetic")
    elif change == "auth":
        # Avoid ordinary external reauthentication; retirement precedes it.
        win._begin_silent_refresh = lambda: None
        win._on_status("auth_required:synthetic")
    elif change == "rotation":
        win._voice_connection_changed(str(uuid.uuid4()))
    else:
        win._new_chat()
    title = win._surface_dialog._title.text()
    visible = win._surface_dialog.isVisible()
    win._on_chrome_surface(frame(old, "foreign private content"))
    assert win._surface_dialog._title.text() == title
    assert win._surface_dialog.isVisible() == visible


@pytest.mark.parametrize(
    "changes",
    [
        {"request_generation": None},
        {"request_generation": 5},
        {"request_generation": "wrong"},
        {"mode": "mandatory"},
        {"surface_key": "theme"},
    ],
)
def test_malformed_work_never_pins_or_banners(win, changes):
    sent = ready(win)
    win._open_surface("work", "Recent work")
    value = frame(sent[-1][1])
    value.update(changes)
    before = win._banner.text()
    win._on_chrome_surface(value)
    assert not win._surface_dialog._mandatory
    assert win._surface_dialog._title.text() == "Recent work"
    assert win._banner.text() == before


def test_failure_and_retry_are_current_and_fresh(win):
    sent = ready(win)
    win._open_surface("work", "Recent work")
    first = sent[-1][1]
    win._on_status("work_read_failed:" + str(uuid.uuid4()))
    assert win._work_read is not None
    win._on_status("work_read_failed:" + first)
    assert win._work_read is None
    assert not win._surface_dialog._timer.isActive()
    win._surface_dialog._retry()
    assert sent[-1][1] != first
    assert win._surface_dialog._timer.isActive()


class Socket:
    def __init__(self, fail=False):
        self.frames = []
        self.fail = fail

    async def send(self, value):
        if self.fail:
            raise OSError("synthetic")
        self.frames.append(json.loads(value))


@pytest.fixture
def transport(qapp):
    client = OrchestratorClient("ws://127.0.0.1:9/ws", "synthetic", work_reads=True)
    loop = asyncio.new_event_loop()
    client._loop = loop
    client._ws = Socket()
    client._connected = True
    client.connection_generation = CONNECTION
    yield client, loop
    if not loop.is_closed():
        loop.run_until_complete(asyncio.sleep(0))
        loop.close()


def flush(loop):
    # Deliver the scheduled coroutine and its future completion callback.
    loop.run_until_complete(asyncio.sleep(0))
    loop.run_until_complete(asyncio.sleep(0))


def test_registered_wire_is_identified_before_send_and_params_frozen(transport):
    client, loop = transport
    seen = []
    client.submission.connect(seen.append)
    generation = str(uuid.uuid4())
    params = {"mode": "list", "nested": {"x": 1}}
    assert client.send_current_work_read(params, generation)
    assert len(seen) == 1 and not client._ws.frames
    params["nested"]["x"] = 9
    flush(loop)
    value = client._ws.frames[0]
    assert value["payload"]["params"]["nested"]["x"] == 1
    assert value["submission_id"] == value["payload"]["submission_id"] == seen[0].submission_id
    assert value["request_generation"] == value["payload"]["request_generation"] == generation
    assert value["connection_generation"] == CONNECTION
    assert not client._pending


@pytest.mark.parametrize(
    "change", ["closed", "stopped", "socket", "connection", "retired", "new_read", "callback"]
)
def test_scheduled_read_rechecks_transport_after_wait(transport, change):
    client, loop = transport
    socket = client._ws
    generation = str(uuid.uuid4())
    if change == "callback":
        client.submission.connect(lambda _: client.retire_work_read(generation))
    assert client.send_current_work_read({}, generation)
    if change == "closed":
        client._connected = False
    elif change == "stopped":
        client._stop = True
    elif change == "socket":
        client._ws = Socket()
    elif change == "connection":
        client.connection_generation = str(uuid.uuid4())
    elif change == "retired":
        client.retire_work_read(generation)
    elif change == "new_read":
        client.send_current_work_read({}, str(uuid.uuid4()))
    flush(loop)
    assert all(value["request_generation"] != generation for value in socket.frames)
    assert not client._pending


def test_disconnected_and_failed_send_never_queue_but_ordinary_events_do(transport):
    client, loop = transport
    client._connected = False
    assert not client.send_current_work_read({}, str(uuid.uuid4()))
    client.send_event("get_history", {})
    assert len(client._pending) == 1
    client._connected = True
    client._ws.fail = True
    notices = []
    client.status.connect(notices.append)
    generation = str(uuid.uuid4())
    assert client.send_current_work_read({}, generation)
    flush(loop)
    assert notices == ["work_read_failed:" + generation]
    assert len(client._pending) == 1


def test_capability_is_factory_opt_in_and_invalid_read_fails_closed(qapp):
    legacy = OrchestratorClient("ws://127.0.0.1:9/ws", "synthetic")
    current = OrchestratorClient("ws://127.0.0.1:9/ws", "synthetic", work_reads=True)
    assert "work_read_v1" not in legacy._register_frame()["capabilities"]
    assert "work_read_v1" in current._register_frame()["capabilities"]
    with pytest.raises(WindowsProtocolError):
        current.send_current_work_read({}, "wrong")
    with pytest.raises(WindowsProtocolError):
        current.send_current_work_read([], str(uuid.uuid4()))


def test_timeout_retires_response_and_retry_replaces_generation(win):
    sent = ready(win)
    win._open_surface("work", "Recent work")
    old = sent[-1][1]
    win._surface_dialog._on_timeout()
    assert win._work_read is None
    win._on_chrome_surface(frame(old, "late after timeout"))
    assert win._surface_dialog._title.text() == "Recent work"
    win._surface_dialog._retry()
    assert sent[-1][1] != old


def test_submission_callback_owner_change_is_rechecked(transport):
    client, loop = transport
    current = [True]
    client.submission.connect(lambda _: current.__setitem__(0, False))
    assert not client.send_current_work_read({}, str(uuid.uuid4()), is_current=lambda: current[0])
    flush(loop)
    assert not client._ws.frames and not client._pending


@pytest.mark.parametrize("changed", ["owner", "unavailable", "socket"])
def test_scheduled_read_rechecks_caller_context_at_physical_send(transport, changed):
    client, loop = transport
    socket = client._ws
    scheduled = [False]
    notices = []
    client.status.connect(notices.append)

    def is_current():
        if not scheduled[0]:
            return True
        if changed == "unavailable":
            raise RuntimeError("synthetic context retired")
        if changed == "socket":
            client._ws = Socket()
            return True
        return False

    request = str(uuid.uuid4())
    assert client.send_current_work_read({}, request, is_current=is_current)
    assert not socket.frames
    scheduled[0] = True
    flush(loop)
    assert not socket.frames and not client._ws.frames and not client._pending
    assert notices == ["work_read_failed:" + request]


def test_generic_transport_cannot_accidentally_retain_work_reads(transport):
    client, loop = transport
    client._connected = False
    client.send_event("chrome_open", {"surface": "work", "params": {}})
    assert not client._pending
    client.send_event("chrome_open", {"surface": "theme", "params": {}})
    assert len(client._pending) == 1


def test_rendered_work_button_and_failed_send_keep_honest_loading(win):
    sent = ready(win)
    win._open_surface("work", "Recent work")
    old = sent[-1][1]
    win._surface_dialog._emit_from_surface(
        "chrome_open", {"surface": "work", "params": {"mode": "result"}}
    )
    assert sent[-1][1] != old
    assert win._surface_dialog._status.text() == "Loading…"
    win.client.send_current_work_read = lambda *_args, **_kwargs: False
    win._retry_surface("work", {"mode": "result"})
    assert win._work_read is None
    assert not win._surface_dialog._timer.isActive()


def test_accepted_reply_retires_transport_and_only_its_local_banner(win):
    sent = ready(win)
    retired = []
    win.client.retire_work_read = retired.append
    win._open_surface("work", "Recent work")
    request = sent[-1][1]
    win._show_banner("Submitting…", operation_request_generation=request)
    win._on_chrome_surface(frame(request))
    assert retired == [request]
    assert win._banner.isHidden()


@pytest.mark.parametrize("action", ["chrome_open", "chrome_close"])
def test_other_surface_navigation_retires_old_read_before_roundtrip(win, action):
    sent = ready(win)
    win._open_surface("work", "Recent work")
    request = sent[-1][1]
    win._emit(action, {"surface": "theme"})
    assert win._work_read is None
    win._on_chrome_surface(frame(request, "retired"))
    assert win._surface_dialog._title.text() == "Recent work"


def test_loop_shutdown_refuses_without_queue_or_leaked_coroutine(transport):
    client, loop = transport
    loop.close()
    statuses = []
    client.status.connect(statuses.append)
    request = str(uuid.uuid4())
    assert not client.send_current_work_read({}, request)
    assert statuses == ["work_read_failed:" + request]
    assert not client._pending
