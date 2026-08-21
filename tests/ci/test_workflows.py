from pathlib import Path
import re
import stat


ROOT = Path(__file__).resolve().parents[2]
ACTIVE = ROOT / ".github" / "workflows"
INACTIVE = ROOT / "workflows-disabled"
PYTHON_CI_LOCK = ROOT / "tooling" / "python-ci" / "requirements.lock.txt"


def _job_ids(text: str) -> set[str]:
    jobs = text.partition("\njobs:\n")[2]
    assert jobs
    return set(re.findall(r"(?m)^  ([A-Za-z0-9_-]+):\s*$", jobs))


def _job_block(text: str, job_id: str) -> str:
    jobs = text.partition("\njobs:\n")[2]
    _, marker, remainder = jobs.partition(f"  {job_id}:\n")
    assert marker, job_id
    return re.split(r"(?m)^  [A-Za-z0-9_-]+:\s*$", remainder, maxsplit=1)[0]


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
    assert "python -m pip install --force-reinstall --no-deps dist/*.whl" in text
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


def test_python_owner_jobs_use_hash_locked_ci_dependencies_and_build_constraint() -> None:
    text = (ACTIVE / "ci.yml").read_text(encoding="utf-8")
    lock = PYTHON_CI_LOCK.read_text(encoding="utf-8")

    requirements = re.findall(r"(?m)^[A-Za-z][A-Za-z0-9_.-]*==[^\s]+.*$", lock)
    assert requirements
    assert all("==" in line and "--hash=sha256:" in line for line in requirements)

    install = "python -m pip install --require-hashes -r tooling/python-ci/requirements.lock.txt"
    for job_id in ("python", "windows"):
        job = _job_block(text, job_id)
        assert install in job
        assert "python -m pip install --no-deps --no-build-isolation ." in job
        assert ".[dev]" not in job

    python_job = _job_block(text, "python")
    assert "PIP_CONSTRAINT=tooling/python-ci/requirements.lock.txt python -m build" in python_job
    assert 'requires = ["setuptools==80.10.2"]' in (ROOT / "pyproject.toml").read_text(
        encoding="utf-8"
    )


def test_native_ci_is_active_and_uses_standalone_paths() -> None:
    android = (ACTIVE / "android-ci.yml").read_text(encoding="utf-8")
    apple = (ACTIVE / "apple-ci.yml").read_text(encoding="utf-8")

    assert _job_ids(android) == {
        "build-test",
        "next-major-readiness",
        "instrumented",
        "android-required",
    }
    assert _job_ids(apple) == {
        "swift-lint",
        "core-tests",
        "app-unit-tests",
        "first-login-ui",
        "watch-continuity",
        "apple-required",
    }
    assert "components/AstralProjection/" not in android + apple
    assert "if: ${{ false }}" not in android + apple
    assert (
        "github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'"
        in android
    )


def test_apple_ci_runs_when_its_coverage_exporter_changes() -> None:
    apple = (ACTIVE / "apple-ci.yml").read_text(encoding="utf-8")
    triggers = apple.partition("on:\n")[2].partition("\npermissions:\n")[0]
    push = triggers.partition("  push:\n")[2].partition("\n  pull_request:\n")[0]
    pull_request = triggers.partition("  pull_request:\n")[2]

    assert '- "scripts/**"' in push
    assert '- "scripts/**"' in pull_request


def test_native_ci_is_independently_read_only_secret_free_and_sha_pinned() -> None:
    workflows = {
        name: (ACTIVE / name).read_text(encoding="utf-8")
        for name in ("android-ci.yml", "apple-ci.yml")
    }

    for name, text in workflows.items():
        assert re.search(r"(?m)^permissions:\n  contents: read(?:\s|$)", text), name
        assert not re.search(r"(?m)^\s+[A-Za-z0-9_-]+:\s*write(?:\s|#|$)", text), name
        assert not re.search(r"\bsecrets?\b", text, flags=re.IGNORECASE), name
        assert "id-token:" not in text, name
        uses = re.findall(r"(?m)^\s*(?:-\s*)?uses:\s*([^\s#]+)", text)
        assert uses, name
        for action in uses:
            if action.startswith("./"):
                continue
            _, separator, ref = action.rpartition("@")
            assert separator and re.fullmatch(r"[0-9a-f]{40}", ref), (name, action)


def test_android_ci_preserves_exact_hosted_emulator_and_wrapper_contract() -> None:
    android = (ACTIVE / "android-ci.yml").read_text(encoding="utf-8")
    instrumented = _job_block(android, "instrumented")

    assert android.count("./gradlew ") == 6
    assert not re.search(r"(?m)^\s+(?:run|script):\s+gradle(?:\s|$)", android)
    assert 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' in instrumented
    assert "sudo udevadm control --reload-rules" in instrumented
    assert "sudo udevadm trigger --name-match=kvm" in instrumented
    assert "api-level: 34" in instrumented
    assert "arch: x86_64" in instrumented
    assert "working-directory: android-client" in instrumented
    assert (
        "script: ./gradlew :app:connectedDebugAndroidTest --no-daemon --stacktrace"
        in instrumented
    )


def test_apple_ci_preserves_exact_platform_coverage_and_marker_contract() -> None:
    apple = (ACTIVE / "apple-ci.yml").read_text(encoding="utf-8")
    apple_required = _job_block(apple, "apple-required")

    for setting in (
        'XCODE_VERSION: "26.6"',
        'XCODE_BUILD: "17F113"',
        'IOS_RUNTIME: "26.5"',
        'WATCHOS_RUNTIME: "26.5"',
        'destination: "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5"',
        'destination: "platform=macOS"',
    ):
        assert setting in apple
    assert apple.count("runs-on: macos-26") == 5
    assert apple.count("name: Select exact Xcode") == 5
    assert apple.count("CODE_SIGNING_ALLOWED=NO") == 3
    assert apple.count("-enableCodeCoverage YES") == 3
    assert apple.count("python3 scripts/export_xccov_line_coverage.py") == 3

    for marker in (
        "apple-required-app-unit-${{ matrix.slug }}",
        "apple-required-first-login-${{ matrix.slug }}",
        "apple-required-app-unit-ios",
        "apple-required-app-unit-macos",
        "apple-required-first-login-ios",
        "apple-required-first-login-macos",
    ):
        assert marker in apple
    for marker in (
        "apple-required-app-unit-ios",
        "apple-required-app-unit-macos",
        "apple-required-first-login-ios",
        "apple-required-first-login-macos",
    ):
        assert f"name: {marker}" in apple_required


def test_android_ci_wrapper_is_committed_executable() -> None:
    wrapper_mode = (ROOT / "android-client" / "gradlew").stat().st_mode

    assert wrapper_mode & stat.S_IXUSR


def test_native_ci_aggregates_run_fail_closed_after_required_jobs() -> None:
    android = (ACTIVE / "android-ci.yml").read_text(encoding="utf-8")
    apple = (ACTIVE / "apple-ci.yml").read_text(encoding="utf-8")
    android_required = _job_block(android, "android-required")
    apple_required = _job_block(apple, "apple-required")

    assert "if: ${{ always() }}" in android_required
    assert "needs:\n      - build-test\n      - instrumented" in android_required
    assert "next-major-readiness" not in android_required
    assert "if: ${{ always() }}" in apple_required
    assert "needs:\n      - swift-lint\n      - core-tests" in apple_required
    for job_id in (
        "swift-lint",
        "core-tests",
        "app-unit-tests",
        "first-login-ui",
        "watch-continuity",
    ):
        assert f"needs.{job_id}.result" in apple_required


def test_three_owner_workflows_are_active_while_six_release_workflows_remain_inert() -> None:
    assert {path.name for path in ACTIVE.glob("*.yml")} == {
        "android-ci.yml",
        "apple-ci.yml",
        "ci.yml",
    }
    assert len(list(INACTIVE.glob("*.yml"))) == 6
