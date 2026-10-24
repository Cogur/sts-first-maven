#!/usr/bin/env sh
# Piackereső indítása macOS-en / Linuxon.
# Első indításkor, és ha a requirements.txt változott, telepíti a csomagokat.
cd "$(dirname "$0")"
[ -d .venv ] || python3 -m venv .venv
if ! cmp -s requirements.txt .venv/installed-requirements.txt; then
  .venv/bin/pip install -r requirements.txt && cp requirements.txt .venv/installed-requirements.txt
fi
exec .venv/bin/python server.py "$@"
