"""Shared types and helpers for every marketplace source."""

from __future__ import annotations

import json
import os
import re
import shutil
import tempfile
import unicodedata
from dataclasses import asdict, dataclass, field
from typing import Any, Iterable, Iterator



def ascii_ca_bundle(src: str, candidate_dirs: Iterable[str | None]) -> str | None:
    """Path of the CA bundle that libcurl on Windows can open.

    libcurl cannot open a CA file whose path has non-ASCII characters (e.g. a
    folder named "piac-kereső" fails with curl error 77), so such a bundle is
    copied into the first writable ASCII-only folder. None if there is none.
    """
    if src.isascii():
        return src
    for folder in candidate_dirs:
        if not folder or not folder.isascii():
            continue
        dst = os.path.join(folder, "piackereso-cacert.pem")
        try:
            if not os.path.exists(dst) or os.path.getsize(dst) != os.path.getsize(src):
                shutil.copyfile(src, dst)
            return dst
        except OSError:
            continue
    return None


def _pick_backend():
    try:  # curl_cffi mimics a real Chrome TLS handshake; sites with bot protection prefer it.
        import certifi
        from curl_cffi import requests as curl_requests
    except ImportError:
        curl_requests = None
    if curl_requests is not None:
        dirs = (tempfile.gettempdir(), os.environ.get("PUBLIC"), os.environ.get("PROGRAMDATA"), os.path.expanduser("~"))
        ca = ascii_ca_bundle(certifi.where(), dirs)
        if ca:
            return curl_requests, {"impersonate": "chrome", "verify": ca}
    import requests  # plain requests works for most sites

    return requests, {}


_http, _SESSION_ARGS = _pick_backend()

USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
)
TIMEOUT = 15


@dataclass
class Listing:
    source: str
    id: str
    title: str
    url: str
    price: int | None = None  # whole forints; None when the ad has no usable price
    price_text: str = ""
    location: str = ""
    posted: str = ""
    image: str = ""
    extra: str = ""  # e.g. brand / size on Vinted
    image_fallback: str = ""  # shown if `image` (an upgraded, bigger variant) fails to load

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class SearchQuery:
    text: str
    min_price: int | None = None
    max_price: int | None = None
    page: int = 1
    fb_city: str = "budapest"


@dataclass
class SourceResult:
    source: str
    name: str
    search_url: str  # the same search on the site itself, always shown to the user
    listings: list[Listing] = field(default_factory=list)
    error: str = ""
    link_only: bool = False  # True when only the link is usable (Facebook without results)
    note: str = ""  # informational message shown under the source name

    def to_dict(self) -> dict[str, Any]:
        d = asdict(self)
        d["count"] = len(self.listings)
        return d


def new_session():
    s = _http.Session(**_SESSION_ARGS)
    s.headers.update({"Accept-Language": "hu-HU,hu;q=0.9,en;q=0.8"})
    if "impersonate" not in _SESSION_ARGS:  # curl_cffi sends Chrome's own matching headers
        s.headers.update(
            {
                "User-Agent": USER_AGENT,
                "Accept": "text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8",
            }
        )
    return s


# Set by `server.py --debug`: every page fetched is saved here so it can be inspected.
DEBUG_DIR: str | None = None


def _debug_dump(url: str, resp) -> None:
    from datetime import datetime
    from urllib.parse import urlparse

    os.makedirs(DEBUG_DIR, exist_ok=True)
    parts = urlparse(url)
    name = re.sub(r"[^A-Za-z0-9]+", "_", parts.netloc + parts.path).strip("_")[:80]
    with open(os.path.join(DEBUG_DIR, name + ".html"), "w", encoding="utf-8") as f:
        f.write(resp.text)
    cookie_names = sorted({c.split("=", 1)[0].strip() for c in resp.headers.get("Set-Cookie", "").split(",") if "=" in c})
    with open(os.path.join(DEBUG_DIR, "log.txt"), "a", encoding="utf-8") as f:
        f.write(
            f"{datetime.now():%Y-%m-%d %H:%M:%S} {resp.status_code} {url}\n"
            f"    final url: {resp.url}\n    bytes: {len(resp.content)}  saved: {name}.html"
            f"  set-cookie names: {', '.join(cookie_names) or '-'}\n"
        )


def fetch(session, url: str, method: str = "GET", **kwargs) -> Any:
    resp = session.request(method, url, timeout=TIMEOUT, **kwargs)
    if DEBUG_DIR:
        try:
            _debug_dump(url, resp)
        except OSError:
            pass
    if resp.status_code >= 400:
        raise RuntimeError(f"HTTP {resp.status_code} ({url})")
    return resp


_DIGITS = re.compile(r"\d")


def parse_price(text: Any) -> int | None:
    """'85 000 Ft' -> 85000, '12.500,- Ft' -> 12500, '1 299,99' -> 1299, 'Ingyenes' -> 0."""
    if text is None:
        return None
    if isinstance(text, (int, float)):
        return int(text)
    s = str(text).strip()
    if not s:
        return None
    if re.search(r"ingyen|free", s, re.I):
        return 0
    # Drop a decimal part such as ",99" or ".00" at the end of the number.
    s = re.sub(r"[.,]\d{1,2}(?!\d)", "", s)
    digits = "".join(_DIGITS.findall(s))
    return int(digits) if digits else None


def image_candidates(url: str) -> list[str]:
    """Bigger variants of a known thumbnail URL first, then the URL itself.

    Jófogás serves every photo as img.jofogas.hu/thumbs/<name> (small) and
    img.jofogas.hu/images/<name> (full size).
    """
    if "img.jofogas.hu/thumbs/" in url:
        return [url.replace("/thumbs/", "/images/", 1), url]
    return [url] if url else []


def format_huf(price: int | None) -> str:
    return "" if price is None else f"{price:,} Ft".replace(",", " ")


def fold(text: str) -> str:
    """Lower-case and strip accents: 'Páramentesítő' -> 'paramentesito'."""
    decomposed = unicodedata.normalize("NFKD", text.lower())
    return "".join(c for c in decomposed if not unicodedata.combining(c))


def title_matches(title: str, query: str) -> bool:
    """True if every word of the query occurs in the title, ignoring case and accents."""
    words = re.findall(r"\w+", fold(query))
    folded = fold(title)
    return all(w in folded for w in words)


# Zero-width characters some sites (Hardverapró) sprinkle into text against scrapers.
_INVISIBLE = re.compile("[\u200b-\u200f\u2060\ufeff\u00ad]")


def clean(text: Any) -> str:
    return re.sub(r"\s+", " ", _INVISIBLE.sub("", str(text or ""))).strip()


def clean_block(text: Any) -> str:
    """Like clean() but keeps line breaks (for ad descriptions)."""
    lines = (re.sub(r"[ \t\r\f\v]+", " ", line).strip() for line in _INVISIBLE.sub("", str(text or "")).split("\n"))
    return re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip()


def in_price_range(listing: Listing, q: SearchQuery) -> bool:
    if listing.price is None:
        return True  # keep "price on request" ads; the user can judge them
    if q.min_price is not None and listing.price < q.min_price:
        return False
    if q.max_price is not None and listing.price > q.max_price:
        return False
    return True


def iter_json_ld(soup) -> Iterator[Any]:
    for tag in soup.find_all("script", type="application/ld+json"):
        try:
            yield json.loads(tag.string or tag.get_text() or "")
        except (ValueError, TypeError):
            continue


def walk_json(node: Any) -> Iterator[dict]:
    """Yield every dict inside a JSON tree (depth-first)."""
    stack = [node]
    while stack:
        cur = stack.pop()
        if isinstance(cur, dict):
            yield cur
            stack.extend(cur.values())
        elif isinstance(cur, list):
            stack.extend(cur)


def first(d: dict, keys: Iterable[str]) -> Any:
    for k in keys:
        v = d.get(k)
        if v not in (None, "", [], {}):
            return v
    return None


def dedupe(listings: Iterable[Listing]) -> list[Listing]:
    seen: set[str] = set()
    out = []
    for item in listings:
        key = item.url or item.id
        if key in seen:
            continue
        seen.add(key)
        out.append(item)
    return out
