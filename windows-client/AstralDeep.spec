# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec for the AstralDeep native Windows client (single-file .exe).

Build (from windows-client/, in the venv):
    .venv/Scripts/pyinstaller --noconfirm AstralDeep.spec
Output: dist/AstralDeep.exe
"""
import pathlib
import re
import hashlib
import json
import os
import sys

from PyInstaller.utils.hooks import (
    collect_data_files,
    collect_dynamic_libs,
    collect_submodules,
)
from PyInstaller.utils.win32.versioninfo import (
    FixedFileInfo, StringFileInfo, StringStruct, StringTable, VarFileInfo,
    VarStruct, VSVersionInfo,
)

sys.path.insert(0, str(pathlib.Path(SPECPATH)))
from astral_client.deployment import (
    resolve_effective_profile,
    validate_packaged_deployment,
)

# Read the version textually: the exec'd spec cannot rely on importing the package
__version__ = re.search(
    r'__version__\s*=\s*"([^"]+)"',
    (pathlib.Path(SPECPATH) / "astral_client" / "__init__.py").read_text(encoding="utf-8"),
).group(1)

_root = pathlib.Path(SPECPATH)
from astral_client.freeze_environment import freeze_environment

_freeze_environment = freeze_environment()
os.environ.clear()
os.environ.update(_freeze_environment)
_profile_path = _root / "deployment" / "release-profile.json"
_runtime_manifest_path = _root / "deployment" / "runtime-manifest.json"
_release_lock_path = _root / "requirements-release.lock.txt"
_requirements_input_path = _root / "requirements.in"
_helper_path = _root / "asr-helper" / "publish" / "AstralSpeechHelper.exe"
_helper_provenance_path = _root / "asr-helper" / "publish" / "helper-build-provenance.json"
_helper_source_manifest_path = _root / "asr-helper" / "helper-source-hashes.json"
_console_font_path = _root.parent / "contracts" / "assets" / "fonts" / "open-sans-latin.ttf"
_console_font_license_path = _root.parent / "apple-clients" / "NativeAppearance" / "Resources" / "OpenSans-OFL.txt"
for _required in (
    _profile_path,
    _runtime_manifest_path,
    _release_lock_path,
    _requirements_input_path,
    _helper_path,
    _helper_provenance_path,
    _helper_source_manifest_path,
    _console_font_path,
    _console_font_license_path,
):
    if not _required.is_file():
        raise SystemExit(f"required Windows release input is missing: {_required.name}")

_profile = json.loads(_profile_path.read_text(encoding="utf-8"))
_manifest = json.loads(_runtime_manifest_path.read_text(encoding="utf-8"))
_profile_canonical = json.dumps(
    _profile, sort_keys=True, separators=(",", ":"), ensure_ascii=False
).encode("utf-8")
def _sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _matches_sha256(value, path):
    return (
        isinstance(value, str)
        and re.fullmatch(r"[0-9A-Fa-f]{64}", value) is not None
        and value.lower() == _sha256(path)
    )


_helper_provenance = json.loads(_helper_provenance_path.read_text(encoding="utf-8-sig"))
if set(_helper_provenance) != {
    "schema_version", "source_manifest_sha256", "executable_sha256"
} or _helper_provenance.get("schema_version") != 1:
    raise SystemExit("helper build provenance is invalid")
if not _matches_sha256(
    _helper_provenance.get("source_manifest_sha256"), _helper_source_manifest_path
):
    raise SystemExit("helper build provenance is invalid")
if not _matches_sha256(_helper_provenance.get("executable_sha256"), _helper_path):
    raise SystemExit("helper build provenance is invalid")

# A PYZ constant module, not a data file beside the helper, so it cannot be swapped with it
_helper_sha256 = _sha256(_helper_path)
_helper_digest_module_name = "_astral_helper_integrity_expected"
_helper_digest_module_root = _root / "build" / "generated-helper-integrity"
_helper_digest_module_path = _helper_digest_module_root / (
    f"{_helper_digest_module_name}.py"
)
_helper_digest_module_source = (
    '"""Generated at freeze time from the exact bundled helper bytes."""\n'
    f'EXPECTED_HELPER_SHA256 = "{_helper_sha256}"\n'
)
_helper_digest_module_root.mkdir(parents=True, exist_ok=True)
_helper_digest_module_path.write_text(
    _helper_digest_module_source, encoding="utf-8", newline="\n"
)
if (
    _helper_digest_module_path.read_text(encoding="utf-8")
    != _helper_digest_module_source
    or re.fullmatch(r"[0-9a-f]{64}", _helper_sha256) is None
):
    raise SystemExit("generated helper integrity module is invalid")


if __version__ != "0.6.0" or _profile.get("client_version") != __version__:
    raise SystemExit("Windows release profile and client version must both be 0.6.0")
if _manifest.get("client_version") != __version__:
    raise SystemExit("Windows runtime manifest version does not match the client")
if _manifest.get("release_id") != _profile.get("release_id"):
    raise SystemExit("Windows profile/runtime release identities disagree")
if _manifest.get("deployment_profile_sha256") != hashlib.sha256(_profile_canonical).hexdigest():
    raise SystemExit("Windows release profile is not the reviewed manifest input")
if _manifest.get("requirements_lock_sha256") != _sha256(_release_lock_path):
    raise SystemExit("Windows release lock digest does not match the runtime manifest")
if _manifest.get("requirements_input_sha256") != _sha256(_requirements_input_path):
    raise SystemExit("Windows direct-requirements digest does not match the runtime manifest")
if _manifest.get("required_runtime_lock_sha256") != _sha256(_release_lock_path):
    raise SystemExit("Windows BYO runtime is not bound to the final release lock")

# The frozen executable's own validation runs before Analysis so bad inputs yield no candidate
_effective_profile = resolve_effective_profile(
    bundled_profile_path=_profile_path,
    expected_client_version=__version__,
    environment={},
)
validate_packaged_deployment(
    _effective_profile,
    runtime_manifest_path=_runtime_manifest_path,
    requirements_lock_path=_release_lock_path,
    requirements_input_path=_requirements_input_path,
    expected_client_version=__version__,
)

_ver_tuple = tuple(int(p) for p in __version__.split(".")[:3]) + (0,)
version_res = VSVersionInfo(
    ffi=FixedFileInfo(filevers=_ver_tuple, prodvers=_ver_tuple),
    kids=[
        StringFileInfo([StringTable("040904B0", [
            StringStruct("ProductName", "AstralDeep"),
            StringStruct("FileDescription", "AstralDeep native Windows client"),
            StringStruct("FileVersion", __version__),
            StringStruct("ProductVersion", __version__),
            StringStruct("CompanyName", "AstralDeep"),
            StringStruct("OriginalFilename", "AstralDeep.exe"),
        ])]),
        VarFileInfo([VarStruct("Translation", [0x0409, 1200])]),
    ],
)

hiddenimports = (
    collect_submodules("PySide6.QtCharts")
    # QTextToSpeech and its SAPI plugin are runtime inputs, so their closure is explicit
    + collect_submodules("PySide6.QtTextToSpeech")
    # Offline analysis must not omit lazily imported livekit.rtc modules
    + collect_submodules("livekit.rtc")
    + collect_submodules("aiohttp")
    + collect_submodules("sigstore")
    # The frozen exe is every BYO worker's interpreter, so astralprims must resolve inside it
    + collect_submodules("astralprims")
    # websockets resolves connect through a runtime __import__, so collect it explicitly
    + collect_submodules("websockets")
    + ["PySide6.QtCharts", "PySide6.QtMultimedia", "PySide6.QtTextToSpeech", "websockets",
       "livekit", "livekit.rtc",
       "win_agent", "win_agent.agent", "win_agent.tools",
       "win_agent.lets_executor",
       "win_agent.byo_host", "win_agent.byo_worker",
       "astral_client.phi_gate", "astral_client.audit_log", "astral_client.integrity",
       "astral_client.helper_integrity", _helper_digest_module_name,
       "astral_client.confirm",
       "psutil", "pyperclip", "sigstore", "astralprims", "lets", "nacl",
       # Reached through a pre-Qt frozen entrypoint that static analysis cannot discover
       "lets.authority_helper", "lets.executor"]
)

excludes = [
    "PySide6.QtWebEngineCore", "PySide6.QtWebEngineWidgets", "PySide6.QtWebEngineQuick",
    "PySide6.Qt3DCore", "PySide6.Qt3DRender", "PySide6.QtQuick3D",
    "PySide6.QtPdf", "PySide6.QtPositioning", "PySide6.QtSql", "PySide6.QtTest",
    "tkinter", "PySide6.QtDesigner",
]

a = Analysis(
    ["main.py"],
    pathex=[str(_helper_digest_module_root)],
    # Collect livekit's RTC FFI artifact rather than rely on one-file import discovery
    binaries=(
        collect_dynamic_libs("livekit")
        + collect_dynamic_libs(
            "PySide6",
            search_patterns=[
                "qtexttospeech_sapi.dll",
                "libqtexttospeech_*.dylib",
                "libqtexttospeech_*.so",
            ],
        )
        + [("asr-helper/publish/AstralSpeechHelper.exe", "asr-helper")]
    ),
    datas=[
        ("assets/astraldeep.ico", "assets"),
        (str(_console_font_path), "assets/fonts"),
        (str(_root.parent / "backend/webrender/static/img/AstralDeep.png"), "assets/img"),
        (str(_root.parent / "backend/webrender/static/img/user-avatar.png"), "assets/img"),
        (str(_console_font_license_path), "assets/fonts"),
        ("deployment/release-profile.json", "deployment"),
        ("deployment/runtime-manifest.json", "deployment"),
        ("requirements-release.lock.txt", "deployment"),
        ("requirements.in", "deployment"),
        ("asr-helper/helper-source-hashes.json", "asr-helper"),
        ("asr-helper/publish/helper-build-provenance.json", "asr-helper"),
    ]
    + collect_data_files("livekit", include_py_files=False),
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=excludes,
    noarchive=False,
)
# Keep only the SAPI plugin so a package never reports the silent mock as local synthesis
a.binaries = [
    entry
    for entry in a.binaries
    if not (
        pathlib.PurePosixPath(entry[0].replace("\\", "/")).parent.name.lower()
        == "texttospeech"
        and pathlib.PurePosixPath(entry[0].replace("\\", "/")).name.lower()
        != "qtexttospeech_sapi.dll"
    )
]
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    [],
    name="AstralDeep",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=False,
    disable_windowed_traceback=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    version=version_res,
    icon="assets/astraldeep.ico",
)
