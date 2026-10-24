"""Hardverapró (hardverapro.hu): server-rendered HTML, one <li class="media"> per ad."""

from __future__ import annotations

import re
from urllib.parse import urlencode, urljoin

from bs4 import BeautifulSoup

from ..common import Listing, SearchQuery, SourceResult, clean, fetch, new_session, parse_price, title_matches

KEY = "hardverapro"
NAME = "Hardverapró"
BASE = "https://hardverapro.hu"
PER_PAGE = 50  # hardverapro.hu lists 50 ads per page; "offset" pages through them


def search_url(q: SearchQuery) -> str:
    params = {"stext": q.text}
    if q.min_price is not None:
        params["minprice"] = q.min_price
    if q.max_price is not None:
        params["maxprice"] = q.max_price
    if q.page > 1:
        params["offset"] = (q.page - 1) * PER_PAGE
    return f"{BASE}/aprok/keres.php?{urlencode(params)}"


_AD_HREF = re.compile(r"/apro/[^/]+/[^\"']*\.html")


def parse(html: str) -> list[Listing]:
    soup = BeautifulSoup(html, "html.parser")
    rows = soup.select("li.media[data-uadid]") or soup.select(".uad-list li.media") or soup.select("li.media")
    out = []
    for row in rows:
        link = row.select_one(".uad-title a, .uad-col-title a, h1 a, h4 a") or row.find("a", href=_AD_HREF)
        if not link or not link.get("href"):
            continue
        url = urljoin(BASE, link["href"])
        img = row.select_one(".uad-image img, img")
        image = ""
        if img:
            image = img.get("data-src") or img.get("data-retina-url") or img.get("src") or ""
            image = urljoin(BASE, image) if image else ""
        price_el = row.select_one(".uad-price")
        price_text = clean(price_el.get_text(" ")) if price_el else ""
        city = row.select_one(".uad-cities, .uad-city, .uad-light")
        time_el = row.select_one(".uad-time time, .uad-time, time")
        posted = ""
        if time_el:
            posted = clean(time_el.get_text(" ")) or time_el.get("title", "") or time_el.get("datetime", "")
            posted = posted.strip("–- ")  # "– Előresorolva" -> "Előresorolva"
        out.append(
            Listing(
                source=KEY,
                id=row.get("data-uadid") or url,
                title=clean(link.get("title") or link.get_text(" ")),
                url=url,
                price=parse_price(price_text),
                price_text=price_text,
                location=clean(city.get_text(" ")) if city else "",
                posted=posted,
                image=image,
            )
        )
    return out


def search(q: SearchQuery) -> SourceResult:
    url = search_url(q)
    res = SourceResult(source=KEY, name=NAME, search_url=url)
    resp = fetch(new_session(), url)
    # The page also lists paid "Előresorolva" ads that have nothing to do with the
    # search; the site searches titles, so keep only ads whose title has every word.
    res.listings = [item for item in parse(resp.text) if title_matches(item.title, q.text)]
    return res
