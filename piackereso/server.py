"""Piackereső: local web server.

    python server.py                 # http://localhost:8765, this computer only
    python server.py --lan           # reachable from your phone on the home Wi-Fi
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import socket
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from piackereso import common, search, settings
from piackereso.common import SearchQuery
from piackereso.sources import SOURCES

STATIC = Path(__file__).resolve().parent / "static"


def _int(params: dict, name: str) -> int | None:
    raw = (params.get(name) or [""])[0].replace(" ", "")
    return int(raw) if raw.isdigit() else None


class Handler(BaseHTTPRequestHandler):
    server_version = "Piackereso/1.0"

    def do_GET(self):
        url = urlparse(self.path)
        params = parse_qs(url.query)
        if url.path == "/api/search":
            return self._search(params)
        if url.path == "/api/sources":
            return self._json([{"key": k, "name": m.NAME} for k, m in SOURCES.items()])
        if url.path == "/api/settings":
            return self._json({"fb_cookie_set": bool(settings.facebook_cookie())})
        return self._static("index.html" if url.path in ("/", "") else url.path.lstrip("/"))

    def do_POST(self):
        if urlparse(self.path).path != "/api/settings":
            return self._json({"error": "not found"}, status=404)
        try:
            length = int(self.headers.get("Content-Length") or 0)
            data = json.loads(self.rfile.read(min(length, 65536)) or b"{}")
        except ValueError:
            return self._json({"error": "bad json"}, status=400)
        # Only the Facebook cookie is settable; values are never echoed back.
        settings.update(
            fb_c_user=str(data.get("fb_c_user") or "").strip(),
            fb_xs=str(data.get("fb_xs") or "").strip(),
        )
        search.clear_cache()
        return self._json({"fb_cookie_set": bool(settings.facebook_cookie())})

    def _search(self, params: dict):
        text = (params.get("q") or [""])[0].strip()
        if not text:
            return self._json({"error": "Adj meg egy keresőszót."}, status=400)
        q = SearchQuery(
            text=text,
            min_price=_int(params, "min"),
            max_price=_int(params, "max"),
            page=max(1, _int(params, "page") or 1),
            fb_city=(params.get("city") or ["budapest"])[0],
        )
        keys = [k for k in (params.get("sources") or [""])[0].split(",") if k]
        results = search.run(q, keys)
        self._json({"query": text, "page": q.page, "sources": [r.to_dict() for r in results]})

    def _static(self, rel: str):
        path = (STATIC / rel).resolve()
        if STATIC not in path.parents or not path.is_file():
            return self._json({"error": "not found"}, status=404)
        body = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", mimetypes.guess_type(path.name)[0] or "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, data, status: int = 200):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):  # keep the console quiet except for searches
        if "/api/search" in (args[0] if args else ""):
            super().log_message(fmt, *args)


def _lan_ip() -> str:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("10.255.255.255", 1))
            return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"


def main():
    ap = argparse.ArgumentParser(description="Piackereső: search Hungarian second-hand marketplaces at once")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--lan", action="store_true", help="listen on every interface so a phone on the same Wi-Fi can open it")
    ap.add_argument("--no-browser", action="store_true", help="do not open the browser on start")
    ap.add_argument("--debug", action="store_true", help="save every fetched page into the debug/ folder")
    args = ap.parse_args()

    if args.debug:
        common.DEBUG_DIR = str(Path(__file__).resolve().parent / "debug")
        print(f"Hibakereső mód: a letöltött oldalak ide kerülnek: {common.DEBUG_DIR}")

    host = "0.0.0.0" if args.lan else "127.0.0.1"
    httpd = ThreadingHTTPServer((host, args.port), Handler)
    local = f"http://localhost:{args.port}"
    print(f"Piackereső fut: {local}")
    if args.lan:
        print(f"Telefonról (ugyanazon a Wi-Fin): http://{_lan_ip()}:{args.port}")
    print("Leállítás: Ctrl+C")
    if not args.no_browser:
        webbrowser.open(local)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
