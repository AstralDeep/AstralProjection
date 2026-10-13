"""Exercise native owner decisions and real Markdown safety boundaries independently.
The regression gate runs these named cases against isolated, deliberately broken guards.
"""

import importlib.util
from html.parser import HTMLParser
from pathlib import Path

import pytest

from scripts.ci_lanes import classify, validate_lane


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "projection_guard_sanitize", ROOT / "backend/webrender/sanitize.py"
)
SANITIZE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SANITIZE)


class Links(HTMLParser):
    def __init__(self, markup):
        super().__init__()
        self.hrefs = []
        self.feed(markup)

    def handle_starttag(self, tag, attributes):
        if tag == "a":
            self.hrefs.append(dict(attributes)["href"])


def test_native_failures_and_skips_do_not_authorize():
    assert validate_lane("true", ["success", "success"]) == "passed"
    assert validate_lane("false", ["skipped", "skipped"]) == "not applicable"
    for result in ("failure", "skipped", "cancelled", "timed_out", ""):
        with pytest.raises(ValueError):
            validate_lane("true", ["success", result])
    with pytest.raises(ValueError):
        validate_lane("false", ["skipped", "success"])


def test_shared_changes_require_every_native_lane():
    for path in (
        "contracts/ui_protocol.json",
        "backend/rote/adapter.py",
        "backend/webrender/chrome/menu_model.py",
        "backend/webrender/chrome/console_model.py",
        "tooling/python-ci/requirements.lock.txt",
        ".github/workflows/ci.yml",
    ):
        assert classify([path]) == {"android": True, "apple": True}
    assert classify(["backend/webrender/sanitize.py"]) == {"android": False, "apple": False}
    assert classify(["android-client/app/src/Main.kt"]) == {"android": True, "apple": False}
    assert classify(["apple-clients/AstralCore/Core.swift"]) == {"android": False, "apple": True}


def test_markdown_unsafe_destinations_are_blocked():
    assert Links(SANITIZE.inline_md("[allowed](https://example.test/a_b)")).hrefs == [
        "https://example.test/a_b"
    ]
    for destination in ("javascript:alert(1)", "data:text/html,evil", "vbscript:evil"):
        rendered = SANITIZE.inline_md(f"[unsafe]({destination})")
        assert Links(rendered).hrefs == ["#"]
        assert destination not in rendered


def test_markdown_destination_length_limit_is_exact():
    prefix = "https://example.test/"
    accepted = prefix + "x" * (2048 - len(prefix))
    assert Links(SANITIZE.inline_md(f"[maximum]({accepted})")).hrefs == [accepted]
    assert Links(SANITIZE.inline_md(f"[too long]({accepted}x)")).hrefs == []
