"""Checks the Apple workflow binds each Mac observation lane to its retained native binary.
The collector and merger suites verify the produced format and refusal behavior.
"""

from pathlib import Path
import re

import pytest


ROOT = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize("lane", ["unit", "ui"])
def test_apple_native_domains_are_collected_for_both_platforms_and_uploaded(lane):
    text = (ROOT / ".github/workflows/apple-ci.yml").read_text()
    marker = "--lane " + lane
    blocks = [
        block for block in text.split('          if [[ -d "$result" ]]; then') if marker in block
    ]
    assert len(blocks) == 1
    block = blocks[0].split('          exit "$status"', 1)[0]
    assert "if [[ '${{ matrix.slug }}' == ios ]]" not in block
    assert 'test "$status" -eq 0' in block
    assert "--platform '${{ matrix.slug }}'" in block
    assert f"apple-${{{{ matrix.slug }}}}-{lane}-domain.json" in block
    assert f"native-binaries/apple-${{{{ matrix.slug }}}}-{lane}.zip" in block
    assert 'native_args=(--native-domain "$domain")' in block
    assert re.search(
        r"build/060/coverage/native-binaries/apple-\$\{\{ matrix.slug \}\}-" + lane + r"\.zip", text
    )
    assert 'XCODE_VERSION: "26.6"' in text and 'XCODE_BUILD: "17F113"' in text
    assert "permissions:\n  contents: read" in text


@pytest.mark.parametrize("job", ["app-unit-tests", "first-login-ui"])
def test_mac_native_domain_uses_the_same_generated_products_without_rebuild(job):
    text = (ROOT / ".github/workflows/apple-ci.yml").read_text()
    block = text.split("  " + job + ":\n", 1)[1]
    block = re.split(r"(?m)^  [a-z][a-z-]+:\s*$", block, maxsplit=1)[0]
    prepared = block.split("test_action='test'\n", 1)[1].split(
        "test_action=test-without-building", 1
    )[0]
    assert "build-for-testing" in prepared
    assert "if [[ '${{ matrix.slug }}' == ios ]]" not in prepared
    assert "-only-testing:" not in prepared
