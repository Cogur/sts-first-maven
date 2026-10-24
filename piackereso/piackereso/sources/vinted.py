"""Vinted (vinted.hu).

The catalog page is rendered in the browser, but the site's own JSON endpoint
(/api/v2/catalog/items) answers once the session holds the access_token_web
cookie that a normal visit to the home page sets. Installing curl_cffi
(see requirements.txt) makes the requests look like Chrome, which Vinted's bot
protection lets through far more often than plain requests.
"""

from __future__ import annotations

from urllib.parse import urlencode

from ..common import Listing, SearchQuery, SourceResult, clean, fetch, format_huf, new_session, parse_price

KEY = "vinted"
NAME = "Vinted"
BASE = "https://www.vinted.hu"
PER_PAGE = 48


def _params(q: SearchQuery) -> dict:
    params: dict = {"search_text": q.text, "order": "newest_first"}
    if q.min_price is not None:
        params["price_from"] = q.min_price
    if q.max_price is not None:
        params["price_to"] = q.max_price
    if q.min_price is not None or q.max_price is not None:
        params["currency"] = "HUF"
    return params


def search_url(q: SearchQuery) -> str:
    params = _params(q)
    if q.page > 1:
        params["page"] = q.page
    return f"{BASE}/catalog?{urlencode(params)}"


def api_url(q: SearchQuery) -> str:
    params = _params(q)
    params.update({"page": q.page, "per_page": PER_PAGE})
    return f"{BASE}/api/v2/catalog/items?{urlencode(params)}"


def parse(data: dict) -> list[Listing]:
    out = []
    for it in data.get("items") or []:
        price_raw = it.get("price")
        currency = it.get("currency") or "HUF"
        if isinstance(price_raw, dict):  # newer API: {"amount": "5000.0", "currency_code": "HUF"}
            currency = price_raw.get("currency_code") or currency
            price_raw = price_raw.get("amount")
        price = parse_price(price_raw)
        price_text = format_huf(price) if currency == "HUF" else f"{price_raw} {currency}"
        photo = it.get("photo") or {}
        image = photo.get("url") or ""
        for thumb in photo.get("thumbnails") or []:
            if thumb.get("type") in ("thumb310x430", "thumb310"):
                image = thumb.get("url") or image
        url = it.get("url") or f"{BASE}/items/{it.get('id')}"
        login = (it.get("user") or {}).get("login")
        extra = " · ".join(
            x for x in (it.get("brand_title"), it.get("size_title"), it.get("status"), login and f"@{login}") if x
        )
        out.append(
            Listing(
                source=KEY,
                id=str(it.get("id")),
                title=clean(it.get("title")),
                url=url if url.startswith("http") else BASE + url,
                price=price if currency == "HUF" else None,
                price_text=price_text,
                image=image,
                extra=extra,
            )
        )
    return out


def search(q: SearchQuery) -> SourceResult:
    res = SourceResult(source=KEY, name=NAME, search_url=search_url(q))
    session = new_session()
    fetch(session, BASE + "/")  # sets the access_token_web cookie the API needs
    resp = fetch(
        session,
        api_url(q),
        headers={"Accept": "application/json, text/plain, */*", "Referer": search_url(q)},
    )
    res.listings = parse(resp.json())
    return res
