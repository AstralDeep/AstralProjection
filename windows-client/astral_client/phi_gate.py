"""Client-side PHI pre-filter for the Windows coding agent: refuses file reads and
command output that look like PHI before they leave the machine, mirroring
backend/personalization/phi_gate.py's pattern half; used by win_agent/tools.py.
"""

from __future__ import annotations

import logging
import re
from typing import List

logger = logging.getLogger("astral.phi_gate")

_PREFILTER_PATTERNS: List[re.Pattern] = [
    re.compile(r"\b\d{3}-\d{2}-\d{4}\b"),
    re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"),
    re.compile(r"\b(?:\+?1[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b"),
    re.compile(r"\b\d{4}-\d{2}-\d{2}\b"),
    re.compile(r"\b\d{1,2}/\d{1,2}/\d{2,4}\b"),
    re.compile(r"\bMRN\b[:#\s-]*\d{3,}", re.IGNORECASE),
    re.compile(r"\bmedical record\b", re.IGNORECASE),
    re.compile(r"\b\d{7,}\b"),
]


def looks_like_phi(text: str) -> bool:
    if not isinstance(text, str) or not text:
        return False
    try:
        return any(p.search(text) for p in _PREFILTER_PATTERNS)
    # Fail-closed: any error here must still refuse, not allow
    except Exception:  # noqa: BLE001
        logger.warning("PHI pre-filter raised; treating input as PHI (fail-closed)", exc_info=True)
        return True


def scan(text: str) -> bool:
    return looks_like_phi(text)
