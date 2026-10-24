"""Local settings (e.g. the Facebook login cookie), kept in settings.local.json next to server.py.

The file stays on this computer: it is git-ignored and the server never sends its
secrets back to the browser.
"""

from __future__ import annotations

import json
import threading
from pathlib import Path

PATH = Path(__file__).resolve().parents[1] / "settings.local.json"
_lock = threading.Lock()


def load() -> dict:
    try:
        return json.loads(PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def update(**values) -> None:
    with _lock:
        data = load()
        for key, value in values.items():
            if value:
                data[key] = value
            else:
                data.pop(key, None)
        PATH.write_text(json.dumps(data, indent=2), encoding="utf-8")


def facebook_cookie() -> str:
    data = load()
    c_user, xs = data.get("fb_c_user", "").strip(), data.get("fb_xs", "").strip()
    return f"c_user={c_user}; xs={xs}" if c_user and xs else ""
