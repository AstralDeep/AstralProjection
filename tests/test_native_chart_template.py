"""The embedded chart document is reproducible and has a closed trust boundary."""

import base64
import hashlib
import importlib.util
import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "scripts/build_native_chart.py"
spec = importlib.util.spec_from_file_location("build_native_chart", MODULE)
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


def test_template_exactly_tracks_web_options_vendor_and_fonts():
    assert builder.OUTPUT.read_text() == builder.build()
    assert "delete layout.width" in builder.build()
    assert "cfg.responsive = true" in builder.build()
    assert "viewportWidth < 640" in builder.build()
    assert "if (el.getBoundingClientRect().width < 500)" in builder.build()


def test_only_the_exact_two_scripts_can_execute():
    template = builder.build()
    vendor = (ROOT / "backend/webrender/static/vendor/plotly.min.js").read_text()
    filled = template.replace("__ASTRAL_PLOTLY_VENDOR__", vendor)
    scripts = re.findall(r"<script>(.*?)</script>", filled, flags=re.S)
    assert len(scripts) == 2
    for script in scripts:
        digest = base64.b64encode(hashlib.sha256(script.encode()).digest()).decode()
        assert f"'sha256-{digest}'" in template
    assert "script-src 'unsafe-inline'" not in template
    assert "unsafe-eval" not in template
    for directive in ("default-src 'none'", "connect-src 'none'", "frame-src 'none'",
                      "object-src 'none'", "base-uri 'none'", "form-action 'none'"):
        assert directive in template
    assert "addJavascriptInterface" not in template
    assert "messageHandlers" not in template
    assert template.count("__ASTRAL_CHART_PAYLOAD_BASE64__") == 1


def test_changed_vendor_cannot_break_out_of_its_script_tag(tmp_path, monkeypatch):
    static = tmp_path / "backend/webrender/static"
    (static / "vendor").mkdir(parents=True)
    (static / "client.js").write_text((ROOT / "backend/webrender/static/client.js").read_text())
    (static / "vendor/plotly.min.js").write_text("</SCRIPT><script>evil()</script>")
    monkeypatch.setattr(builder, "ROOT", tmp_path)
    with pytest.raises(ValueError, match="exact bytes"):
        builder.build()


def test_cli_build_and_check_refuse_absent_or_stale_template(tmp_path, monkeypatch):
    output = tmp_path / "assets/chart.html"
    monkeypatch.setattr(builder, "OUTPUT", output)
    with pytest.raises(SystemExit, match="drifted"):
        builder.main(["--check"])
    builder.main([])
    builder.main(["--check"])
    output.write_text("stale")
    with pytest.raises(SystemExit, match="drifted"):
        builder.main(["--check"])
