#!/usr/bin/env python3
"""HomeGuard simulator: fake door station relay and indoor monitor.

Door station (port 8080):  GET/POST /cgi-bin/accessControl.cgi?action=openDoor&channel=1
Indoor monitor (port 8081): GET /sdcard/snapshot/   (HTML directory listing of event files)

Both require HTTP Digest auth (admin / admin123), like the real devices.
Every --new-event-every seconds a fresh "call" snapshot is added to the monitor,
so you can test Events -> Sync. Standard library only.
"""
import argparse
import hashlib
import html
import os
import re
import secrets
import shutil
import threading
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit

REALM = "HomeGuardSim"
NONCES = set()
EVENT_TYPES = ["FACE", "CALL", "MOTION", "CARD"]


def md5(s: str) -> str:
    return hashlib.md5(s.encode()).hexdigest()


class DigestHandler(BaseHTTPRequestHandler):
    server_version = "HomeGuardSim/1.0"
    user = "admin"
    password = "admin123"

    def log_message(self, fmt, *args):
        print(f"[{self.server.name}] {self.address_string()} {fmt % args}", flush=True)

    def _challenge(self):
        nonce = secrets.token_hex(16)
        NONCES.add(nonce)
        self.send_response(401)
        self.send_header(
            "WWW-Authenticate",
            f'Digest realm="{REALM}", qop="auth", nonce="{nonce}", algorithm=MD5',
        )
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _authorized(self) -> bool:
        header = self.headers.get("Authorization", "")
        if not header.startswith("Digest "):
            return False
        p = dict(re.findall(r'(\w+)="?([^",]*)"?', header[7:]))
        if p.get("nonce") not in NONCES or p.get("username") != self.user:
            return False
        ha1 = md5(f"{self.user}:{REALM}:{self.password}")
        ha2 = md5(f"{self.command}:{p.get('uri', '')}")
        if p.get("qop") == "auth":
            expected = md5(f"{ha1}:{p['nonce']}:{p.get('nc')}:{p.get('cnonce')}:auth:{ha2}")
        else:
            expected = md5(f"{ha1}:{p['nonce']}:{ha2}")
        return secrets.compare_digest(expected, p.get("response", ""))

    def _send(self, code, body: bytes, ctype="text/plain; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if not self._authorized():
            return self._challenge()
        self.handle_authorized()

    do_POST = do_GET
    do_PUT = do_GET


class DoorHandler(DigestHandler):
    def handle_authorized(self):
        url = urlsplit(self.path)
        if url.path == "/cgi-bin/accessControl.cgi" and "action=openDoor" in url.query:
            print("\n" + "=" * 50 + "\n  >>> DOOR RELAY TRIGGERED - DOOR UNLOCKED <<<\n" + "=" * 50 + "\n", flush=True)
            return self._send(200, b"OK")
        self._send(404, b"Unknown endpoint")


class MonitorHandler(DigestHandler):
    sd_dir = "sdcard"

    def handle_authorized(self):
        path = unquote(urlsplit(self.path).path)
        if path in ("/sdcard/snapshot", "/sdcard/snapshot/"):
            files = sorted(f for f in os.listdir(self.sd_dir) if not f.startswith("."))
            links = "\n".join(f'<a href="{html.escape(f)}">{html.escape(f)}</a><br>' for f in files)
            return self._send(200, f"<html><body>{links}</body></html>".encode(), "text/html; charset=utf-8")
        if path.startswith("/sdcard/snapshot/"):
            name = os.path.basename(path)
            full = os.path.join(self.sd_dir, name)
            if name and os.path.isfile(full):
                with open(full, "rb") as fh:
                    return self._send(200, fh.read(), "image/jpeg" if name.lower().endswith(".jpg") else "video/mp4")
        self._send(404, b"Not found")


def add_events(sd_dir: str, every: int):
    samples = sorted(f for f in os.listdir(sd_dir) if f.endswith(".jpg"))
    i = 0
    while every > 0 and samples:
        time.sleep(every)
        kind = EVENT_TYPES[i % len(EVENT_TYPES)]
        name = f"{datetime.now():%Y%m%d_%H%M%S}_{kind}.jpg"
        shutil.copy(os.path.join(sd_dir, samples[i % len(samples)]), os.path.join(sd_dir, name))
        print(f"[monitor] new event on SD card: {name}", flush=True)
        i += 1


def serve(name, handler, port):
    srv = ThreadingHTTPServer(("0.0.0.0", port), handler)
    srv.name = name
    print(f"[{name}] listening on :{port}", flush=True)
    srv.serve_forever()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--door-port", type=int, default=8080)
    ap.add_argument("--monitor-port", type=int, default=8081)
    ap.add_argument("--sdcard", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "sdcard"))
    ap.add_argument("--new-event-every", type=int, default=120, help="seconds; 0 disables")
    args = ap.parse_args()
    MonitorHandler.sd_dir = args.sdcard
    threading.Thread(target=serve, args=("door", DoorHandler, args.door_port), daemon=True).start()
    threading.Thread(target=add_events, args=(args.sdcard, args.new_event_every), daemon=True).start()
    serve("monitor", MonitorHandler, args.monitor_port)


if __name__ == "__main__":
    main()
