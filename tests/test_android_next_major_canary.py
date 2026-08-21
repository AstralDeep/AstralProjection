"""Standalone contracts for AstralProjection's isolated Android canary."""

from __future__ import annotations

import ast
import importlib.util
import json
from pathlib import Path
import sys
from types import ModuleType

import pytest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "run_android_next_major_canary.py"
PINS = ROOT / "android-client" / "gradle" / "next-major-canary.properties"
ANDROID = ROOT / "android-client"


def _load_driver() -> ModuleType:
    spec = importlib.util.spec_from_file_location("projection_android_next_major", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


driver = _load_driver()


def test_canary_driver_is_stdlib_only_and_exposes_documented_gates() -> None:
    tree = ast.parse(SCRIPT.read_text(encoding="utf-8"), filename=str(SCRIPT))
    imported: set[str] = set()
    functions: dict[str, ast.FunctionDef] = {}
    for node in tree.body:
        if isinstance(node, ast.Import):
            imported.update(alias.name.partition(".")[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module:
            imported.add(node.module.partition(".")[0])
        elif isinstance(node, ast.FunctionDef):
            functions[node.name] = node
    imported.discard("__future__")
    public_gates = {
        "load_pins",
        "inspect_shipping_toolchain",
        "verify_migration_blockers_removed",
        "probe_official_availability",
        "run_canary",
        "main",
    }

    assert imported <= sys.stdlib_module_names
    assert public_gates <= functions.keys()
    assert all(ast.get_docstring(functions[name]) for name in public_gates)


def test_repository_declaration_and_shipping_tree_are_internally_consistent() -> None:
    pins = driver.load_pins(PINS)
    shipping = driver.inspect_shipping_toolchain(ANDROID)

    assert pins.availability == "unreleased"
    assert (pins.agp_major, pins.gradle_major) == (10, 10)
    assert pins.agp_version is pins.gradle_version is None
    assert shipping.agp_version != "UNRELEASED"
    assert shipping.gradle_version != "UNRELEASED"
    driver.verify_migration_blockers_removed(ANDROID)


def test_unreleased_canary_fails_closed_without_leaving_an_isolated_copy(
    tmp_path: Path,
) -> None:
    with pytest.raises(driver.CanaryUnavailable) as unavailable:
        driver.run_canary(PINS, source_root=ANDROID, temp_parent=tmp_path)

    assert unavailable.value.code == "toolchain_unreleased"
    assert list(tmp_path.iterdir()) == []


@pytest.mark.parametrize(
    ("agp_versions", "gradle_versions", "expected"),
    [
        (
            ["10.0.0-alpha01", "10.0.0-rc01"],
            ["10.0.0-milestone-1"],
            {"agp_major_available": False, "gradle_major_available": False},
        ),
        (
            ["10.0.0"],
            ["10.0.1"],
            {"agp_major_available": True, "gradle_major_available": True},
        ),
    ],
)
def test_official_probe_accepts_only_stable_target_major_releases(
    agp_versions: list[str],
    gradle_versions: list[str],
    expected: dict[str, bool],
) -> None:
    pins = driver.load_pins(PINS)

    def fetch(url: str) -> bytes:
        if "maven-metadata" in url:
            members = "".join(f"<version>{version}</version>" for version in agp_versions)
            return f"<metadata><versioning><versions>{members}</versions></versioning></metadata>".encode()
        return json.dumps([{"version": version} for version in gradle_versions]).encode()

    assert driver.probe_official_availability(pins, fetcher=fetch) == expected


def test_stable_target_majors_make_the_unreleased_declaration_stale() -> None:
    pins = driver.load_pins(PINS)

    with pytest.raises(driver.CanaryConfigError) as stale:
        driver.validate_unreleased_declaration(
            pins,
            {"agp_major_available": True, "gradle_major_available": True},
        )

    assert stale.value.code == "unreleased_declaration_stale"


def test_known_gradle_ten_removal_blockers_are_rejected(tmp_path: Path) -> None:
    source = tmp_path / "android-client"
    (source / "app").mkdir(parents=True)
    for relative, content in {
        "gradle.properties": "android.builtInKotlin=false\n",
        "settings.gradle.kts": 'enableFeaturePreview("TYPESAFE_PROJECT_ACCESSORS")\n',
        "build.gradle.kts": "plugins {}\n",
        "app/build.gradle.kts": "dependencies { implementation(projects.core) }\n",
    }.items():
        target = source / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")

    with pytest.raises(driver.CanaryConfigError) as blocked:
        driver.verify_migration_blockers_removed(source)

    assert blocked.value.code == "known_removal_blocker"
