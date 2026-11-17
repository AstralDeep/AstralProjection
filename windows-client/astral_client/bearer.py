# A bearer token a host hands the window, with no renewal, custody cookie or sign-in of its own.
# app.py and protocol.py accept it where they once took a refreshable session, and every renewal answer is none.

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional


@dataclass(repr=False)
class Session:
    access_token: str
    server_base: Optional[str] = None

    def websocket_headers(self, url: str) -> dict:
        return {}

    def remaining(self) -> Optional[float]:
        return None

    def refresh_delay_ms(self) -> Optional[int]:
        return None

    def refresh(self) -> Optional[str]:
        return None

    def logout(self) -> bool:
        return False
