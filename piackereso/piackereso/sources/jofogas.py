"""Jófogás (jofogas.hu).

The result page markup has changed several times, so parsing tries, in order:
1. the classic list markup (div.list-item / h3.item-title / .price-value),
2. schema.org JSON-LD embedded in the page,
3. any embedded JSON state (__NEXT_DATA__ and similar) holding ad objects,
4. a last resort: every link that looks like an ad (".../<slug>_<id>.htm").
"""

from __future__ import annotations

import json
import re
from urllib.parse import urlencode, urljoin

from bs4 import BeautifulSoup

from ..common import (
    Listing,
    SearchQuery,
    SourceResult,
    clean,
    dedupe,
    fetch,
    first,
    format_huf,
    iter_json_ld,
    new_session,
    parse_price,
    walk_json,
)

KEY = "jofogas"
NAME = "Jófogás"
BASE = "https://www.jofogas.hu"

_AD_URL = re.compile(r"jofogas\.hu/.+_(\d{6,})\.htm")


def search_url(q: SearchQuery) -> str:
    params: dict = {"q": q.text}
    if q.min_price is not None:
        params["min_price"] = q.min_price
    if q.max_price is not None:
        params["max_price"] = q.max_price
    if q.page > 1:
        params["o"] = q.page
    return f"{BASE}/magyarorszag?{urlencode(params)}"


def _ad_id(url: str) -> str:
    m = _AD_URL.search(url)
    return m.group(1) if m else url


def _img(el) -> str:
    if not el:
        return ""
    return el.get("data-src") or el.get("data-original") or el.get("src") or ""


def _parse_markup(soup) -> list[Listing]:
    out = []
    for row in soup.select("div.list-item, div.reListElement, article.list-item"):
        link = row.select_one("h3.item-title a, .item-title a, a.subject, a[href*='.htm']")
        if not link or not link.get("href"):
            continue
        url = urljoin(BASE, link["href"])
        price_el = row.select_one(".price-value, .item-price, .price")
        price_text = clean(price_el.get_text(" ")) if price_el else ""
        city = row.select_one(".cityname, .item-location, .location")
        time_el = row.select_one(".time, .item-date, time")
        out.append(
            Listing(
                source=KEY,
                id=_ad_id(url),
                title=clean(link.get("title") or link.get_text(" ")),
                url=url,
                price=parse_price(price_text),
                price_text=price_text,
                location=clean(city.get_text(" ")) if city else "",
                posted=clean(time_el.get_text(" ")) if time_el else "",
                image=_img(row.select_one("img")),
            )
        )
    return out


def _from_json_obj(d: dict) -> Listing | None:
    """Turn any dict that looks like an ad (title + ad URL) into a Listing."""
    url = first(d, ("url", "link", "href", "share_link", "adUrl"))
    title = first(d, ("subject", "title", "name"))
    if not isinstance(url, str) or not isinstance(title, str) or not _AD_URL.search(urljoin(BASE, url)):
        return None
    url = urljoin(BASE, url)
    price = first(d, ("price", "price_value", "priceValue", "offers"))
    if isinstance(price, dict):  # schema.org Offer or {"value": ..}
        price = first(price, ("price", "value", "amount", "lowPrice"))
    image = first(d, ("image", "thumbnail", "image_url", "imageUrl", "images"))
    if isinstance(image, list):
        image = image[0] if image else ""
    if isinstance(image, dict):
        image = first(image, ("url", "src", "contentUrl")) or ""
    location = first(d, ("city", "location", "region", "address"))
    if isinstance(location, dict):
        location = first(location, ("city", "name", "addressLocality", "label")) or ""
    price = parse_price(price)
    return Listing(
        source=KEY,
        id=_ad_id(url),
        title=clean(title),
        url=url,
        price=price,
        price_text=format_huf(price),
        location=clean(location) if isinstance(location, str) else "",
        posted=clean(first(d, ("date", "list_time", "datePosted", "created_at")) or ""),
        image=image if isinstance(image, str) else "",
    )


def _parse_json(soup) -> list[Listing]:
    blobs = list(iter_json_ld(soup))
    for tag in soup.find_all("script"):
        text = tag.string or ""
        if tag.get("id") == "__NEXT_DATA__" or tag.get("type") == "application/json":
            try:
                blobs.append(json.loads(text))
            except ValueError:
                pass
    out = []
    for blob in blobs:
        for d in walk_json(blob):
            item = _from_json_obj(d)
            if item:
                out.append(item)
    return out


def _parse_links(soup) -> list[Listing]:
    out = []
    for a in soup.find_all("a", href=True):
        url = urljoin(BASE, a["href"])
        title = clean(a.get("title") or a.get_text(" "))
        if _AD_URL.search(url) and len(title) > 3:
            out.append(Listing(source=KEY, id=_ad_id(url), title=title, url=url))
    return out


def parse(html: str) -> list[Listing]:
    soup = BeautifulSoup(html, "html.parser")
    for strategy in (_parse_markup, _parse_json, _parse_links):
        found = dedupe(strategy(soup))
        if found:
            return found
    return []


def search(q: SearchQuery) -> SourceResult:
    url = search_url(q)
    res = SourceResult(source=KEY, name=NAME, search_url=url)
    resp = fetch(new_session(), url)
    res.listings = parse(resp.text)
    return res
