"""Runtime and frozen-archive integrity contracts for the speech helper."""

from __future__ import annotations

import ctypes
import hashlib
import os
from pathlib import Path
import sys
from types import CodeType, SimpleNamespace

import pytest

from astral_client import helper_integrity
from astral_client.helper_integrity import (
    HelperIntegrityResult,
    verify_helper_integrity,
)


ROOT = Path(__file__).resolve().parents[1]
SPEC = ROOT / "AstralDeep.spec"


def _helper(tmp_path: Path, content: bytes = b"qualified helper") -> tuple[Path, str]:
    path = tmp_path / "AstralSpeechHelper.exe"
    path.write_bytes(content)
    return path, hashlib.sha256(content).hexdigest()


def _candidate_exe() -> Path:
    value = os.getenv("ASTRAL_WINDOWS_EXE")
    if not value:
        pytest.skip("ASTRAL_WINDOWS_EXE is supplied by the Windows candidate job")
    path = Path(value)
    if not path.is_file():
        pytest.fail(f"ASTRAL_WINDOWS_EXE is not a file: {path}")
    return path


def _embedded_helper_and_digest() -> tuple[bytes, str]:
    exe = _candidate_exe()
    from PyInstaller.archive.readers import CArchiveReader

    archive = CArchiveReader(str(exe))
    helper_entry = next(
        name
        for name in archive.toc
        if name.replace("\\", "/").lower()
        == "asr-helper/astralspeechhelper.exe"
    )
    pyz_entry = next(
        name for name in archive.toc if name.replace("\\", "/").lower() == "pyz.pyz"
    )
    assert helper_integrity._EXPECTED_DIGEST_MODULE not in archive.toc

    pyz = archive.open_embedded_archive(pyz_entry)
    assert helper_integrity._EXPECTED_DIGEST_MODULE in pyz.toc
    generated_code = pyz.extract(helper_integrity._EXPECTED_DIGEST_MODULE)
    assert isinstance(generated_code, CodeType)
    namespace = {"__builtins__": {}}
    exec(generated_code, namespace)
    assert set(namespace) == {
        "__builtins__",
        "__doc__",
        "EXPECTED_HELPER_SHA256",
    }
    expected = namespace["EXPECTED_HELPER_SHA256"]
    assert isinstance(expected, str)
    return archive.extract(helper_entry), expected


def test_missing_helper_fails_before_loading_expected_digest(tmp_path):
    called = False

    def load_expected():
        nonlocal called
        called = True
        return "0" * 64

    result = verify_helper_integrity(
        tmp_path / "missing.exe",
        expected_digest_loader=load_expected,
        platform="win32",
    )

    assert result == HelperIntegrityResult(False, "helper_missing")
    assert not called


def test_non_windows_platform_fails_closed(tmp_path):
    helper, expected = _helper(tmp_path)

    result = verify_helper_integrity(
        helper,
        expected_sha256=expected,
        authenticode_verifier=lambda _path: True,
        platform="linux",
    )

    assert result == HelperIntegrityResult(False, "unsupported_platform")


@pytest.mark.parametrize(
    "loader",
    (
        lambda: None,
        lambda: "A" * 64,
        lambda: (_ for _ in ()).throw(RuntimeError("unavailable")),
    ),
)
def test_missing_or_malformed_generated_digest_fails_closed(tmp_path, loader):
    helper, _expected = _helper(tmp_path)

    result = verify_helper_integrity(
        helper,
        expected_digest_loader=loader,
        platform="win32",
    )

    assert result == HelperIntegrityResult(False, "expected_digest_unavailable")


def test_default_digest_loader_reads_only_the_generated_module(monkeypatch):
    expected = "1" * 64
    monkeypatch.setitem(
        sys.modules,
        helper_integrity._EXPECTED_DIGEST_MODULE,
        SimpleNamespace(EXPECTED_HELPER_SHA256=expected),
    )

    assert helper_integrity._load_expected_digest() == expected


def test_default_digest_loader_rejects_a_missing_module(monkeypatch):
    monkeypatch.delitem(
        sys.modules, helper_integrity._EXPECTED_DIGEST_MODULE, raising=False
    )
    real_import = helper_integrity.importlib.import_module

    def reject_generated(name):
        if name == helper_integrity._EXPECTED_DIGEST_MODULE:
            raise ImportError(name)
        return real_import(name)

    monkeypatch.setattr(helper_integrity.importlib, "import_module", reject_generated)

    assert helper_integrity._load_expected_digest() is None


def test_digest_read_failure_fails_closed(tmp_path):
    helper, expected = _helper(tmp_path)

    result = verify_helper_integrity(
        helper,
        expected_sha256=expected,
        digest_reader=lambda _path: (_ for _ in ()).throw(RuntimeError("read failed")),
        platform="win32",
    )

    assert result == HelperIntegrityResult(False, "digest_read_failed")


def test_digest_mismatch_never_reaches_authenticode(tmp_path):
    helper, _expected = _helper(tmp_path)
    signature_called = False

    def verify_signature(_path):
        nonlocal signature_called
        signature_called = True
        return True

    result = verify_helper_integrity(
        helper,
        expected_sha256="0" * 64,
        authenticode_verifier=verify_signature,
        platform="win32",
    )

    assert result == HelperIntegrityResult(False, "digest_mismatch")
    assert not signature_called


@pytest.mark.parametrize(
    "verifier",
    (
        lambda _path: False,
        lambda _path: (_ for _ in ()).throw(RuntimeError("trust unavailable")),
    ),
)
def test_unsigned_or_unverifiable_helper_is_unavailable(tmp_path, verifier):
    helper, expected = _helper(tmp_path)

    result = verify_helper_integrity(
        helper,
        expected_sha256=expected,
        authenticode_verifier=verifier,
        platform="win32",
    )

    assert result == HelperIntegrityResult(False, "signature_invalid")


def test_replacement_during_signature_validation_is_rejected(tmp_path):
    helper, expected = _helper(tmp_path)
    digests = iter((expected, "2" * 64))

    result = verify_helper_integrity(
        helper,
        expected_sha256=expected,
        digest_reader=lambda _path: next(digests),
        authenticode_verifier=lambda _path: True,
        platform="win32",
    )

    assert result == HelperIntegrityResult(
        False, "helper_changed_during_verification"
    )


def test_matching_digest_and_trusted_signature_are_ready(tmp_path):
    helper, expected = _helper(tmp_path)

    result = verify_helper_integrity(
        helper,
        expected_sha256=expected,
        authenticode_verifier=lambda path: path == helper,
        platform="win32",
    )

    assert result == HelperIntegrityResult(True, "ready")


class _FakeWinVerifyTrust:
    def __init__(self, *outcomes):
        self.argtypes = None
        self.restype = None
        self._outcomes = iter(outcomes)
        self.state_actions: list[int] = []
        self.policies: list[tuple[int, int, int]] = []

    def __call__(self, _window, _action, trust_data_pointer):
        trust_data = ctypes.cast(
            trust_data_pointer, ctypes.POINTER(helper_integrity._WinTrustData)
        ).contents
        self.state_actions.append(int(trust_data.dwStateAction))
        self.policies.append(
            (
                int(trust_data.dwUIChoice),
                int(trust_data.fdwRevocationChecks),
                int(trust_data.dwProvFlags),
            )
        )
        outcome = next(self._outcomes)
        if isinstance(outcome, Exception):
            raise outcome
        return outcome


@pytest.mark.parametrize(("status", "expected"), ((0, True), (1, False)))
def test_winverifytrust_verifies_and_closes_state(tmp_path, status, expected):
    helper, _digest = _helper(tmp_path)
    win_verify_trust = _FakeWinVerifyTrust(status, 0)

    result = helper_integrity._verify_authenticode(
        helper,
        library_loader=lambda: SimpleNamespace(WinVerifyTrust=win_verify_trust),
    )

    assert result is expected
    assert win_verify_trust.state_actions == [
        helper_integrity._WTD_STATEACTION_VERIFY,
        helper_integrity._WTD_STATEACTION_CLOSE,
    ]
    assert win_verify_trust.argtypes is not None
    assert win_verify_trust.restype is not None
    assert win_verify_trust.policies == [
        (
            helper_integrity._WTD_UI_NONE,
            helper_integrity._WTD_REVOKE_WHOLECHAIN,
            helper_integrity._WTD_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT
            | helper_integrity._WTD_DISABLE_MD2_MD4,
        )
    ] * 2


def test_winverifytrust_closes_state_when_verification_raises(tmp_path):
    helper, _digest = _helper(tmp_path)
    win_verify_trust = _FakeWinVerifyTrust(RuntimeError("failed"), 0)

    with pytest.raises(RuntimeError, match="failed"):
        helper_integrity._verify_authenticode(
            helper,
            library_loader=lambda: SimpleNamespace(WinVerifyTrust=win_verify_trust),
        )

    assert win_verify_trust.state_actions == [
        helper_integrity._WTD_STATEACTION_VERIFY,
        helper_integrity._WTD_STATEACTION_CLOSE,
    ]


def test_default_wintrust_loader_uses_the_windows_system_library(monkeypatch):
    expected = object()
    monkeypatch.setattr(
        helper_integrity.ctypes,
        "WinDLL",
        lambda name, *, use_last_error: (
            expected if (name, use_last_error) == ("wintrust", True) else None
        ),
        raising=False,
    )

    assert helper_integrity._load_wintrust() is expected


def test_spec_generates_digest_module_for_pyz_not_data_files():
    text = SPEC.read_text(encoding="utf-8")
    analysis = text.partition("a = Analysis(")[2]
    datas = analysis.partition("datas=[")[2].partition("hiddenimports=")[0]

    assert '_helper_digest_module_name = "_astral_helper_integrity_expected"' in text
    assert "_helper_sha256 = _sha256(_helper_path)" in text
    assert "EXPECTED_HELPER_SHA256" in text
    assert 'pathex=[str(_helper_digest_module_root)]' in analysis
    assert '"astral_client.helper_integrity", _helper_digest_module_name' in text
    assert "_helper_digest_module" not in datas


def test_unsigned_candidate_embeds_exact_digest_and_remains_unavailable(tmp_path):
    """The unprivileged active CI candidate has no helper signing identity."""

    if sys.platform != "win32":
        pytest.skip("WinVerifyTrust is a Windows qualification")
    helper_bytes, expected = _embedded_helper_and_digest()
    helper = tmp_path / "AstralSpeechHelper.exe"
    helper.write_bytes(helper_bytes)

    assert expected == hashlib.sha256(helper_bytes).hexdigest()
    assert verify_helper_integrity(
        helper, expected_sha256=expected
    ) == HelperIntegrityResult(False, "signature_invalid")
