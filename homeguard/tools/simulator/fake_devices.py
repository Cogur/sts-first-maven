#!/usr/bin/env python3
"""HomeGuard simulator: fake door station relay and indoor monitor.

Door station (port 8080):  GET/POST /cgi-bin/accessControl.cgi?action=openDoor&channel=1
Indoor monitor (port 8081): GET /sdcard/snapshot/   (HTML directory listing of event files)
NVR web interface (port 8082): TVT NVMS-9000 login, camera list, RTSP/API Server
    settings, and the HTTP API recording search (/LAPI/V1.0/Playback/SearchByTime)
TVT device protocol (port 9008): login + alarm output (door relay over the TVT protocol)

All require admin / admin123 (HTTP Digest on 8080/8081, like the real devices).
Every --new-event-every seconds a fresh "call" snapshot is added to the monitor,
so you can test Events -> Sync. Standard library only.
"""
import argparse
import base64
import hashlib
import html
import os
import re
import secrets
import shutil
import socketserver
import struct
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


class NvrWebHandler(BaseHTTPRequestHandler):
    """TVT NVMS-9000 web interface + HTTP API, enough for the app's sign-in and playback."""

    server_version = "HomeGuardSim-NVR/1.0"
    user, password = "admin", "admin123"
    nonce = secrets.token_hex(8)
    token = secrets.token_hex(8)
    state = {"rtsp": True, "api": False}
    cameras = ["Front Gate", "Garden", "Garage"]

    def log_message(self, fmt, *args):
        print(f"[nvr-web] {self.address_string()} {fmt % args}", flush=True)

    def _send(self, code, body, ctype="text/xml; charset=utf-8", headers=()):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    @staticmethod
    def _ok(content=""):
        return f'<?xml version="1.0" encoding="UTF-8"?><response><status>success</status>{content}</response>'

    _fail = '<?xml version="1.0"?><response><status>fail</status><errorCode>536870948</errorCode></response>'

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode("utf-8", "replace")
        path = urlsplit(self.path).path
        if path.startswith("/LAPI/"):
            return self._lapi(path, body)
        cmd = path.lstrip("/")
        logged_in = f"<token>{self.token}</token>" in body
        if cmd == "reqLogin":
            return self._send(200, self._ok(f"<content><nonce>{self.nonce}</nonce><token>{self.token}</token></content>"))
        if cmd == "doLogin":
            md5_upper = hashlib.md5(self.password.encode()).hexdigest().upper()
            good = hashlib.sha512(f"{md5_upper}#{self.nonce}".encode()).hexdigest()
            m = re.search(r"<password><!\[CDATA\[(.*?)\]\]></password>", body)
            ok = m and secrets.compare_digest(m.group(1), good) and f"[{self.user}]" in body
            return self._send(200, self._ok() if ok else self._fail)
        if not logged_in:
            return self._send(200, self._fail)
        if cmd == "queryDevList":
            items = "".join(
                f'<item id="{{0000000{i}-0000-0000-0000-000000000000}}"><chlNum>{i}</chlNum>'
                f"<name><![CDATA[{n}]]></name><ip>10.0.0.1{i}</ip><port>9008</port></item>"
                for i, n in enumerate(self.cameras, 1)
            )
            return self._send(200, self._ok(f'<content type="list" total="{len(self.cameras)}">{items}</content>'))
        if cmd == "queryOnlineChlList":
            items = "".join(f'<item id="{{0000000{i}-0000-0000-0000-000000000000}}"/>' for i in range(1, 4))
            return self._send(200, self._ok(f"<content>{items}</content>"))
        if cmd == "queryRTSPServer":
            return self._send(200, self._ok(
                f"<content><rtspServerSwitch>{str(self.state['rtsp']).lower()}</rtspServerSwitch>"
                "<rtspAuthType>Digest</rtspAuthType><rtspPort>8554</rtspPort>"
                "<anonymousAccess>false</anonymousAccess></content>"))
        if cmd == "editRTSPServer":
            self.state["rtsp"] = "<rtspServerSwitch>true" in body
            print(f"[nvr-web] RTSP service switched {'ON' if self.state['rtsp'] else 'OFF'} by the app", flush=True)
            return self._send(200, self._ok())
        if cmd == "queryApiServer":
            return self._send(200, self._ok(
                f"<content><apiserverSwitch>{str(self.state['api']).lower()}</apiserverSwitch>"
                "<authenticationType>Basic</authenticationType></content>"))
        if cmd == "editApiServer":
            self.state["api"] = "<apiserverSwitch>true" in body
            print(f"[nvr-web] API Server switched {'ON' if self.state['api'] else 'OFF'} by the app", flush=True)
            return self._send(200, self._ok())
        return self._send(200, self._fail)

    def _lapi(self, path, body):
        if not self.state["api"]:
            return self._send(404, "API Server disabled", "text/plain")
        expected = "Basic " + base64.b64encode(f"{self.user}:{self.password}".encode()).decode()
        if not secrets.compare_digest(self.headers.get("Authorization", ""), expected):
            return self._send(401, "", headers=[("WWW-Authenticate", 'Basic realm="NVR"')])
        if path != "/LAPI/V1.0/Playback/SearchByTime":
            return self._send(404, "Unknown command", "text/plain")
        ch = re.search(r"<channelID>(\d+)</channelID>", body)
        start = re.search(r"<startTime>(\d{4}-\d\d-\d\d)", body)
        day = start.group(1) if start else datetime.now().strftime("%Y-%m-%d")
        segs = []
        # A recording every two hours plus motion clips, like a typical schedule.
        for h in range(0, 24, 2):
            segs.append((f"{day}T{h:02d}:00:00", f"{day}T{h:02d}:45:00", "schedule"))
            segs.append((f"{day}T{h + 1:02d}:10:00", f"{day}T{h + 1:02d}:12:30", "motion"))
        items = "".join(
            f"<RecordSegment><channelID>{ch.group(1) if ch else 1}</channelID><startTime>{a}</startTime>"
            f"<endTime>{b}</endTime><recordType>{t}</recordType></RecordSegment>"
            for a, b, t in segs
        )
        return self._send(200, '<?xml version="1.0"?><SearchByTimeResponse><ResponseStatus>'
                               f"<statusCode>200</statusCode></ResponseStatus>{items}</SearchByTimeResponse>")


class TvtDeviceHandler(socketserver.BaseRequestHandler):
    """TVT device protocol (port 9008), classic login: the door relay as alarm output 0."""

    user, password = b"admin", b"admin123"

    @staticmethod
    def packet(cmd, data=b""):
        return b"1111" + struct.pack("<IIIII", 16 + len(data), cmd, 0, 0, len(data)) + data

    def handle(self):
        init = bytearray(64)
        init[0:4] = b"head"
        struct.pack_into("<III", init, 4, 1, 0, 3)  # devType, productType, protocolVer 3
        self.request.sendall(bytes(init) + b"1111" + b"\0\0\0\0")
        buf = b""
        while True:
            chunk = self.request.recv(4096)
            if not chunk:
                return
            buf += chunk
            while len(buf) >= 8:
                (length,) = struct.unpack_from("<I", buf, 4)
                if len(buf) < 8 + length:
                    break
                frame, buf = buf[8:8 + length], buf[8 + length:]
                if length < 16:
                    continue
                cmd = struct.unpack_from("<I", frame, 0)[0]
                data = frame[16:]
                if cmd == 0x101:
                    user = data[4:36].rstrip(b"\0")
                    pw = data[36:68].rstrip(b"\0")
                    ok = user == self.user and pw == self.password
                    print(f"[tvt-9008] login {'OK' if ok else 'REJECTED'}", flush=True)
                    reply = bytearray(200)
                    reply[58:58 + 13] = b"HomeGuardDoor"
                    self.request.sendall(self.packet(0x1000101, bytes(reply)) if ok else self.packet(0x1000102))
                elif cmd == 0x0B01:
                    print("\n" + "=" * 50 + f"\n  >>> TVT ALARM OUTPUT {struct.unpack_from('<I', data)[0]} ON - DOOR UNLOCKED <<<\n"
                          + "=" * 50 + "\n", flush=True)
                elif cmd == 0x0B02:
                    print("[tvt-9008] alarm output off", flush=True)


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
    ap.add_argument("--nvr-web-port", type=int, default=8082)
    ap.add_argument("--tvt-port", type=int, default=9008)
    ap.add_argument("--sdcard", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "sdcard"))
    ap.add_argument("--new-event-every", type=int, default=120, help="seconds; 0 disables")
    args = ap.parse_args()
    MonitorHandler.sd_dir = args.sdcard
    threading.Thread(target=serve, args=("door", DoorHandler, args.door_port), daemon=True).start()
    threading.Thread(target=serve, args=("nvr-web", NvrWebHandler, args.nvr_web_port), daemon=True).start()
    tvt = socketserver.ThreadingTCPServer(("0.0.0.0", args.tvt_port), TvtDeviceHandler)
    tvt.daemon_threads = True
    print(f"[tvt-9008] listening on :{args.tvt_port}", flush=True)
    threading.Thread(target=tvt.serve_forever, daemon=True).start()
    threading.Thread(target=add_events, args=(args.sdcard, args.new_event_every), daemon=True).start()
    serve("monitor", MonitorHandler, args.monitor_port)


if __name__ == "__main__":
    main()
