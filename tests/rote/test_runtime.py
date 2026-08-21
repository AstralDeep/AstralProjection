from __future__ import annotations

from rote.capabilities import DeviceType
from rote.rote import ROTE


def test_registration_lookup_and_cleanup_are_connection_scoped() -> None:
    runtime = ROTE()
    first = object()
    second = object()

    assert runtime.get_profile(first).device_type is DeviceType.BROWSER
    mobile = runtime.register_device(first, {"device_type": "mobile", "viewport_width": 390})
    assert runtime.get_profile(first) is mobile
    assert runtime.get_profile(second).device_type is DeviceType.BROWSER

    runtime.adapt(first, [{"type": "text", "content": "hello"}])
    runtime.cleanup(first)
    assert runtime.get_profile(first).device_type is DeviceType.BROWSER
    assert first not in runtime._last_components


def test_browser_fast_path_preserves_raw_component_identity() -> None:
    runtime = ROTE()
    socket = object()
    components = [{"type": "text", "content": "hello"}]
    runtime.register_device(socket, {})

    assert runtime.adapt(socket, components) is components
    assert runtime._last_components[socket] is components


def test_device_updates_distinguish_noop_no_cache_raw_and_adapted_results() -> None:
    runtime = ROTE()
    socket = object()
    initial = {
        "device_type": "browser",
        "viewport_width": 1200,
        "viewport_height": 800,
    }
    runtime.register_device(socket, initial)

    profile, components, changed = runtime.update_device(socket, dict(initial))
    assert profile.device_type is DeviceType.BROWSER
    assert components is None and changed is False

    profile, components, changed = runtime.update_device(
        socket,
        {**initial, "viewport_width": 1100},
    )
    assert components is None and changed is True

    raw = [{"type": "text", "content": "x" * 300}]
    runtime.adapt(socket, raw)
    profile, components, changed = runtime.update_device(socket, initial)
    assert profile.device_type is DeviceType.BROWSER
    assert components is raw and changed is True

    profile, components, changed = runtime.update_device(
        socket,
        {"device_type": "watch", "viewport_width": 205, "viewport_height": 251},
    )
    assert profile.device_type is DeviceType.WATCH
    assert changed is True
    assert components is not None
    assert len(components[0]["content"]) <= profile.max_text_chars


def test_empty_registration_and_update_use_default_profile() -> None:
    runtime = ROTE()
    socket = object()
    assert runtime.register_device(socket, {}).device_type is DeviceType.BROWSER
    profile, components, changed = runtime.update_device(socket, {})
    assert profile.device_type is DeviceType.BROWSER
    assert components is None and changed is False
