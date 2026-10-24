"""Facebook Marketplace.

The search page embeds its results as JSON (<script type="application/json">),
each ad a dict with "marketplace_listing_title". Facebook often shows a login
wall instead of results to logged-out visitors, so:

- without a login cookie the app tries once logged out, and if no ads come back
  it falls back to just linking the search (link_only);
- with the user's own c_user + xs cookies (entered in the app's settings, stored
  in settings.local.json) the request is made as that user.

Automated access is against Facebook's terms; with a cookie, the risk (a
checkpoint or restriction) falls on the user's account. The README says so.
"""

from __future__ import annotations

import json
from urllib.parse import quote, urlencode

from bs4 import BeautifulSoup

from .. import settings
from ..common import Listing, SearchQuery, SourceResult, clean, fetch, first, new_session, parse_price, walk_json

KEY = "facebook"
NAME = "Facebook Marketplace"
BASE = "https://www.facebook.com"


def search_url(q: SearchQuery) -> str:
    params: dict = {"query": q.text, "exact": "false"}
    if q.min_price is not None:
        params["minPrice"] = q.min_price
    if q.max_price is not None:
        params["maxPrice"] = q.max_price
    city = quote((q.fb_city or "budapest").strip().lower())
    return f"{BASE}/marketplace/{city}/search?{urlencode(params)}"


def _listing(d: dict) -> Listing | None:
    title = d.get("marketplace_listing_title") or d.get("custom_title")
    ad_id = d.get("id")
    if not isinstance(title, str) or not ad_id or d.get("is_sold"):
        return None
    price = d.get("listing_price") or {}
    amount = parse_price(price.get("amount")) if isinstance(price, dict) else None
    price_text = clean(first(price, ("formatted_amount", "amount_with_offset_in_currency")) or "") if isinstance(price, dict) else ""
    geo = ((d.get("location") or {}).get("reverse_geocode") or {}) if isinstance(d.get("location"), dict) else {}
    photo = d.get("primary_listing_photo") or {}
    image = ((photo.get("image") or {}).get("uri") or "") if isinstance(photo, dict) else ""
    return Listing(
        source=KEY,
        id=str(ad_id),
        title=clean(title),
        url=f"{BASE}/marketplace/item/{ad_id}/",
        price=amount,
        price_text=price_text,
        location=clean(first(geo, ("city", "state")) or "") if isinstance(geo, dict) else "",
        image=image,
    )


def parse(html: str) -> list[Listing]:
    soup = BeautifulSoup(html, "html.parser")
    out: dict[str, Listing] = {}
    for tag in soup.find_all("script"):
        text = tag.string or ""
        if "marketplace_listing_title" not in text:
            continue
        try:
            blob = json.loads(text)
        except ValueError:
            continue
        for d in walk_json(blob):
            if "marketplace_listing_title" in d:
                item = _listing(d)
                if item and item.id not in out:
                    out[item.id] = item
    return list(out.values())


def _looks_like_login(html: str) -> bool:
    return 'id="login_form"' in html or "/login/?next=" in html[:20000]


def search(q: SearchQuery) -> SourceResult:
    url = search_url(q)
    res = SourceResult(source=KEY, name=NAME, search_url=url)
    if q.page > 1:  # one page of results only; Facebook loads more through a private API
        return res
    cookie = settings.facebook_cookie()
    headers = {"Cookie": cookie} if cookie else {}
    try:
        html = fetch(new_session(), url, headers=headers).text
        res.listings = parse(html)
    except Exception as exc:  # noqa: BLE001 - any failure falls back to the link
        if cookie:
            raise
        html = ""
        res.note = f"Kijelentkezve nem sikerült ({str(exc)[:80]})."
    if res.listings:
        return res
    if cookie and _looks_like_login(html):
        raise RuntimeError("A Facebook belépés lejárt: frissítsd a c_user és xs sütit a Beállításokban.")
    res.link_only = True
    if not res.note:
        res.note = "Bejelentkezés nélkül nem adott találatot." if not cookie else "Nem találtam hirdetést az oldalon."
    return res
