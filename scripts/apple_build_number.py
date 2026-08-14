#!/usr/bin/env python3
"""Derive a monotonic Apple build number across the repository transition.

The AstralDeep Apple release workflow historically used its repository-local
``GITHUB_RUN_NUMBER`` directly.  AstralProjection starts with a new run-number
sequence, so using that value without an authenticated offset can reuse an App
Store Connect build number.

Release jobs must supply all three values from the protected Apple release
environment.  There are deliberately no source-controlled defaults:

``ASTRAL_APPLE_BUILD_NUMBER_BASE``
    First build number reserved for Projection run 1.
``ASTRAL_APPLE_LAST_SUBMITTED_BUILD``
    Highest build confirmed in App Store Connect immediately before cutover.
``GITHUB_RUN_NUMBER``
    Monotonic run number assigned by GitHub to the Projection workflow.

The output is a single positive integer suitable for ``CFBundleVersion``.
"""

from __future__ import annotations

import argparse
import os
import re
from collections.abc import Mapping, Sequence

BUILD_NUMBER_BASE_ENV = "ASTRAL_APPLE_BUILD_NUMBER_BASE"
LAST_SUBMITTED_BUILD_ENV = "ASTRAL_APPLE_LAST_SUBMITTED_BUILD"
RUN_NUMBER_ENV = "GITHUB_RUN_NUMBER"

# A single-component CFBundleVersion remains portable across the current Apple
# targets.  Fail before exceeding the documented four-digit major component;
# release engineering can then adopt a reviewed dotted scheme deliberately.
MAX_BUILD_NUMBER = 9_999
_POSITIVE_DECIMAL = re.compile(r"[1-9][0-9]*\Z")


def _positive_decimal(value: str | int, *, name: str) -> int:
    if isinstance(value, bool):
        raise ValueError(f"{name} must be a positive decimal integer")
    text = str(value)
    if _POSITIVE_DECIMAL.fullmatch(text) is None:
        raise ValueError(f"{name} must be a positive decimal integer")
    parsed = int(text)
    if parsed > MAX_BUILD_NUMBER:
        raise ValueError(f"{name} must be at most {MAX_BUILD_NUMBER}")
    return parsed


def calculate_build_number(
    *,
    base: str | int,
    run_number: str | int,
    last_submitted_build: str | int,
) -> int:
    """Return the Projection build number or fail closed on unsafe inputs."""

    parsed_base = _positive_decimal(base, name="build-number base")
    parsed_run = _positive_decimal(run_number, name="workflow run number")
    parsed_last = _positive_decimal(last_submitted_build, name="last submitted build")
    if parsed_base <= parsed_last:
        raise ValueError("build-number base must be greater than the last submitted build")
    result = parsed_base + parsed_run - 1
    if result > MAX_BUILD_NUMBER:
        raise ValueError(f"derived build number exceeds the supported maximum {MAX_BUILD_NUMBER}")
    return result


def _required_value(explicit: str | None, *, environment: Mapping[str, str], variable: str) -> str:
    value = explicit if explicit is not None else environment.get(variable)
    if value is None or value == "":
        raise ValueError(f"{variable} is required")
    return value


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="derive a monotonic Astral Apple CFBundleVersion")
    parser.add_argument(
        "--base",
        help=f"protected first Projection build (or {BUILD_NUMBER_BASE_ENV})",
    )
    parser.add_argument(
        "--last-submitted-build",
        help=(f"highest App Store Connect build before cutover (or {LAST_SUBMITTED_BUILD_ENV})"),
    )
    parser.add_argument(
        "--run-number",
        help=f"Projection workflow run number (or {RUN_NUMBER_ENV})",
    )
    return parser


def main(
    argv: Sequence[str] | None = None,
    *,
    environment: Mapping[str, str] | None = None,
) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    env = os.environ if environment is None else environment
    try:
        result = calculate_build_number(
            base=_required_value(args.base, environment=env, variable=BUILD_NUMBER_BASE_ENV),
            last_submitted_build=_required_value(
                args.last_submitted_build,
                environment=env,
                variable=LAST_SUBMITTED_BUILD_ENV,
            ),
            run_number=_required_value(args.run_number, environment=env, variable=RUN_NUMBER_ENV),
        )
    except ValueError as exc:
        parser.error(str(exc))
    print(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
