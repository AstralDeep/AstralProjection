"""Private export assets are reproducible, offline and installable resources."""
import base64
import hashlib
import json
import re
import sys
from pathlib import Path

import pytest

from astralprojection import export_asset_path
from astralprojection.resources import InvalidResourcePath
from scripts import build_native_export as builder


def test_generated_document_and_csp_are_exact_shared_assets():
    markup, manifest = builder.build()
    assert markup == export_asset_path("export.html").read_text()
    assert manifest == json.loads(export_asset_path("manifest.json").read_text())
    assert manifest["template_sha256"] == hashlib.sha256(markup.encode()).hexdigest()
    scripts = re.findall(r"<script>(.*?)</script>", markup, re.S)
    for code in scripts:
        digest = base64.b64encode(hashlib.sha256(code.encode()).digest()).decode()
        assert f"'sha256-{digest}'" in markup
    for name in ("canvas-export.js", "canvas-export-host.js"):
        assert (builder.STATIC / name).read_text() in scripts
    assert "Plotly.newPlot" not in markup and "__ASTRAL_PLOTLY_VENDOR__" not in markup
    assert markup.count("__ASTRAL_EXPORT_PRESENTATION_BASE64__") == 1
    assert "connect-src 'none'" in markup and "base-uri 'none'" in markup
    assert "form-action 'none'" in markup and "data:font/woff2;base64," in markup
    shell = (builder.ROOT / "backend/webrender/templates/shell.html").read_text()
    assert shell.index('/static/canvas-export.js?') < shell.index('/static/client.js?')


def test_generator_cli_checks_and_writes_only_explicit_output(tmp_path, monkeypatch):
    monkeypatch.setattr(builder, "OUTPUT", tmp_path / "output")
    monkeypatch.setattr(sys, "argv", ["build_native_export.py", "--check"])
    assert builder.main() == 1
    monkeypatch.setattr(sys, "argv", ["build_native_export.py"])
    assert builder.main() == 0
    monkeypatch.setattr(sys, "argv", ["build_native_export.py", "--check"])
    assert builder.main() == 0
    (builder.OUTPUT / "export.html").write_text("altered")
    assert builder.main() == 1


@pytest.mark.parametrize("path,suffix,error", [
    ("astral.css", "x{background:url(https://outside.invalid/image)}", "Unbundled"),
    ("astral.css", "</style>", "embedding"),
    ("canvas-export.js", "</script>", "embedding"),
])
def test_unbundled_assets_or_script_boundaries_refuse(path, suffix, error, monkeypatch):
    original = Path.read_bytes
    def read(source):
        value = original(source)
        return value + suffix.encode() if source == builder.STATIC / path else value
    monkeypatch.setattr(Path, "read_bytes", read)
    with pytest.raises(ValueError, match=error):
        builder.build()


@pytest.mark.parametrize("path", ["../ui_protocol.json", "/export.html", "x\\export.html", "CON"])
def test_export_accessor_refuses_escaping_paths(path):
    with pytest.raises(InvalidResourcePath):
        export_asset_path(path)
