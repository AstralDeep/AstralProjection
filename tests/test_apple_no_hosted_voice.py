"""Fails when an Apple production source starts the hosted voice controller or reaches api/voice or LiveKit.
Only the dormant hosted files and the Watch REST client may name them, and the app model may only hold the inert controller.
"""

from __future__ import annotations

from pathlib import Path
import re

import pytest

ROOT = Path(__file__).resolve().parents[1] / "apple-clients"
APP_SOURCES = ROOT / "AstralApp" / "AstralApp"
SCANNED = ("AstralApp/AstralApp", "AstralCore/Sources", "AstralKernel/Sources", "AstralWatch")

HOSTED_FILES = {
    "AstralApp/AstralApp/Voice/VoiceSessionController.swift": "dormant hosted controller with the api/voice REST client and LiveKit media client",
    "AstralApp/AstralApp/Voice/AppleLocalSpeech.swift": "client-local speech engine reachable only through the dormant hosted controller",
    "AstralApp/AstralApp/Voice/AppleLocalSpeechProgress.swift": "progress tracker used only by the dormant client-local speech engine",
    "AstralApp/AstralApp/Voice/AppleLocalVoiceRuntime.swift": "client-local voice runtime reachable only through the dormant hosted controller",
}
WATCH_FILES = {
    "AstralWatch/WatchVoiceREST.swift": "the Watch posts to api/voice by design",
    "AstralWatch/WatchVoiceBridge.swift": "the Watch voice bridge drives its own api/voice client by design",
}
ALLOWED_FILES = {**HOSTED_FILES, **WATCH_FILES}

APP_MODEL = "AstralApp/AstralApp/AppModel.swift"
APP_MODEL_SYMBOLS = {
    "AppleVoiceSessionController": "the app model owns the inert hosted controller and feeds it frames and lifecycle events",
    "AppleVoicePermission": "read-only microphone permission and route status for the device descriptor",
}
HOSTED_MEMBERS_NEVER_STARTING = {
    "active",
    "audioEngineConfigurationChanged",
    "audioRouteChanged",
    "audioSessionInterrupted",
    "audioSessionInterruptionEnded",
    "awaitingAcceptance",
    "close",
    "consume",
    "controlTransportDisconnected",
    "conversationDidHydrate",
    "installTerminalNoticeForUITesting",
    "installUIConnection",
    "mediaConnected",
    "message",
    "phase",
    "sceneBecameActive",
    "sceneBecameInactive",
    "sessionLocked",
    "sessionUnlocked",
    "setChatAdopter",
    "setFrameSender",
    "terminalNotice",
    "updateVisibleChatLocally",
}

ALWAYS_FORBIDDEN = re.compile(r"api/voice|LiveKit")
DECLARATION = re.compile(
    r"^\s*(?:@\w+\s+)*(?:(?:public|internal|private|fileprivate|final|nonisolated)\s+)*"
    r"(?:class|struct|enum|protocol|actor)\s+(\w+)",
    re.M,
)
HOSTED_CONTROLLER_MEMBER = re.compile(
    r"(?<![\w.])voice\.(\w+)|(?<![\w.])(?:self|model)\.voice\.(\w+)"
)
QUALIFIED_CONTROLLER_MEMBER = re.compile(r"(?<![\w.])(?:self|model)\.voice\.(\w+)()")
HOSTED_CONTROLLER_ALIAS = re.compile(r"\bmodel\.voice\b(?!\.)")


def strip_comments(text: str, keep_strings: bool = True) -> str:
    out: list[str] = []
    i, n = 0, len(text)
    while i < n:
        pair = text[i : i + 2]
        if pair == "//":
            while i < n and text[i] != "\n":
                i += 1
        elif pair == "/*":
            depth = 1
            i += 2
            while i < n and depth:
                if text[i : i + 2] == "/*":
                    depth += 1
                    i += 2
                elif text[i : i + 2] == "*/":
                    depth -= 1
                    i += 2
                else:
                    if text[i] == "\n":
                        out.append("\n")
                    i += 1
        elif text[i] == '"':
            multiline = text[i : i + 3] == '"""'
            quote = '"""' if multiline else '"'
            out.append(quote)
            i += len(quote)
            while i < n and text[i : i + len(quote)] != quote:
                if text[i] == "\\":
                    out.append(text[i : i + 2] if keep_strings else "")
                    i += 2
                    continue
                if text[i] == "\n" and not multiline:
                    break
                out.append(text[i] if keep_strings else "")
                i += 1
            out.append(quote)
            i += len(quote)
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def declared_names(text: str) -> set[str]:
    return set(DECLARATION.findall(text))


def hosted_members(code: str, relative: str = APP_MODEL) -> set[str]:
    pattern = HOSTED_CONTROLLER_MEMBER if relative == APP_MODEL else QUALIFIED_CONTROLLER_MEMBER
    return {match.group(1) or match.group(2) for match in pattern.finditer(code)}


def violations(relative: str, text: str, hosted_symbols: set[str]) -> list[str]:
    if relative in ALLOWED_FILES:
        return []
    found = [
        f"{relative}: reaches {match.group(0)!r}"
        for match in ALWAYS_FORBIDDEN.finditer(strip_comments(text))
    ]
    code = strip_comments(text, keep_strings=False)
    for symbol in sorted(hosted_symbols):
        if re.search(rf"\b{symbol}\b", code) and not (
            relative == APP_MODEL and symbol in APP_MODEL_SYMBOLS
        ):
            found.append(f"{relative}: references hosted voice type {symbol}")
    for member in hosted_members(code, relative):
        if member not in HOSTED_MEMBERS_NEVER_STARTING:
            found.append(f"{relative}: calls hosted voice member {member}")
    if relative != APP_MODEL:
        found.extend(
            f"{relative}: aliases the hosted voice controller"
            for _ in HOSTED_CONTROLLER_ALIAS.finditer(code)
        )
    return found


def production_sources() -> dict[str, str]:
    sources: dict[str, str] = {}
    for base in SCANNED:
        for path in sorted((ROOT / base).rglob("*.swift")):
            sources[path.relative_to(ROOT).as_posix()] = path.read_text(encoding="utf-8")
    return sources


def hosted_symbols(sources: dict[str, str]) -> set[str]:
    names: set[str] = set()
    for relative in HOSTED_FILES:
        names |= declared_names(strip_comments(sources[relative]))
    return names


def test_allow_list_names_only_existing_files_with_reasons():
    for relative, reason in ALLOWED_FILES.items():
        assert (ROOT / relative).is_file(), relative
        assert reason.strip()
    assert set(HOSTED_FILES) == {
        f"AstralApp/AstralApp/Voice/{path.name}" for path in (APP_SOURCES / "Voice").glob("*.swift")
    }


def test_hosted_files_are_the_only_main_app_declarations_of_hosted_voice():
    sources = production_sources()
    symbols = hosted_symbols(sources)
    assert {
        "AppleVoiceSessionController",
        "AppleLiveKitVoiceMediaClient",
        "URLSessionAppleVoiceControlAPI",
    } <= symbols
    assert set(APP_MODEL_SYMBOLS) <= symbols
    assert any(
        "api/voice" in text for relative, text in sources.items() if relative in HOSTED_FILES
    )


def test_no_production_source_outside_the_allow_list_reaches_hosted_voice():
    sources = production_sources()
    symbols = hosted_symbols(sources)
    found = [
        item for relative, text in sources.items() for item in violations(relative, text, symbols)
    ]
    assert found == []


def test_the_app_model_only_calls_non_starting_members_of_the_hosted_controller():
    code = strip_comments(production_sources()[APP_MODEL], keep_strings=False)
    members = hosted_members(code)
    assert members and members <= HOSTED_MEMBERS_NEVER_STARTING
    assert not {"activate", "takeover", "perform", "end"} & members


SYMBOLS = {"AppleVoiceSessionController", "AppleVoicePermission", "AppleLiveKitGrant"}


@pytest.mark.parametrize(
    "source",
    [
        'let url = base + "api/voice/sessions"',
        "import LiveKit",
        "let room = LiveKitRoom()",
        "let client = AppleLiveKitGrant.self",
        "await model.voice.activate()",
        "await model.voice.takeover()",
        "let hosted = model.voice",
        "let controller = AppleVoiceSessionController()",
    ],
)
def test_a_new_hosted_voice_reference_is_reported(source):
    assert violations("AstralApp/AstralApp/Views/ChatView.swift", source, SYMBOLS)


@pytest.mark.parametrize(
    "source",
    [
        "// await model.voice.activate() and api/voice",
        '/* import LiveKit */ let a = "https://example.test"',
        "let voice = model.onDeviceVoice\nawait model.onDeviceVoice.activate()",
        "model.voice.message",
        'let note = """\nplain\n"""',
    ],
)
def test_comments_on_device_voice_and_read_only_members_are_not_reported(source):
    assert violations("AstralApp/AstralApp/Views/ChatView.swift", source, SYMBOLS) == []


def test_the_app_model_may_hold_the_controller_but_not_start_it():
    held = "let voice: AppleVoiceSessionController\nself.voice = AppleVoiceSessionController()\nvoice.consume(frame)"
    assert violations(APP_MODEL, held, SYMBOLS) == []
    assert violations(APP_MODEL, "voice.activate()", SYMBOLS)
    assert violations(APP_MODEL, "let r = AppleLiveKitGrant.self", SYMBOLS)


def test_allow_listed_files_are_exempt():
    assert (
        violations("AstralWatch/WatchVoiceREST.swift", 'path: "api/voice/sessions"', SYMBOLS) == []
    )
    assert (
        violations(
            "AstralApp/AstralApp/Voice/VoiceSessionController.swift", "import LiveKit", SYMBOLS
        )
        == []
    )


def test_string_scanner_keeps_code_after_a_url_literal():
    assert violations(
        "AstralApp/AstralApp/X.swift", 'let u = "https://e.test" + "api/voice"', SYMBOLS
    )
