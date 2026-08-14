"""Enforce AstralProjection's one-way dependency boundary."""

from __future__ import annotations

import ast
from pathlib import Path

import pytest

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SOURCE_ROOTS = (
    REPOSITORY_ROOT / "src" / "astralprojection",
    REPOSITORY_ROOT / "backend" / "webrender",
    REPOSITORY_ROOT / "backend" / "rote",
)
FORBIDDEN_IMPORT_ROOTS = {
    "agents",
    "astraldeep",
    "audit",
    "backend",
    "dreaming",
    "feedback",
    "llm_config",
    "onboarding",
    "orchestrator",
    "personalization",
    "scheduler",
    "shared",
    "voice_agent",
}


def _python_sources() -> list[Path]:
    return sorted(
        path
        for source_root in SOURCE_ROOTS
        if source_root.is_dir()
        for path in source_root.rglob("*.py")
    )


def _absolute_import_roots(path: Path) -> list[tuple[int, str]]:
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    importlib_names = {"importlib"}
    import_module_names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            importlib_names.update(
                alias.asname or "importlib" for alias in node.names if alias.name == "importlib"
            )
        elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module == "importlib":
            import_module_names.update(
                alias.asname or alias.name for alias in node.names if alias.name == "import_module"
            )
    roots: list[tuple[int, str]] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            roots.extend((node.lineno, alias.name.split(".", 1)[0]) for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
            roots.append((node.lineno, node.module.split(".", 1)[0]))
        elif isinstance(node, ast.Call):
            root = _literal_dynamic_import_root(
                node,
                importlib_names=importlib_names,
                import_module_names=import_module_names,
            )
            if root is not None:
                roots.append((node.lineno, root))
    return roots


def _literal_dynamic_import_root(
    node: ast.Call,
    *,
    importlib_names: set[str],
    import_module_names: set[str],
) -> str | None:
    """Return the absolute root from a literal dynamic import, if present."""

    is_builtin_import = isinstance(node.func, ast.Name) and node.func.id == "__import__"
    is_importlib_import = (
        isinstance(node.func, ast.Attribute)
        and isinstance(node.func.value, ast.Name)
        and node.func.value.id in importlib_names
        and node.func.attr == "import_module"
    )
    is_import_module_alias = isinstance(node.func, ast.Name) and node.func.id in import_module_names
    if not (is_builtin_import or is_importlib_import or is_import_module_alias):
        return None

    candidate: ast.expr | None = node.args[0] if node.args else None
    if candidate is None:
        candidate = next(
            (keyword.value for keyword in node.keywords if keyword.arg == "name"),
            None,
        )
    if not isinstance(candidate, ast.Constant) or not isinstance(candidate.value, str):
        return None
    if not candidate.value or candidate.value.startswith("."):
        return None
    return candidate.value.split(".", 1)[0]


@pytest.mark.parametrize(
    ("source", "expected"),
    [
        ('import importlib\nimportlib.import_module("backend.shared")\n', [(2, "backend")]),
        ('__import__(name="shared.database")\n', [(1, "shared")]),
        (
            'import importlib as il\nil.import_module("orchestrator.runtime")\n',
            [(2, "orchestrator")],
        ),
        (
            'from importlib import import_module as load\nload("personalization.store")\n',
            [(2, "personalization")],
        ),
    ],
)
def test_literal_dynamic_imports_are_included_in_the_boundary_scan(
    tmp_path: Path,
    source: str,
    expected: list[tuple[int, str]],
) -> None:
    path = tmp_path / "dynamic_import.py"
    path.write_text(source, encoding="utf-8")

    found = [item for item in _absolute_import_roots(path) if item[1] in FORBIDDEN_IMPORT_ROOTS]

    assert found == expected


@pytest.mark.parametrize(
    "source",
    [
        'import importlib\nname = "backend.shared"\nimportlib.import_module(name)\n',
        'factory.import_module("backend.shared")\n',
        'importlib.import_module(".backend", package="astralprojection")\n',
    ],
)
def test_nonliteral_or_relative_dynamic_imports_do_not_create_false_roots(
    tmp_path: Path,
    source: str,
) -> None:
    path = tmp_path / "allowed_dynamic_import.py"
    path.write_text(source, encoding="utf-8")

    found = [item for item in _absolute_import_roots(path) if item[1] in FORBIDDEN_IMPORT_ROOTS]

    assert found == []


def test_projection_does_not_import_deep_implementation_packages() -> None:
    sources = _python_sources()
    assert sources, "AstralProjection source inventory is unexpectedly empty"

    violations = [
        f"{path.relative_to(REPOSITORY_ROOT).as_posix()}:{line}: {root}"
        for path in sources
        for line, root in _absolute_import_roots(path)
        if root in FORBIDDEN_IMPORT_ROOTS
    ]

    if violations:
        pytest.fail(
            "AstralProjection must consume host-neutral inputs instead of AstralDeep "
            "implementation packages:\n" + "\n".join(sorted(violations))
        )
