"""Tests for the xccov exporter and its native-domain policy (scripts/native_xccov_domain.py)
against real Git sources and stubbed tool bytes: raw counters and source identities survive
the CLI, discarded subranges keep their unsigned 64-bit bound, and denials leave no output.
"""

from __future__ import annotations

import json
import subprocess

import pytest

from scripts import export_xccov_line_coverage as exporter
from scripts import native_xccov_domain as policy


@pytest.fixture
def native_export(tmp_path, monkeypatch):
    repo = tmp_path / "repo"
    repo.mkdir()
    paths = [policy.APP_ROOT + "Example.swift", policy.CORE_ROOT + "Core.swift"]
    for path in paths:
        source = repo / path
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_bytes(b"enum Example {\n let value = 1\n}\n")
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
    subprocess.run(["git", "-C", str(repo), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "source"], check=True)
    bundle = repo / "build/result.xcresult"
    bundle.mkdir(parents=True)
    domain = policy.make_domain(
        geometry={path: {"native_last_line": 2, "geometry_sha256": policy.sha256(path.encode())} for path in paths},
        source_bytes=lambda path: (repo / path).read_bytes(),
        binary={"member": policy.BINARY_MEMBERS["app"], "sha256": "a" * 64, "artifact_sha256": "b" * 64,
                "artifact_member": "coverage/native-binaries/apple-ios-unit.zip"},
        observed_sources=paths, prefix="", lane="unit",
    )
    original = exporter._bounded_command
    rows = [{"line": 1, "isExecutable": False}, {"line": 2, "isExecutable": True, "executionCount": 7}]
    def run(command, **kwargs):
        if command[0] == "git":
            return original(command, **kwargs)
        if "--file-list" in command:
            return (str(repo / paths[0]) + "\n").encode()
        path = command[command.index("--file") + 1]
        return json.dumps({path: rows}).encode()
    monkeypatch.setattr(exporter, "_bounded_command", run)
    return repo, bundle, paths, domain, rows


def test_cli_keeps_raw_counter_rows_and_all_mapped_source_identities(native_export):
    repo, bundle, paths, domain, rows = native_export
    declaration = repo / "build/domain.json"
    declaration.write_text(json.dumps(domain))
    output = repo / "build/output.json"
    assert exporter.main(["--repo", str(repo), "--xcresult", str(bundle), "--platform", "ios", "--native-domain", str(declaration), "--output", str(output)]) == 0
    value = json.loads(output.read_text())
    assert value["coverage"] == {paths[0]: rows}
    assert value["domains"]["unit"]["observed_sources"] == [paths[0]]
    assert set(value["domains"]["unit"]["sources"]) == set(paths)
    assert all(facts["physical_lines"] == 3 for facts in value["domains"]["unit"]["sources"].values())
    assert len(value["coverage"][paths[0]]) == 2


@pytest.mark.parametrize("mutation", ["prefix", "short", "hole", "source", "platform", "missing_app", "counter", "size"])
def test_native_export_denials_leave_no_output(native_export, monkeypatch, mutation):
    repo, bundle, paths, domain, rows = native_export
    platform = "ios"
    if mutation == "prefix":
        domain["source_prefix"] = "components/AstralProjection/"
    elif mutation == "short":
        rows.pop()
    elif mutation == "hole":
        rows.pop(0)
    elif mutation == "source":
        (repo / paths[1]).write_bytes(b"private changed source\n")
    elif mutation == "platform":
        platform = "macos"
    elif mutation == "missing_app":
        extra = paths[0].replace("Example.swift", "Other.swift")
        (repo / extra).write_bytes((repo / paths[0]).read_bytes())
        domain["sources"][extra] = dict(domain["sources"][paths[0]])
        domain["observed_sources"] = sorted([*paths, extra])
    elif mutation == "counter":
        rows[-1]["executionCount"] = True
    else:
        monkeypatch.setattr(exporter, "MAX_OUTPUT_BYTES", 500)
    output = repo / "build/output.json"
    with pytest.raises(exporter.ExportError):
        exporter.export_xccov(repo=repo, xcresult=bundle, output=output, platform=platform, native_domain=domain)
    assert not output.exists()


_ARCHIVE_SOURCE = "/checkout/" + policy.APP_ROOT + "Example.swift"


def _observations(subranges=None, count=7):
    row = {"line": 2, "isExecutable": True, "executionCount": count}
    if subranges is not None:
        row["subranges"] = subranges
    return json.dumps({_ARCHIVE_SOURCE: [{"line": 1, "isExecutable": False}, row]}).encode()


@pytest.mark.parametrize("field", ["column", "executionCount", "length"])
def test_unsigned_64_bit_subranges_leave_exported_lines_unchanged(native_export, field):
    repo, bundle, paths, _domain, rows = native_export
    plain = repo / "build/plain.json"
    exporter.export_xccov(repo=repo, xcresult=bundle, output=plain, platform="ios")
    subrange = {"column": 18, "executionCount": 0, "length": 0, field: 2**64 - 1}
    rows[-1]["subranges"] = [subrange]
    wrapped = repo / "build/wrapped.json"
    exporter.export_xccov(repo=repo, xcresult=bundle, output=wrapped, platform="ios")
    assert wrapped.read_bytes() == plain.read_bytes()
    assert json.loads(wrapped.read_text()) == {
        paths[0]: [{"line": 1, "isExecutable": False}, {"line": 2, "isExecutable": True, "executionCount": 7}]
    }


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("executionCount", 2**64),
        ("column", 2**64),
        ("length", 2**64),
        ("executionCount", -1),
        ("column", 1.5),
        ("length", "7"),
        ("executionCount", True),
        ("column", None),
    ],
)
def test_subrange_integers_outside_unsigned_64_bits_are_refused_where_they_occur(field, value):
    subrange = {"column": 18, "executionCount": 0, "length": 0, field: value}
    with pytest.raises(exporter.ExportError) as refused:
        exporter._normalize_observations(
            _observations([subrange]), queried_path=_ARCHIVE_SOURCE, maximum_lines=3
        )
    assert refused.value.code == "invalid_observation"
    assert _ARCHIVE_SOURCE in refused.value.message
    assert "line 2" in refused.value.message
    assert f"subrange {field}" in refused.value.message


def test_line_execution_counts_keep_their_signed_64_bit_bound():
    accepted = exporter._normalize_observations(
        _observations(count=2**63 - 1), queried_path=_ARCHIVE_SOURCE, maximum_lines=3
    )
    assert accepted[-1]["executionCount"] == 2**63 - 1
    with pytest.raises(exporter.ExportError) as refused:
        exporter._normalize_observations(
            _observations(count=2**63), queried_path=_ARCHIVE_SOURCE, maximum_lines=3
        )
    assert refused.value.code == "invalid_observation"
    assert _ARCHIVE_SOURCE in refused.value.message
    assert "line 2" in refused.value.message
    assert "executionCount" in refused.value.message


@pytest.mark.parametrize(
    "subranges",
    [
        {"column": 18, "executionCount": 0, "length": 0},
        [{"column": 18, "executionCount": 0, "length": 0}] * (exporter.MAX_SUBRANGES_PER_LINE + 1),
        [[18, 0, 0]],
        [{"column": 18, "executionCount": 0}],
        [{"column": 18, "executionCount": 0, "length": 0, "count": 0}],
    ],
)
def test_malformed_subranges_are_refused_where_they_occur(subranges):
    with pytest.raises(exporter.ExportError) as refused:
        exporter._normalize_observations(
            _observations(subranges), queried_path=_ARCHIVE_SOURCE, maximum_lines=3
        )
    assert refused.value.code == "invalid_observation"
    assert f"{_ARCHIVE_SOURCE} line 2" in refused.value.message
