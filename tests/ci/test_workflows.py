from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[2]
ACTIVE = ROOT / ".github" / "workflows"
INACTIVE = ROOT / "workflows-disabled"


def _job_ids(text: str) -> set[str]:
    jobs = text.partition("\njobs:\n")[2]
    assert jobs
    return set(re.findall(r"(?m)^  ([A-Za-z0-9_-]+):\s*$", jobs))


def test_core_ci_is_active_read_only_and_projection_owned() -> None:
    text = (ACTIVE / "ci.yml").read_text(encoding="utf-8")

    assert _job_ids(text) == {"python", "web", "windows", "required"}
    assert "pull_request:" in text and "branches: [main]" in text
    assert "permissions:\n  contents: read" in text
    assert "if: ${{ false }}" not in text
    assert "components/AstralProjection/" not in text
    assert "id-token: write" not in text and "secrets." not in text
    for action in re.findall(r"(?m)^\s*-\s*uses:\s*[^@\s]+@([^\s#]+)", text):
        assert re.fullmatch(r"[0-9a-f]{40}", action)


def test_core_ci_runs_qualified_owner_gates() -> None:
    text = (ACTIVE / "ci.yml").read_text(encoding="utf-8")

    assert "gitleaks_8.30.1_linux_x64.tar.gz" in text
    assert "551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb" in text
    assert 'gitleaks git --redact --log-opts="--all"' in text
    assert "ruff check src backend tests scripts windows-client" in text
    assert "pytest -q" in text
    assert "python -m build" in text
    assert 'python -c "import astralprojection, rote, webrender"' in text
    assert "test \"$(corepack npm --version)\" = \"11.16.0\"" in text
    assert "test:coverage-conversion:browser" in text
    assert "continuity-contract-060.spec.js" in text
    assert "voice-conversation-065.spec.js" in text
    assert "playwright-image.txt" in text
    assert "--env HOME=/tmp" in text
    assert "corepack npm exec -- playwright test" in text
    assert "QT_QPA_PLATFORM: offscreen" in text
    assert "PYTHONPATH: windows-client" in text
    assert "if: always()" in text
    assert "needs: [python, web, windows]" in text
    for job in ("python", "web", "windows"):
        assert f"needs.{job}.result" in text
    assert text.count("== 'success'") == 3


def test_only_core_ci_is_active_while_eight_workflows_remain_inert() -> None:
    assert {path.name for path in ACTIVE.glob("*.yml")} == {"ci.yml"}
    assert len(list(INACTIVE.glob("*.yml"))) == 8
