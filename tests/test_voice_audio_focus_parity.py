"""Verify the Android, Apple and web voice clients suspend with the same server-defined
audio-focus and output-route interruption reasons and pair them with the mandatory
microphone disable. The voice audio fence must keep every client on one session vocabulary.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

ANDROID = ROOT / "android-client/app/src/main/kotlin/com/personalailabs/astraldeep/app/voice/VoiceSessionController.kt"
APPLE = ROOT / "apple-clients/AstralApp/AstralApp/Voice/VoiceSessionController.swift"
WEB = ROOT / "backend/webrender/static/client.js"

AUDIO_FOCUS_REASON = "audio_interrupted"
ROUTE_REASON = "route_unavailable"


def test_android_audio_fence_uses_the_shared_interruption_reasons():
    source = ANDROID.read_text(encoding="utf-8")
    assert f'suspendMediaForAudio("{AUDIO_FOCUS_REASON}")' in source
    assert f'suspendMediaForAudio("{ROUTE_REASON}")' in source
    assert 'put("microphone_enabled", false)' in source


def test_apple_voice_suspends_with_the_same_interruption_reasons():
    source = APPLE.read_text(encoding="utf-8")
    assert f'suspendMedia(reason: "{AUDIO_FOCUS_REASON}")' in source
    assert f'suspendMedia(reason: "{ROUTE_REASON}")' in source
    assert '"microphone_enabled": .bool(false)' in source


def test_web_voice_reports_the_same_audio_interruption_reason():
    source = WEB.read_text(encoding="utf-8")
    assert AUDIO_FOCUS_REASON in source
    assert "foreground_reason" in source
