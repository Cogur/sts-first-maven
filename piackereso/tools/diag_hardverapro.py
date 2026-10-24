"""Hardverapró diagnosis: which kind of request gets real search results?

Run from the app folder (diag.bat does this on Windows):

    .venv/bin/python tools/diag_hardverapro.py kave

Each variant prints its redirect chain and how many ads matched the search.
The report is also written to debug/diag_hardverapro.txt so it can be sent on.
"""

from __future__ import annotations

import sys
import time
from pathlib import Path
from urllib.parse import urlencode, urljoin

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from core import common  # noqa: E402
from core.common import SearchQuery, title_matches  # noqa: E402
from core.sources import hardverapro  # noqa: E402

BASE = "https://hardverapro.hu"
INDEX = f"{BASE}/aprok/index.html"
LINES: list[str] = []


def say(text: str = "") -> None:
    print(text)
    LINES.append(text)


def curl_session(profile: str):
    from curl_cffi import requests as curl_requests

    return curl_requests.Session(impersonate=profile, verify=common._SESSION_ARGS.get("verify", True))


def requests_session():
    import requests

    s = requests.Session()
    s.headers.update(
        {
            "User-Agent": common.USER_AGENT,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
            "Accept-Language": "hu-HU,hu;q=0.9,en;q=0.8",
            "Upgrade-Insecure-Requests": "1",
        }
    )
    return s


def cookie_names(resp) -> str:
    raw = resp.headers.get("Set-Cookie", "") or ""
    names = sorted({c.split("=", 1)[0].strip() for c in raw.split(",") if "=" in c and "GMT" not in c.split("=", 1)[0]})
    return ",".join(names) or "-"


def get_chain(session, url: str, headers: dict) -> tuple[str, str]:
    """Follow redirects by hand; return (chain description, final html)."""
    hops = []
    for _ in range(6):
        resp = session.get(url, headers=headers, allow_redirects=False, timeout=common.TIMEOUT)
        hops.append(f"{resp.status_code} {url} [set-cookie: {cookie_names(resp)}]")
        location = resp.headers.get("Location")
        if resp.status_code in (301, 302, 303, 307, 308) and location:
            url = urljoin(url, location)
            continue
        return "\n      -> ".join(hops), resp.text
    return "\n      -> ".join(hops) + " (too many redirects)", ""


def run_variant(name: str, make_session, query: str, warmup: bool, wait: float, headers: dict, extra: dict | None = None):
    say(f"\n== {name}")
    try:
        session = make_session()
        if warmup:
            session.get(INDEX, timeout=common.TIMEOUT)
            if wait:
                time.sleep(wait)
        params = {"stext": query, **(extra or {})}
        chain, html = get_chain(session, f"{BASE}/aprok/keres.php?{urlencode(params)}", headers)
        ads = hardverapro.parse(html)
        hits = [a for a in ads if title_matches(a.title, query)]
        main = '"pageType":"mainpage"' in html
        say(f"   chain: {chain}")
        say(f"   ads on page: {len(ads)}, matching '{query}': {len(hits)}, looks like main page: {main}")
        for a in hits[:3]:
            say(f"     - {a.title} ({a.price_text})")
        say("   RESULT: " + ("WORKS" if hits else "no results"))
    except Exception as exc:  # noqa: BLE001
        say(f"   ERROR: {type(exc).__name__}: {str(exc)[:200]}")


def main() -> None:
    query = " ".join(sys.argv[1:]) or "kave"
    say(f"Hardverapró diagnosis, query: {query!r}, python {sys.version.split()[0]}")
    try:
        import curl_cffi

        say(f"curl_cffi {curl_cffi.__version__}")
    except ImportError:
        say("curl_cffi not installed")
    nav = {"Referer": INDEX, "Sec-Fetch-Site": "same-origin", "Sec-Fetch-Mode": "navigate", "Sec-Fetch-User": "?1", "Sec-Fetch-Dest": "document"}
    form = {
        "stcid_text": "", "stcid": "", "stmid_text": "", "stmid": "", "minprice": "", "maxprice": "",
        "cmpid_text": "", "cmpid": "", "usrid_text": "", "usrid": "", "stext_none": "",
    }
    variants = [
        ("A chrome, no warm-up", lambda: curl_session("chrome"), False, 0, {}, None),
        ("B chrome, warm-up, immediately (app today)", lambda: curl_session("chrome"), True, 0, {"Referer": INDEX}, form),
        ("C chrome, warm-up, wait 3 s, navigation headers", lambda: curl_session("chrome"), True, 3, nav, form),
        ("D chrome, warm-up, wait 8 s, navigation headers", lambda: curl_session("chrome"), True, 8, nav, form),
        ("E firefox profile, warm-up, wait 3 s", lambda: curl_session("firefox"), True, 3, nav, form),
        ("F safari profile, warm-up, wait 3 s", lambda: curl_session("safari"), True, 3, nav, form),
        ("G python requests, warm-up, wait 3 s", requests_session, True, 3, {"Referer": INDEX}, form),
        ("H chrome, warm-up, wait 3 s, title-only search", lambda: curl_session("chrome"), True, 3, nav, {**form, "search_title": "1"}),
    ]
    for name, make, warm, wait, headers, extra in variants:
        run_variant(name, make, query, warm, wait, headers, extra)
    out = ROOT / "debug" / "diag_hardverapro.txt"
    out.parent.mkdir(exist_ok=True)
    out.write_text("\n".join(LINES) + "\n", encoding="utf-8")
    print(f"\nSaved to {out}")


if __name__ == "__main__":
    main()
