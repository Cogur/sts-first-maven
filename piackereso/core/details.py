"""Ad detail pages: a bigger image and the description, for the AI export.

The search results only carry a title, a price and a small thumbnail. Each
ad's own page usually has more: OpenGraph tags (og:image, og:description),
schema.org JSON-LD, the description block, or embedded JSON. Extraction is
generic so it survives small markup changes; anything missing falls back to
what the search result already had.
"""

from __future__ import annotations

import json
import threading
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from urllib.parse import urljoin, urlparse

from bs4 import BeautifulSoup

from . import settings
from .common import clean_block, fetch, iter_json_ld, new_session, walk_json
from .sources import hardverapro

MAX_DESCRIPTION = 1200
MAX_IMAGES = 3

# Only these hosts are fetched (ad pages and their images), so a request to the
# local server cannot make it fetch arbitrary addresses.
ALLOWED_HOSTS = (
    "hardverapro.hu", "rios.hu",
    "jofogas.hu",
    "vinted.hu", "vinted.net",
    "facebook.com", "fbcdn.net",
)

# Site-wide texts that some pages put in og:description instead of the ad's own.
_GENERIC_DESCRIPTIONS = ("adatbázisában", "Itt megtalálod, amit keresel")

_DESCRIPTION_SELECTORS = (
    ".rtif-content", "[itemprop=description]", ".uad-content", ".description",
    "#description", ".item-description", ".ad-description", ".adDescription",
)


@dataclass
class Details:
    description: str = ""
    images: list[str] = field(default_factory=list)


def allowed(url: str) -> bool:
    host = (urlparse(url).hostname or "").lower()
    return urlparse(url).scheme == "https" and any(host == h or host.endswith("." + h) for h in ALLOWED_HOSTS)


def _meta(soup, key: str) -> list[str]:
    tags = soup.find_all("meta", attrs={"property": key}) + soup.find_all("meta", attrs={"name": key})
    return [t.get("content", "").strip() for t in tags if t.get("content")]


def _usable_description(text: str) -> bool:
    return len(text) > 20 and not any(g in text for g in _GENERIC_DESCRIPTIONS)


def extract(html: str, page_url: str) -> Details:
    soup = BeautifulSoup(html, "html.parser")
    texts: list[str] = []
    images: list[str] = []

    # 1. The page's description block (largest match wins).
    for sel in _DESCRIPTION_SELECTORS:
        for el in soup.select(sel):
            texts.append(clean_block(el.get_text("\n")))

    # 2. schema.org data and any embedded JSON state.
    blobs = list(iter_json_ld(soup))
    for tag in soup.find_all("script", type="application/json"):
        try:
            blobs.append(json.loads(tag.string or ""))
        except ValueError:
            pass
    preferred = ""
    for blob in blobs:
        for d in walk_json(blob):
            seller_text = d.get("redacted_description")  # Facebook Marketplace's ad text
            if isinstance(seller_text, dict) and isinstance(seller_text.get("text"), str):
                preferred = preferred or clean_block(seller_text["text"])
            for key in ("description", "body"):
                if isinstance(d.get(key), str):
                    texts.append(clean_block(BeautifulSoup(d[key], "html.parser").get_text("\n")))
            if d.get("@type") in ("Product", "Offer", "IndividualProduct"):
                img = d.get("image")
                for candidate in img if isinstance(img, list) else [img]:
                    if isinstance(candidate, dict):
                        candidate = candidate.get("url") or candidate.get("contentUrl")
                    if isinstance(candidate, str):
                        images.append(candidate)

    description = preferred or max((t for t in texts if _usable_description(t)), key=len, default="")
    if not description:  # 3. the short OpenGraph summary
        description = next((clean_block(t) for t in _meta(soup, "og:description") + _meta(soup, "description") if _usable_description(t)), "")

    images = _meta(soup, "og:image") + images
    # Hardverapró keeps the ad's photos under /dl/uad/ on its CDN.
    for el in soup.select("a[href*='/dl/uad/'], img[src*='/dl/uad/']"):
        images.append(el.get("href") or el.get("src"))

    seen: set[str] = set()
    unique = []
    for img in images:
        if not img:
            continue
        absolute = urljoin(page_url, img.strip())
        if absolute in seen or "logo" in absolute.lower() or absolute.lower().endswith(".svg"):
            continue
        seen.add(absolute)
        unique.append(absolute)
    if len(description) > MAX_DESCRIPTION:
        description = description[:MAX_DESCRIPTION].rsplit(" ", 1)[0] + " …"
    return Details(description=description, images=unique[:MAX_IMAGES])


_cache: dict[str, Details] = {}
_cache_lock = threading.Lock()
_local = threading.local()


def _session():
    if getattr(_local, "session", None) is None:
        _local.session = new_session()
    return _local.session


def _page(source: str, url: str):
    if source == "hardverapro":
        return hardverapro.fetch_page(url)
    headers = {}
    if source == "facebook":
        cookie = settings.facebook_cookie()
        if cookie:
            headers["Cookie"] = cookie
    return fetch(_session(), url, headers=headers)


def get(source: str, url: str) -> Details:
    """Details of one ad; empty Details if the page cannot be read."""
    with _cache_lock:
        if url in _cache:
            return _cache[url]
    details = Details()
    if allowed(url):
        try:
            resp = _page(source, url)
            if resp is not None:
                details = extract(resp.text, url)
        except Exception:  # noqa: BLE001 - the export uses the search result instead
            pass
    with _cache_lock:
        if len(_cache) > 500:
            _cache.clear()
        _cache[url] = details
    return details


def get_many(items: list[dict]) -> list[Details]:
    """Details for each item, in order. Hardverapró pages go one at a time (its own lock)."""
    with ThreadPoolExecutor(max_workers=4) as pool:
        return list(pool.map(lambda it: get(it.get("source", ""), it.get("url", "")), items))
