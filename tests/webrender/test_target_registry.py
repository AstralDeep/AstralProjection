"""Behavioral contracts for target fallback and profile routing."""

from types import SimpleNamespace

import astralprims as ap

from rote.capabilities import DeviceType
from webrender import render_for_target, target_for_profile


def test_unknown_target_warns_and_falls_back_to_web(caplog):
    rendered = render_for_target("missing-target", [ap.Text(content="fallback").to_dict()])
    assert "fallback" in rendered
    assert "unknown client target" in caplog.text


def test_profile_target_selection_is_flag_gated_and_registered(monkeypatch):
    voice = SimpleNamespace(device_type=DeviceType.VOICE)
    explicit = SimpleNamespace(device_type=DeviceType.BROWSER, render_target="AOM")
    unknown = SimpleNamespace(device_type=DeviceType.BROWSER, render_target="missing")

    monkeypatch.setenv("FF_NATIVE_TARGETS", "false")
    assert target_for_profile(voice) == "web"

    monkeypatch.setenv("FF_NATIVE_TARGETS", " YES ")
    assert target_for_profile(explicit) == "aom"
    assert target_for_profile(voice) == "voice"
    assert target_for_profile(unknown) == "web"
