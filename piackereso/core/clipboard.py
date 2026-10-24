"""Put a file on the system clipboard, so it can be pasted (Ctrl+V) into an AI chat.

Browsers cannot put a PDF file on the clipboard, but this server runs on the
user's own computer and can ask the operating system to do it.
"""

from __future__ import annotations

import base64
import subprocess
import sys
from pathlib import Path


def windows_command(path: Path) -> list[str]:
    # Windows PowerShell 5.1 (powershell.exe, part of Windows 10/11) has
    # Set-Clipboard -LiteralPath, which copies the file itself, like Ctrl+C in
    # Explorer. -EncodedCommand avoids quoting trouble with accented paths.
    script = "Set-Clipboard -LiteralPath '" + str(path).replace("'", "''") + "'"
    encoded = base64.b64encode(script.encode("utf-16-le")).decode("ascii")
    return ["powershell", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded]


def copy_file(path: Path) -> None:
    """Raises RuntimeError with a Hungarian message if the copy fails."""
    path = Path(path).resolve()
    if sys.platform.startswith("win"):
        cmd, stdin = windows_command(path), None
        flags = subprocess.CREATE_NO_WINDOW
    elif sys.platform == "darwin":
        cmd, stdin, flags = ["osascript", "-e", f'set the clipboard to (POSIX file "{path}")'], None, 0
    else:
        cmd, stdin, flags = ["xclip", "-selection", "clipboard", "-t", "text/uri-list", "-i"], path.as_uri() + "\n", 0
    try:
        done = subprocess.run(cmd, input=stdin, capture_output=True, text=True, timeout=20, creationflags=flags)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError(f"A vágólapra másolás nem sikerült ({exc}). Használd a letöltést.") from exc
    if done.returncode != 0:
        raise RuntimeError(f"A vágólapra másolás nem sikerült: {(done.stderr or done.stdout).strip()[:200]}")
