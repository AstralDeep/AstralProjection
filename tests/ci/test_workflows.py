from pathlib import Path
import re
import stat

import pytest


ROOT = Path(__file__).resolve().parents[2]
ACTIVE = ROOT / ".github" / "workflows"
INACTIVE = ROOT / "workflows-disabled"
PYTHON_CI_LOCK = ROOT / "tooling" / "python-ci" / "requirements.lock.txt"
REVIEWED_GITLEAKS_FIXTURE_FINGERPRINTS = frozenset(
    {
        "330bc85d07cac8fabc5cf8e1f7d313d2eb47e7d8:windows-client/tests/test_remote_machines_surface.py:private-key:42",
        "330bc85d07cac8fabc5cf8e1f7d313d2eb47e7d8:windows-client/tests/test_win_agent_startup_gate.py:generic-api-key:121",
        "330bc85d07cac8fabc5cf8e1f7d313d2eb47e7d8:windows-client/tests/test_win_agent_startup_gate.py:generic-api-key:133",
        "330bc85d07cac8fabc5cf8e1f7d313d2eb47e7d8:windows-client/tests/test_win_agent_startup_gate.py:generic-api-key:201",
        "330bc85d07cac8fabc5cf8e1f7d313d2eb47e7d8:windows-client/tests/test_win_agent_inbound_auth.py:generic-api-key:124",
        "330bc85d07cac8fabc5cf8e1f7d313d2eb47e7d8:windows-client/tests/test_win_agent_inbound_auth.py:generic-api-key:267",
    }
)


def _job_ids(text: str) -> set[str]:
    jobs = text.partition("\njobs:\n")[2]
    assert jobs
    return set(re.findall(r"(?m)^  ([A-Za-z0-9_-]+):\s*$", jobs))


def _job_block(text: str, job_id: str) -> str:
    jobs = text.partition("\njobs:\n")[2]
    _, marker, remainder = jobs.partition(f"  {job_id}:\n")
    assert marker, job_id
    return re.split(r"(?m)^  [A-Za-z0-9_-]+:\s*$", remainder, maxsplit=1)[0]


def _step_block(job: str, step_name: str) -> str:
    _, marker, remainder = job.partition(f"      - name: {step_name}\n")
    assert marker, step_name
    return re.split(r"(?m)^      - ", remainder, maxsplit=1)[0]


def _assert_native_workflow_authority(name: str, text: str) -> None:
    permission_indents = re.findall(r"(?m)^([ \t]*)permissions\s*:", text)
    assert permission_indents == [""], (name, permission_indents)
    _, marker, after_permissions = text.partition("permissions:\n")
    assert marker, name
    permission_block = re.split(
        r"(?m)^(?=\S)", after_permissions, maxsplit=1
    )[0].strip()
    assert permission_block == "contents: read", (name, permission_block)
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


def _assert_core_trigger_and_python_coverage(text: str) -> None:
    triggers = text.partition("on:\n")[2].partition("\npermissions:\n")[0]
    push = triggers.partition("  push:\n")[2].partition("\n  pull_request:\n")[0]
    pull_request = triggers.partition("  pull_request:\n")[2]
    assert "branches: [main]" in push
    assert "branches: [main]" in pull_request

    python = _job_block(text, "python")
    assert "mkdir -p build/074/coverage" in python
    assert (
        "pytest -q -p no:cacheprovider "
        "--cov=astralprojection --cov=rote --cov=webrender "
        "--cov=scripts.merge_xccov_line_coverage --cov-branch "
        "--cov-report=xml:build/074/coverage/projection-python.xml"
    ) in python
    assert (
        "diff-cover build/074/coverage/projection-python.xml "
        "--compare-branch origin/main --fail-under=90"
    ) in python


def _assert_apple_platform_contract(apple: str) -> None:
    app_unit = _job_block(apple, "app-unit-tests")
    first_login = _job_block(apple, "first-login-ui")
    watch = _job_block(apple, "watch-continuity")
    apple_required = _job_block(apple, "apple-required")

    for setting in (
        'XCODE_VERSION: "26.6"',
        'XCODE_BUILD: "17F113"',
        'IOS_RUNTIME: "26.5"',
        'WATCHOS_RUNTIME: "26.5"',
    ):
        assert setting in apple
    for job_id in (
        "swift-lint",
        "core-tests",
        "app-unit-tests",
        "first-login-ui",
        "watch-continuity",
    ):
        job = _job_block(apple, job_id)
        assert "runs-on: macos-26" in job
        assert "name: Select exact Xcode" in job
        assert "${XCODE_VERSION}" in job
        assert "${XCODE_BUILD}" in job

    ios_destination = (
        'destination: "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5"'
    )
    macos_destination = 'destination: "platform=macOS"'
    ios_runtime_check = (
        'xcrun simctl list runtimes available | grep -F "iOS ${IOS_RUNTIME}"'
    )
    exporter = "python3 scripts/export_xccov_line_coverage.py"
    for job in (app_unit, first_login):
        assert ios_destination in job
        assert macos_destination in job
        assert ios_runtime_check in job
        assert job.count("CODE_SIGNING_ALLOWED=NO") == 1
        assert job.count("-enableCodeCoverage YES") == 1
        assert job.count(exporter) == 1
        assert "--platform '${{ matrix.slug }}'" in job

    app_unit_marker = _step_block(app_unit, "Publish app unit success marker")
    assert "name: apple-required-app-unit-${{ matrix.slug }}" in app_unit_marker
    assert "app-unit-${{ matrix.slug }}.ok" in app_unit
    first_login_marker = _step_block(first_login, "Publish first-login success marker")
    assert "name: apple-required-first-login-${{ matrix.slug }}" in first_login_marker
    assert "first-login-${{ matrix.slug }}.ok" in first_login

    assert "name: Required · watchOS 26.5 continuity coverage" in watch
    assert (
        'xcrun simctl list runtimes available | grep -F "watchOS ${WATCHOS_RUNTIME}"'
        in watch
    )
    assert "os.environ['WATCHOS_RUNTIME']" in watch
    assert "-scheme AstralWatch" in watch
    assert (
        '-destination "platform=watchOS Simulator,id=${{ steps.watch_sim.outputs.udid }}"'
        in watch
    )
    assert watch.count("CODE_SIGNING_ALLOWED=NO") == 1
    assert watch.count("-enableCodeCoverage YES") == 1
    assert watch.count(exporter) == 1
    assert "--platform watchos" in watch
    assert "--output \"$report\"" in watch

    download_action = (
        "uses: actions/download-artifact@"
        "d3f86a106a0bac45b974a628896c90dbdf5c8093"
    )
    marker_steps = {
        "Require iOS app-unit success": "apple-required-app-unit-ios",
        "Require macOS app-unit success": "apple-required-app-unit-macos",
        "Require iOS first-login success": "apple-required-first-login-ios",
        "Require macOS first-login success": "apple-required-first-login-macos",
    }
    for step_name, artifact_name in marker_steps.items():
        step = _step_block(apple_required, step_name)
        assert download_action in step
        assert f"name: {artifact_name}" in step

    assert "name: Check out candidate for source-bound coverage union" in apple_required
    assert "python3 scripts/merge_xccov_line_coverage.py" in apple_required
    for platform in ("ios", "macos"):
        assert f"name: apple-required-app-unit-{platform}-coverage" in apple_required
        assert f"name: apple-required-first-login-{platform}-coverage" in apple_required
        assert f"--platform {platform}" in apple_required
        assert (
            f"path: ${{{{ github.workspace }}}}/build/060/coverage/union-inputs/"
            f"{platform}/unit"
        ) in apple_required
        assert (
            f"path: ${{{{ github.workspace }}}}/build/060/coverage/union-inputs/"
            f"{platform}/ui"
        ) in apple_required
        assert (
            f'--unit-input "${{GITHUB_WORKSPACE}}/build/060/coverage/union-inputs/'
            f'{platform}/unit/'
            f'apple-{platform}-unit-xccov.json"'
        ) in apple_required
        assert (
            f'--ui-input "${{GITHUB_WORKSPACE}}/build/060/coverage/union-inputs/'
            f'{platform}/ui/'
            f'apple-{platform}-first-login-xccov.json"'
        ) in apple_required
        assert f'--output "${{COVERAGE_ROOT}}/apple-{platform}-xccov.json"' in apple_required
    assert "name: apple-required-platform-union-coverage" in apple_required
    assert '--repo "${GITHUB_WORKSPACE}"' in apple_required
    assert "${RUNNER_TEMP}/apple-coverage" not in apple_required
    assert "--input " not in apple_required


def test_core_ci_is_active_read_only_and_projection_owned() -> None:
    text = (ACTIVE / "ci.yml").read_text(encoding="utf-8")

    assert _job_ids(text) == {"python", "web", "windows", "required"}
    _assert_core_trigger_and_python_coverage(text)
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
    _assert_core_trigger_and_python_coverage(text)
    assert "python -m build" in text
    assert "python -m pip install --force-reinstall --no-deps dist/*.whl" in text
    assert 'python -c "import astralprojection, rote, webrender"' in text
    assert "test \"$(corepack npm --version)\" = \"11.16.0\"" in text
    assert "test:coverage-conversion:browser" in text
    assert "test:coverage-union" in text
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


def test_python_ci_invokes_pytest_as_a_module_for_top_level_scripts() -> None:
    python = _job_block((ACTIVE / "ci.yml").read_text(encoding="utf-8"), "python")

    assert "python -m pytest -q -p no:cacheprovider" in python


def test_gitleaks_history_exempts_only_reviewed_fixture_fingerprints() -> None:
    ignore = ROOT / ".gitleaksignore"

    fingerprints = {
        line for line in ignore.read_text(encoding="utf-8").splitlines() if line
    }

    assert fingerprints == REVIEWED_GITLEAKS_FIXTURE_FINGERPRINTS


def test_python_owner_jobs_use_hash_locked_ci_dependencies_and_build_constraint() -> None:
    text = (ACTIVE / "ci.yml").read_text(encoding="utf-8")
    lock = PYTHON_CI_LOCK.read_text(encoding="utf-8")

    requirements = re.findall(r"(?m)^[A-Za-z][A-Za-z0-9_.-]*==[^\s]+.*$", lock)
    assert requirements
    assert all("==" in line and "--hash=sha256:" in line for line in requirements)
    for package in (
        "chardet",
        "coverage",
        "diff-cover",
        "jinja2",
        "markupsafe",
        "pytest-cov",
        "tomli",
    ):
        assert re.search(rf"(?m)^{re.escape(package)}==[^\s]+.*--hash=sha256:", lock)

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


@pytest.mark.parametrize(
    ("needle", "replacement"),
    (
        ("  push:\n    branches: [main]\n", ""),
        ("--cov=webrender", "--cov=tests"),
        (
            "--cov=scripts.merge_xccov_line_coverage",
            "--cov=tests.test_merge_xccov_line_coverage",
        ),
        ("--cov-branch", ""),
        ("--compare-branch origin/main", "--compare-branch HEAD~1"),
        ("--fail-under=90", "--fail-under=89"),
    ),
)
def test_core_ci_rejects_trigger_or_python_coverage_weakening(
    needle: str,
    replacement: str,
) -> None:
    text = (ACTIVE / "ci.yml").read_text(encoding="utf-8")
    mutated = text.replace(needle, replacement, 1)
    assert mutated != text

    with pytest.raises(AssertionError):
        _assert_core_trigger_and_python_coverage(mutated)


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


@pytest.mark.parametrize("workflow_name", ("android-ci.yml", "apple-ci.yml"))
def test_native_ci_push_and_pull_request_watch_voice_075_fixture(workflow_name: str) -> None:
    text = (ACTIVE / workflow_name).read_text(encoding="utf-8")
    triggers = text.partition("on:\n")[2].partition("\npermissions:\n")[0]
    push = triggers.partition("  push:\n")[2].partition("\n  pull_request:\n")[0]
    pull_request = triggers.partition("  pull_request:\n")[2].partition("\n  schedule:\n")[0]
    path = "contracts/fixtures/voice_075/client_local_conformance.json"

    assert push.count(path) == 1
    assert pull_request.count(path) == 1


@pytest.mark.parametrize("workflow_name", ("android-ci.yml", "apple-ci.yml"))
@pytest.mark.parametrize("event_name", ("push", "pull_request"))
def test_native_ci_voice_075_path_guard_rejects_missing_event_filter(
    workflow_name: str,
    event_name: str,
) -> None:
    text = (ACTIVE / workflow_name).read_text(encoding="utf-8")
    path = "contracts/fixtures/voice_075/client_local_conformance.json"
    lines = text.splitlines(keepends=True)
    start = lines.index(f"  {event_name}:\n")
    end = next(
        (
            index
            for index in range(start + 1, len(lines))
            if lines[index].startswith("  ") and not lines[index].startswith("    ")
        ),
        len(lines),
    )
    event_path = next(
        index for index in range(start, end) if path in lines[index]
    )
    mutated = "".join(lines[:event_path] + lines[event_path + 1 :])

    triggers = mutated.partition("on:\n")[2].partition("\npermissions:\n")[0]
    push = triggers.partition("  push:\n")[2].partition("\n  pull_request:\n")[0]
    pull_request = triggers.partition("  pull_request:\n")[2].partition("\n  schedule:\n")[0]
    with pytest.raises(AssertionError):
        assert push.count(path) == 1 and pull_request.count(path) == 1


def test_native_ci_is_independently_read_only_secret_free_and_sha_pinned() -> None:
    workflows = {
        name: (ACTIVE / name).read_text(encoding="utf-8")
        for name in ("android-ci.yml", "apple-ci.yml")
    }

    for name, text in workflows.items():
        _assert_native_workflow_authority(name, text)


@pytest.mark.parametrize(
    ("workflow_name", "job_id"),
    (("android-ci.yml", "build-test"), ("apple-ci.yml", "swift-lint")),
)
@pytest.mark.parametrize(
    "mutation",
    ("top-level-write-all", "job-write-all", "inline-job-write"),
)
def test_native_ci_authority_rejects_write_escalations(
    workflow_name: str,
    job_id: str,
    mutation: str,
) -> None:
    text = (ACTIVE / workflow_name).read_text(encoding="utf-8")
    if mutation == "top-level-write-all":
        mutated = text.replace(
            "permissions:\n  contents: read",
            "permissions: write-all",
            1,
        )
    elif mutation == "job-write-all":
        mutated = text.replace(
            f"  {job_id}:\n",
            f"  {job_id}:\n    permissions: write-all\n",
            1,
        )
    else:
        mutated = text.replace(
            f"  {job_id}:\n",
            f"  {job_id}:\n    permissions: {{contents: write}}\n",
            1,
        )
    assert mutated != text

    with pytest.raises(AssertionError):
        _assert_native_workflow_authority(workflow_name, mutated)


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
    _assert_apple_platform_contract(apple)


@pytest.mark.parametrize(
    ("needle", "replacement"),
    (
        (
            'xcrun simctl list runtimes available | grep -F "watchOS ${WATCHOS_RUNTIME}"',
            'xcrun simctl list runtimes available | grep -F "iOS ${IOS_RUNTIME}"',
        ),
        (
            '-destination "platform=watchOS Simulator,id=${{ steps.watch_sim.outputs.udid }}"',
            '-destination "platform=iOS Simulator,id=${{ steps.watch_sim.outputs.udid }}"',
        ),
        ("--platform watchos \\", "--platform '${{ matrix.slug }}' \\"),
    ),
)
def test_apple_contract_rejects_watch_contract_moved_out_of_its_job(
    needle: str,
    replacement: str,
) -> None:
    apple = (ACTIVE / "apple-ci.yml").read_text(encoding="utf-8")
    mutated = apple.replace(needle, replacement, 1)
    assert mutated != apple

    with pytest.raises(AssertionError):
        _assert_apple_platform_contract(mutated)


def test_apple_contract_rejects_success_markers_swapped_between_matrix_jobs() -> None:
    apple = (ACTIVE / "apple-ci.yml").read_text(encoding="utf-8")
    app_marker = "name: apple-required-app-unit-${{ matrix.slug }}\n"
    first_login_marker = "name: apple-required-first-login-${{ matrix.slug }}\n"
    mutated = apple.replace(app_marker, "__APP_MARKER__", 1)
    mutated = mutated.replace(first_login_marker, app_marker, 1)
    mutated = mutated.replace("__APP_MARKER__", first_login_marker, 1)
    assert mutated != apple

    with pytest.raises(AssertionError):
        _assert_apple_platform_contract(mutated)


@pytest.mark.parametrize(
    ("needle", "replacement"),
    (
        ("--unit-input", "--input"),
        ("--ui-input", "--unit-input"),
        ("apple-required-app-unit-ios-coverage", "apple-required-first-login-ios-coverage"),
    ),
)
def test_apple_contract_rejects_unlabeled_missing_or_duplicate_coverage_producers(
    needle: str,
    replacement: str,
) -> None:
    apple = (ACTIVE / "apple-ci.yml").read_text(encoding="utf-8")
    mutated = apple.replace(needle, replacement, 1)
    assert mutated != apple

    with pytest.raises(AssertionError):
        _assert_apple_platform_contract(mutated)


def test_apple_contract_rejects_coverage_inputs_outside_candidate_checkout() -> None:
    apple = (ACTIVE / "apple-ci.yml").read_text(encoding="utf-8")
    mutated = apple.replace(
        "${{ github.workspace }}/build/060/coverage/union-inputs/ios/unit",
        "${{ runner.temp }}/apple-coverage/ios/unit",
        1,
    )
    assert mutated != apple

    with pytest.raises(AssertionError):
        _assert_apple_platform_contract(mutated)


def test_release_activation_document_matches_current_workflow_inventory() -> None:
    document = (ROOT / "docs" / "release-workflow-activation.md").read_text(
        encoding="utf-8"
    )
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    active = sorted(ACTIVE.glob("*.yml"))
    disabled = sorted(INACTIVE.glob("*.yml"))
    disabled_jobs = sum(len(_job_ids(path.read_text(encoding="utf-8"))) for path in disabled)

    assert len(active) == 3
    assert len(disabled) == 6
    assert disabled_jobs == 8
    assert "Three owner CI workflows are active under `.github/workflows/`" in document
    assert "six release workflows remain under `workflows-disabled/`" in document
    assert "all eight release jobs carry `if: ${{ false }}`" in document
    assert "There is no `.github/workflows/` directory" not in document
    assert "Nine YAML files" not in document
    assert "all 19 jobs" not in document
    assert "Three owner CI workflows are active and read-only/secret-free" in readme
    for workflow in ("ci.yml", "android-ci.yml", "apple-ci.yml"):
        assert f"`.github/workflows/{workflow}`" in readme
    assert "Six release workflows remain disabled under `workflows-disabled/`" in readme
    assert "Android and Apple workflows also remain inert" not in readme
    assert "Android, Apple, candidate, and release workflows" not in readme


@pytest.mark.parametrize(
    "replacement",
    (
        "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02",
        "",
    ),
    ids=("wrong-action", "removed-action"),
)
def test_apple_aggregate_rejects_missing_pinned_marker_download_action(
    replacement: str,
) -> None:
    apple = (ACTIVE / "apple-ci.yml").read_text(encoding="utf-8")
    download_action = (
        "actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093"
    )
    mutated = apple.replace(download_action, replacement, 1)
    assert mutated != apple

    with pytest.raises(AssertionError):
        _assert_apple_platform_contract(mutated)


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
