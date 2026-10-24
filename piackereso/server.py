"""Piackereső: local web server.

    python server.py                 # http://localhost:8765, this computer only
    python server.py --lan           # reachable from your phone on the home Wi-Fi
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import socket
import threading
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from core import clipboard, common, details, search, settings
from core.common import SearchQuery
from core.sources import SOURCES, hardverapro

STATIC = Path(__file__).resolve().parent / "static"
EXPORTS = Path(__file__).resolve().parent / "exports"


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
        path = urlparse(self.path).path
        if path not in ("/api/settings", "/api/export", "/api/describe"):
            return self._json({"error": "not found"}, status=404)
        try:
            length = int(self.headers.get("Content-Length") or 0)
            data = json.loads(self.rfile.read(min(length, 2_000_000)) or b"{}")
        except ValueError:
            return self._json({"error": "bad json"}, status=400)
        if path == "/api/export":
            return self._export(data)
        if path == "/api/describe":
            return self._describe(data)
        # Only the Facebook cookie is settable; values are never echoed back.
        settings.update(
            fb_c_user=str(data.get("fb_c_user") or "").strip(),
            fb_xs=str(data.get("fb_xs") or "").strip(),
        )
        search.clear_cache()
        return self._json({"fb_cookie_set": bool(settings.facebook_cookie())})

    def _describe(self, data: dict):
        """Ad descriptions, for checking whether the search term is in them.

        Uses the same cached ad-page fetch as the AI export, so a later export
        of these ads is faster.
        """
        items = [
            {"source": str(it.get("source") or ""), "url": str(it.get("url") or "")}
            for it in (data.get("items") or [])[:50]
            if isinstance(it, dict)
        ]
        infos = details.get_many(items)
        return self._json({"descriptions": {it["url"]: info.description for it, info in zip(items, infos)}})

    def _export(self, data: dict):
        """Build the AI-export PDF; send it back, or put it on the clipboard."""
        try:
            from core import export_pdf  # needs fpdf2; imported here so search works without it
        except ImportError:
            return self._json({"error": "Hiányzik az fpdf2 csomag: indítsd újra a start.bat-tal, az telepíti."}, status=500)
        items = [it for it in data.get("items") or [] if isinstance(it, dict)][: export_pdf.MAX_BATCH]
        if not items:
            return self._json({"error": "Nincs exportálható hirdetés."}, status=400)
        prices = [p for p in data.get("prices") or [] if isinstance(p, dict)][:5000]
        meta = {
            "query": str(data.get("query") or "")[:200],
            "min": str(data.get("min") or "")[:12],
            "max": str(data.get("max") or "")[:12],
            "offset": max(0, int(data.get("offset") or 0)),
            "total": int(data.get("total") or len(items)),
            "prices": prices,
        }
        try:
            pdf = export_pdf.build(meta, items, with_details=bool(data.get("details", True)))
        except Exception as exc:  # noqa: BLE001
            return self._json({"error": f"A PDF nem készült el: {exc}"}, status=500)
        EXPORTS.mkdir(exist_ok=True)
        name = export_pdf.filename(meta, len(items))
        target = EXPORTS / name
        target.write_bytes(pdf)
        if data.get("clipboard"):
            try:
                clipboard.copy_file(target)
            except RuntimeError as exc:
                return self._json({"error": str(exc), "file": str(target)}, status=500)
            return self._json({"ok": True, "file": str(target), "kb": len(pdf) // 1024})
        self.send_response(200)
        self.send_header("Content-Type", "application/pdf")
        self.send_header("Content-Disposition", f'attachment; filename="{name}"')
        self.send_header("Content-Length", str(len(pdf)))
        self.end_headers()
        self.wfile.write(pdf)

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
    threading.Thread(target=hardverapro.warm_up, daemon=True).start()
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
