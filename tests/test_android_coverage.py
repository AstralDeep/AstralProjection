from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace

import pytest

from scripts import android_coverage as c


def put(path: Path, content: str | bytes = "fixture") -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content.encode() if isinstance(content, str) else content)
    return path


def replace_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value), encoding="utf-8")


@pytest.fixture
def prepared(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    root = tmp_path / "repo"
    app = root / "android-client/app"
    classes = app / "build/classes"
    put(classes / "Original.class")
    sources = app / "src/main/kotlin"
    put(sources / "Original.kt", "fun original() = 1")
    put(
        app / "src/androidTest/kotlin/SyntheticTest.kt",
        "class SyntheticTest {\n@Test fun works() {}\n}",
    )
    put(
        app / "src/androidTest/kotlin/ReleaseEvidenceInstrumentedTest.kt",
        "class ReleaseEvidenceInstrumentedTest {\n@Test fun stage() {}\n}",
    )
    for relative in [
        "scripts/android_coverage.py",
        "android-client/coverage-tools/ValidateClassIds.java",
        "contracts/fixtures/voice_065/client_conformance.json",
        "contracts/fixtures/voice_075/client_local_conformance.json",
        "backend/webrender/static/vendor/plotly.min.js",
    ]:
        put(root / relative)
    tool = put(tmp_path / "jacoco.jar")
    c.write_json(
        app / "build/coverage/inputs.json",
        {
            "version": "astral.android-coverage-inputs/v1",
            "agp": "9.2.1",
            "jacoco": "0.8.14",
            "variant": "coverage",
            "classes": [str(classes)],
            "sources": [str(sources), str(app / "src/coverage/kotlin")],
            "tools": [str(tool)],
        },
    )
    c.write_json(
        app / "build/coverage/unit-agent.json",
        {
            "count": 1,
            "engine": "jacoco",
            "version": "0.8.14",
            "task": ":app:testCoverageUnitTest",
            "agp_unit_coverage": False,
        },
    )
    put(
        app / "build/test-results/testCoverageUnitTest/TEST-unit.xml",
        '<testsuite tests="2" failures="0" errors="0" skipped="0"/>',
    )
    put(app / "build/kover/bin-reports/testCoverageUnitTest.exec", b"probes")
    put(app / "build/outputs/apk/coverage/app-coverage.apk", b"main apk")
    put(app / "build/outputs/apk/androidTest/coverage/app-coverage-androidTest.apk", b"test apk")
    monkeypatch.setattr(
        c,
        "validate_ids",
        lambda _r, _o, _m, execution: {
            "class_domain": 1,
            "mismatches": 0,
            "lanes": [{}] * len(execution),
        },
    )
    output = tmp_path / "outside-source-receipt"
    c.prepare(root, output)
    return root, output, tool


def device_stub(monkeypatch, root, output, *, failure=False, test_drift=False):
    manifest = c.read_json(output / "manifest.json")
    calls = []
    monkeypatch.setattr(c, "run", lambda args, **kw: calls.append(args) or "Success")
    monkeypatch.setattr(
        c,
        "installed_hash",
        lambda _a, _s, package=c.PACKAGE: (
            "drift"
            if test_drift and package.endswith(".test")
            else manifest["artifacts"][
                "app-coverage-androidTest.apk" if package.endswith(".test") else "app-coverage.apk"
            ]
        ),
    )

    def execute(args, **kwargs):
        calls.append(args)
        if "exec-out" in args:
            return SimpleNamespace(returncode=0, stdout=b"device probes", stderr=b"")
        text = "INSTRUMENTATION_STATUS_CODE: 1\nINSTRUMENTATION_STATUS_CODE: 0\nOK (1 test)\n"
        return SimpleNamespace(returncode=0, stdout="FAILURES!!!" if failure else text, stderr="")

    monkeypatch.setattr(c.subprocess, "run", execute)
    return calls


def collect_fixture(prepared, monkeypatch):
    root, output, _ = prepared
    calls = device_stub(monkeypatch, root, output)
    c.device(root, output, "adb", "emulator-5584", "fixtures", None)
    return root, output, calls


def test_prepare_preserves_complete_original_domain_and_copied_artifacts(prepared):
    root, output, _ = prepared
    manifest = c.verify_base(root, output)
    assert manifest["unit_tests"]["tests"] == 2
    assert manifest["fixture_count"] == 1
    assert manifest["fixture_classes"] == [c.PREFIX + "SyntheticTest"]
    assert len(manifest["class_files"]) == 1
    assert manifest["artifacts"]["unit.exec"] == c.digest(output / "unit.exec")
    with pytest.raises(c.InvalidCoverage, match="output_already_exists"):
        c.prepare(root, output)


@pytest.mark.parametrize("mode", ["remove", "add", "modify"])
def test_any_original_class_tree_drift_is_refused(prepared, mode):
    root, output, _ = prepared
    file = root / "android-client/app/build/classes/Original.class"
    if mode == "remove":
        file.unlink()
    elif mode == "add":
        put(file.with_name("Unloaded.class"))
    else:
        file.write_bytes(b"new bytecode")
    with pytest.raises(c.InvalidCoverage, match="class_domain_changed"):
        c.verify_base(root, output)


@pytest.mark.parametrize("kind", ["source", "new_source", "retained", "original_apk", "tool"])
def test_source_apk_exec_and_tool_changes_fail_closed(prepared, kind):
    root, output, tool = prepared
    paths = {
        "source": root / "android-client/app/src/main/kotlin/Original.kt",
        "new_source": root / "android-client/app/src/main/kotlin/Added.kt",
        "retained": output / "unit.exec",
        "original_apk": root / "android-client/app/build/outputs/apk/coverage/app-coverage.apk",
        "tool": tool,
    }
    put(paths[kind], "changed")
    with pytest.raises(c.InvalidCoverage):
        c.verify_base(root, output)


def test_source_tree_ignores_builds_and_private_signing_material(prepared):
    root, output, _ = prepared
    before = c.source_tree(root)
    put(root / "android-client/app/build/other.bin")
    put(root / "android-client/local.properties", "private sdk")
    put(root / "android-client/keystore.properties", "private signing")
    put(root / "android-client/private.jks", "private signing")
    assert c.source_tree(root) == before
    c.verify_base(root, output)


@pytest.mark.parametrize("kind", ["file", "parent", "outside"])
def test_symlink_and_escaped_inputs_are_refused(tmp_path, kind):
    root = tmp_path / "root"
    root.mkdir()
    target = put(tmp_path / "private", "not collected")
    if kind == "outside":
        path = target
    elif kind == "file":
        path = root / "link"
        path.symlink_to(target)
    else:
        (root / "folder").symlink_to(tmp_path, target_is_directory=True)
        path = root / "folder/private"
    with pytest.raises(c.InvalidCoverage):
        c.inside(root, path)


def test_device_receipt_binds_main_and_test_apk_and_raw_probes(prepared, monkeypatch):
    root, output, calls = collect_fixture(prepared, monkeypatch)
    manifest, execution, closure = c.verify(root, output, ["fixtures"])
    receipt = c.read_json(output / "fixtures.json")
    assert (
        receipt["installed_test_apk_sha256"]
        == manifest["artifacts"]["app-coverage-androidTest.apk"]
    )
    assert receipt["passed"] == 1 and receipt["skipped"] == 0
    assert execution == [output / "unit.exec", output / "fixtures.ec"]
    assert len(closure["lanes"]) == 2
    assert all(call[:3] == ["adb", "-s", "emulator-5584"] for call in calls)


def test_replaced_test_apk_refused_before_instrumentation(prepared, monkeypatch):
    root, output, _ = prepared
    calls = device_stub(monkeypatch, root, output, test_drift=True)
    with pytest.raises(c.InvalidCoverage, match="installed_test_apk_changed"):
        c.device(root, output, "adb", "emulator-5584", "fixtures", None)
    assert not any("am instrument" in str(call) for call in calls)


def test_failed_attempt_is_retained_and_never_replayed(prepared, monkeypatch):
    root, output, _ = prepared
    calls = device_stub(monkeypatch, root, output, failure=True)
    with pytest.raises(c.InvalidCoverage, match="device_tests_not_passed"):
        c.device(root, output, "adb", "emulator-5584", "fixtures", None)
    original = (output / "fixtures.log").read_bytes()
    previous = len(calls)
    with pytest.raises((c.InvalidCoverage, FileExistsError)):
        c.device(root, output, "adb", "emulator-5584", "fixtures", None)
    assert len(calls) == previous and (output / "fixtures.log").read_bytes() == original
    assert not (output / "fixtures.json").exists()


@pytest.mark.parametrize("suffix", ["json", "ec", "log", "started.json"])
def test_existing_or_dangling_lane_evidence_refuses_before_side_effects(
    prepared, monkeypatch, suffix
):
    root, output, _ = prepared
    (output / f"fixtures.{suffix}").symlink_to(output / "absent")
    calls = device_stub(monkeypatch, root, output)
    with pytest.raises((c.InvalidCoverage, FileExistsError)):
        c.device(root, output, "adb", "emulator-5584", "fixtures", None)
    assert not calls


@pytest.mark.parametrize("part", ["classes", "execution", "sources", "tools", "lanes"])
def test_reduced_native_input_domain_never_invokes_report(prepared, monkeypatch, part):
    root, output, _ = collect_fixture(prepared, monkeypatch)
    manifest, execution, _ = c.verify(root, output, ["fixtures"])
    native = c.native_inputs(root, manifest, execution, ["fixtures"])
    native[part] = []
    c.write_json(output / "native-report-inputs.json", native)
    calls = []
    monkeypatch.setattr(c, "run", lambda *args, **kw: calls.append(args))
    with pytest.raises(c.InvalidCoverage, match="native_report_inputs_changed"):
        c.report(root, output, ["fixtures"])
    assert not calls and not (output / "report").exists()


@pytest.mark.parametrize("mutate", ["raw", "log", "receipt", "missing"])
def test_changed_missing_or_overwritten_lane_refuses(prepared, monkeypatch, mutate):
    root, output, _ = collect_fixture(prepared, monkeypatch)
    if mutate == "raw":
        put(output / "fixtures.ec", "changed")
    elif mutate == "log":
        put(output / "fixtures.log", "changed")
    elif mutate == "missing":
        (output / "fixtures.ec").unlink()
    else:
        value = c.read_json(output / "fixtures.json")
        value["skipped"] = 1
        replace_json(output / "fixtures.json", value)
    with pytest.raises(c.InvalidCoverage):
        c.verify(root, output, ["fixtures"])


def test_native_report_is_unmodified_and_bound_to_inputs(prepared, monkeypatch):
    root, output, _ = collect_fixture(prepared, monkeypatch)
    xml = b'<report name="native"><package name=""><sourcefile name="Original.kt"><line nr="1" mi="0" ci="1"/><counter type="LINE" missed="0" covered="1"/></sourcefile></package></report>'
    calls = []

    def gradle(args, **kw):
        calls.append(args)
        put(output / "report/report.xml", xml)
        return "SUCCESS"

    monkeypatch.setattr(c, "run", gradle)
    c.report(root, output, ["fixtures"])
    assert (output / "report/report.xml").read_bytes() == xml
    assert len(calls) == 1 and ":app:coverageReport" in calls[0]
    assert not any("connected" in arg for arg in calls[0])
    assert c.read_json(output / "report.json")["protected_staging_included"] is False
    with pytest.raises(c.InvalidCoverage, match="report_already_exists"):
        c.report(root, output, ["fixtures"])


def staging_file(tmp_path):
    path = tmp_path / "private.json"
    values = {key: "example" for key in c.STAGING_KEYS}
    values["astralStagingUrl"] = "https://stage.example"
    values["astralAccessToken"] = "private $(not-executed) ' value"
    replace_json(path, values)
    path.chmod(0o600)
    return path


def test_real_staging_is_separate_and_private_args_are_quoted_not_receipted(
    prepared, monkeypatch, tmp_path
):
    root, output, _ = collect_fixture(prepared, monkeypatch)
    args = staging_file(tmp_path)
    calls = device_stub(monkeypatch, root, output)
    c.device(root, output, "adb", "emulator-5584", "staging", args)
    manifest, execution, _ = c.verify(root, output, ["fixtures", "staging"])
    assert len(execution) == 3
    assert not any("install" in call for call in calls)
    shell = next(call[-1] for call in calls if "am instrument" in call[-1])
    import shlex

    argv = shlex.split(shell)
    assert "private $(not-executed) ' value" in argv
    assert c.STAGING_CLASS in argv and ",".join(manifest["fixture_classes"]) not in argv
    assert "private" not in (output / "staging.json").read_text()


@pytest.mark.parametrize("kind", ["mode", "keys", "empty", "nul", "http"])
def test_invalid_staging_args_never_launch_device(prepared, monkeypatch, tmp_path, kind):
    root, output, _ = prepared
    path = staging_file(tmp_path)
    v = c.read_json(path)
    if kind == "mode":
        path.chmod(0o644)
    elif kind == "keys":
        v["class"] = "arbitrary"
    elif kind == "empty":
        v["astralAccessToken"] = ""
    elif kind == "nul":
        v["astralAccessToken"] = "bad\0"
    else:
        v["astralStagingUrl"] = "http://stage.example"
    replace_json(path, v)
    calls = device_stub(monkeypatch, root, output)
    with pytest.raises(c.InvalidCoverage):
        c.device(root, output, "adb", "emulator-5584", "staging", path)
    assert not calls


@pytest.mark.parametrize(
    "lanes", [[], ["fixtures", "fixtures"], ["unknown"], ["fixtures", "staging"]]
)
def test_missing_or_invalid_required_lanes_refused(prepared, lanes):
    root, output, _ = prepared
    with pytest.raises(c.InvalidCoverage):
        c.verify(root, output, lanes)


def test_installed_apk_digest_uses_validated_single_package_path(monkeypatch):
    monkeypatch.setattr(c, "run", lambda *_args, **_kw: "package:/data/app/abc/base.apk\n")
    monkeypatch.setattr(
        c.subprocess, "run", lambda *_args, **_kw: SimpleNamespace(returncode=0, stdout=b"apk")
    )
    import hashlib

    assert c.installed_hash("adb", "emulator-5584") == hashlib.sha256(b"apk").hexdigest()


@pytest.mark.parametrize(
    "result",
    [
        "",
        "package:/data/app/a/base.apk\npackage:/data/app/a/split.apk",
        "package:/data/app/a/$(bad).apk",
        "package:/tmp/base.apk",
    ],
)
def test_installed_apk_ambiguous_or_shell_paths_refused(monkeypatch, result):
    monkeypatch.setattr(c, "run", lambda *_args, **_kw: result)
    with pytest.raises(c.InvalidCoverage):
        c.installed_hash("adb", "emulator-5584")


@pytest.mark.parametrize("serial", ["", "bad;command", "a b", "x" * 129])
def test_serial_must_be_explicit_and_safe(serial):
    with pytest.raises(c.InvalidCoverage):
        c.adb_command("adb", serial, "devices")


def test_cli_failure_is_data_free(prepared, capsys):
    root, output, _ = prepared
    assert (
        c.main(["verify", "--root", str(root), "--output", str(output), "--lanes", "staging"]) == 1
    )
    assert capsys.readouterr().err == "android_coverage_failed\n"


def test_run_errors_never_echo_private_arguments(monkeypatch):
    monkeypatch.setattr(
        c.subprocess,
        "run",
        lambda *_args, **_kw: SimpleNamespace(returncode=1, stdout="private", stderr="private"),
    )
    with pytest.raises(c.InvalidCoverage, match="^subprocess_failed$"):
        c.run(["tool", "private"])


@pytest.mark.parametrize("mode", ["missing", "duplicate", "foreign", "foreign_nonempty"])
def test_report_domain_cannot_drop_or_invent_maintained_sources(prepared, mode):
    root, output, _ = prepared
    original = '<sourcefile name="Original.kt"><line nr="1" mi="0" ci="1"/></sourcefile>'
    contents = {
        "missing": "",
        "duplicate": original + original,
        "foreign": original
        + '<sourcefile name="Foreign.kt"><line nr="2" mi="1" ci="0"/></sourcefile>',
        "foreign_nonempty": original + '<sourcefile name="Empty.kt">hidden</sourcefile>',
    }[mode]
    xml = put(output / "domain.xml", '<report><package name="">' + contents + "</package></report>")
    with pytest.raises(c.InvalidCoverage):
        c.report_domain(root, xml, c.read_json(output / "manifest.json"))


def test_report_domain_accepts_only_truly_empty_external_inline_placeholders(prepared):
    root, output, _ = prepared
    xml = put(
        output / "domain.xml",
        '<report><package name=""><sourcefile name="Original.kt"><line nr="1" mi="0" ci="1"/><counter type="LINE" missed="0" covered="1"/></sourcefile><sourcefile name="LazyDsl.kt"/></package></report>',
    )
    result = c.report_domain(root, xml, c.read_json(output / "manifest.json"))
    assert result["maintained_sources"] == ["android-client/app/src/main/kotlin/Original.kt"]
    assert result["empty_external_sources"] == ["LazyDsl.kt"]
    assert result["executable_lines"] == result["covered_lines"] == 1


def test_native_collector_workflow_requires_prepared_exact_apks_all_fixtures_and_raw_artifacts():
    root = Path(__file__).resolve().parents[1]
    workflow = (root / ".github/workflows/android-ci.yml").read_text()
    instrumented = workflow.partition("  instrumented:\n")[2].partition("  android-required:\n")[0]
    assert ":app:prepareCoverageInputs" in instrumented
    assert "--serial emulator-5554 --lane fixtures" in instrumented
    assert "--lanes fixtures" in instrumented
    assert "android-app-device-and-unit-coverage" in instrumented
    assert "connectedDebugAndroidTest" not in instrumented
    assert "continue-on-error" not in instrumented
    assert "secrets." not in instrumented
    assert (
        instrumented.index(":app:prepareCoverageInputs")
        < instrumented.index("--lane fixtures")
        < instrumented.index("--lanes fixtures")
    )


@pytest.mark.parametrize("failed", [False, True])
def test_staging_secret_echo_is_redacted_before_persisting_any_log(
    prepared, monkeypatch, tmp_path, failed
):
    root, output, _ = prepared
    args = staging_file(tmp_path)
    values = c.read_json(args)
    token = values["astralAccessToken"]
    device_stub(monkeypatch, root, output)

    def execute(command, **kwargs):
        if "exec-out" in command:
            return SimpleNamespace(returncode=0, stdout=b"probes")
        result = (
            "FAILURES!!!"
            if failed
            else "INSTRUMENTATION_STATUS_CODE: 1\nINSTRUMENTATION_STATUS_CODE: 0\nOK (1 test)\n"
        )
        return SimpleNamespace(returncode=0, stdout=result + "\n" + token, stderr=json.dumps(token))

    monkeypatch.setattr(c.subprocess, "run", execute)
    if failed:
        with pytest.raises(c.InvalidCoverage, match="device_tests_not_passed"):
            c.device(root, output, "adb", "emulator-5584", "staging", args)
    else:
        c.device(root, output, "adb", "emulator-5584", "staging", args)
    for path in output.glob("staging.*"):
        content = path.read_text()
        assert token not in content and json.dumps(token)[1:-1] not in content
    assert "[REDACTED]" in (output / "staging.log").read_text()


def test_transport_timeout_does_not_expose_private_command_arguments(
    prepared, monkeypatch, tmp_path
):
    root, output, _ = prepared
    args = staging_file(tmp_path)
    device_stub(monkeypatch, root, output)

    def timeout(command, **kwargs):
        import subprocess

        raise subprocess.TimeoutExpired(command, 1800)

    monkeypatch.setattr(c.subprocess, "run", timeout)
    with pytest.raises(c.InvalidCoverage, match="^device_transport_failed$") as error:
        c.device(root, output, "adb", "emulator-5584", "staging", args)
    assert "private" not in str(error.value)
    assert c.read_json(output / "staging.failed.json")["status"] == "failed"


@pytest.mark.parametrize("failed", [False, True])
def test_duplicate_invocation_cannot_write_into_previous_attempt(prepared, monkeypatch, failed):
    root, output, _ = prepared
    device_stub(monkeypatch, root, output, failure=failed)
    if failed:
        with pytest.raises(c.InvalidCoverage):
            c.device(root, output, "adb", "emulator-5584", "fixtures", None)
    else:
        c.device(root, output, "adb", "emulator-5584", "fixtures", None)
    before = {p.name: p.read_bytes() for p in output.glob("fixtures.*")}
    with pytest.raises(c.InvalidCoverage, match="lane_already_collected"):
        c.device(root, output, "adb", "emulator-5584", "fixtures", None)
    assert {p.name: p.read_bytes() for p in output.glob("fixtures.*")} == before
    if not failed:
        c.verify(root, output, ["fixtures"])


def test_failure_from_other_attempt_cannot_contaminate_inflight_owner(prepared, monkeypatch):
    root, output, _ = prepared
    c.write_json(output / "fixtures.started.json", {"attempt_id": "another-owner"})
    before = (output / "fixtures.started.json").read_bytes()
    calls = device_stub(monkeypatch, root, output)
    with pytest.raises(c.InvalidCoverage):
        c.device(root, output, "adb", "emulator-5584", "fixtures", None)
    assert not calls and (output / "fixtures.started.json").read_bytes() == before
    assert not (output / "fixtures.failed.json").exists()


def test_contradictory_failure_marker_refuses_passed_receipt(prepared, monkeypatch):
    root, output, _ = collect_fixture(prepared, monkeypatch)
    c.write_json(output / "fixtures.failed.json", {"status": "failed"})
    with pytest.raises(c.InvalidCoverage, match="contradictory_failed_lane"):
        c.verify(root, output, ["fixtures"])


def test_empty_placeholder_cannot_replace_a_maintained_source(prepared):
    root, output, _ = prepared
    xml = put(
        output / "empty-original.xml",
        '<report><package name=""><sourcefile name="Original.kt"/></package></report>',
    )
    with pytest.raises(c.InvalidCoverage, match="maintained_source_missing_counter"):
        c.report_domain(root, xml, c.read_json(output / "manifest.json"))


def test_python_and_java_collector_lint_coverage_stay_in_ci():
    root = Path(__file__).resolve().parents[1]
    assert "--cov=scripts.android_coverage" in (root / ".github/workflows/ci.yml").read_text()
    source = (root / "scripts/android_coverage.py").read_text()
    assert '"-Xlint:all"' in source and '"-Werror"' in source
