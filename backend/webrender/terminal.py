"""Sanitizes terminal byte and control streams for the shared server-owned panel.
ANSI/OSC/DCS/control and bidi sequences are removed before escaped literal text reaches a
renderer, and submitted keyboard input is bounded before the host dispatches it.
"""

from __future__ import annotations

import base64
import binascii
import math

MAX_OUTPUT_BYTES = 32768
MAX_OUTPUT_LINES = 2000
MAX_INPUT_TEXT = 262144
MAX_INPUT_BASE64 = 87384
MAX_KEYBOARD_TEXT = 512

_BIDI_AND_FORMAT = frozenset(
    {
        "\u061c",
        "\u200b",
        "\u200c",
        "\u200d",
        "\u200e",
        "\u200f",
        "\u202a",
        "\u202b",
        "\u202c",
        "\u202d",
        "\u202e",
        "\u2060",
        "\u2061",
        "\u2062",
        "\u2063",
        "\u2064",
        "\u2066",
        "\u2067",
        "\u2068",
        "\u2069",
        "\u206a",
        "\u206b",
        "\u206c",
        "\u206d",
        "\u206e",
        "\u206f",
        "\ufeff",
    }
)


def _strip_escape_streams(text: str) -> str:
    output: list[str] = []
    index = 0
    length = len(text)
    while index < length:
        character = text[index]
        if character == "\x1b":
            index += 1
            if index >= length:
                break
            introducer = text[index]
            if introducer == "[":
                index += 1
                while index < length and not "\x40" <= text[index] <= "\x7e":
                    index += 1
                index += int(index < length)
            elif introducer == "]":
                index += 1
                while index < length:
                    if text[index] == "\x07":
                        index += 1
                        break
                    if text[index] == "\x1b" and index + 1 < length and text[index + 1] == "\\":
                        index += 2
                        break
                    index += 1
            elif introducer in "PX^_":
                index += 1
                while index < length:
                    if text[index] == "\x07":
                        index += 1
                        break
                    if text[index] == "\x1b" and index + 1 < length and text[index + 1] == "\\":
                        index += 2
                        break
                    index += 1
            elif introducer in "()*+-./#%":
                index += 2
            else:
                index += 1
            continue
        if character == "\x9b":
            index += 1
            while index < length and not "\x40" <= text[index] <= "\x7e":
                index += 1
            index += int(index < length)
            continue
        if character == "\x9d":
            index += 1
            while index < length and text[index] not in "\x07\x9c":
                index += 1
            index += int(index < length)
            continue
        if character in "\x90\x98\x9e\x9f":
            index += 1
            while index < length and text[index] != "\x9c":
                index += 1
            index += int(index < length)
            continue
        output.append(character)
        index += 1
    return "".join(output)


def _safe_scalars(text: str) -> str:
    output: list[str] = []
    for character in text:
        value = ord(character)
        if 0xD800 <= value <= 0xDFFF:
            output.append("\ufffd")
        elif value < 0x20 or 0x7F <= value <= 0x9F:
            if character in "\n\t":
                output.append(character)
            elif character == "\r":
                output.append("\n")
        elif character in _BIDI_AND_FORMAT or 0xE0000 <= value <= 0xE007F:
            continue
        else:
            output.append(character)
    return "".join(output)


def _bound(text: str, max_bytes: int, max_lines: int) -> tuple[str, bool]:
    if max_bytes <= 0 or max_lines <= 0:
        raise ValueError("terminal output bounds must be positive")
    truncated = False
    lines = text.split("\n")
    if len(lines) > max_lines:
        text = "\n".join(lines[-max_lines:])
        truncated = True
    encoded = text.encode("utf-8", "replace")
    if len(encoded) > max_bytes:
        text = encoded[-max_bytes:].decode("utf-8", "ignore")
        truncated = True
    return text, truncated


def _terminal_text(value: object) -> str:
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    if isinstance(value, str) and len(value) <= MAX_INPUT_TEXT:
        return value
    raise ValueError("terminal output must be bounded text")


def decode_terminal_chunk(value: object) -> str:
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    if not isinstance(value, str):
        raise ValueError("terminal output must be text or base64")
    if len(value) > MAX_INPUT_BASE64:
        raise ValueError("terminal output is too large")
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error):
        raise ValueError("terminal output base64 is invalid") from None
    return decoded.decode("utf-8", "replace")


def sanitize_terminal_output(value: object) -> str:
    stripped = _strip_escape_streams(_terminal_text(value))
    safe = _safe_scalars(stripped)
    bounded, _ = _bound(safe, MAX_OUTPUT_BYTES, MAX_OUTPUT_LINES)
    return bounded


def bounded_terminal_output(value: object) -> tuple[str, bool]:
    stripped = _strip_escape_streams(_terminal_text(value))
    safe = _safe_scalars(stripped)
    return _bound(safe, MAX_OUTPUT_BYTES, MAX_OUTPUT_LINES)


def keyboard_input_text(value: object) -> str:
    if not isinstance(value, str):
        raise ValueError("terminal input must be text")
    if not value.strip() or len(value) > MAX_KEYBOARD_TEXT:
        raise ValueError("terminal input length is invalid")
    if any(ord(character) < 0x20 or 0x7F <= ord(character) <= 0x9F for character in value):
        raise ValueError("terminal input controls are invalid")
    return value


def terminal_number(value: object, *, maximum: int = 9007199254740991) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= maximum:
        raise ValueError("terminal number is invalid")
    return value


def terminal_seconds(value: object) -> str:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError("terminal duration is invalid")
    if value < 0:
        raise ValueError("terminal duration is invalid")
    return f"{max(0.0, float(value)):.3f}".rstrip("0").rstrip(".") or "0"


__all__ = [
    "MAX_INPUT_BASE64",
    "MAX_INPUT_TEXT",
    "MAX_KEYBOARD_TEXT",
    "MAX_OUTPUT_BYTES",
    "MAX_OUTPUT_LINES",
    "bounded_terminal_output",
    "decode_terminal_chunk",
    "keyboard_input_text",
    "sanitize_terminal_output",
    "terminal_number",
    "terminal_seconds",
]
