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


def search_form(html: str, q: SearchQuery) -> tuple[str, str, list[tuple[str, str]]] | None:
    """The site's own search form, filled in as a browser would submit it.

    keres.php?stext=... alone gets redirected to the ad index for a script, so
    the request carries every field of the form (hidden ones included).
    Returns (method, action URL, fields) or None if the page has no such form.
    """
    soup = BeautifulSoup(html, "html.parser")
    box = soup.find("input", attrs={"name": "stext"})
    form = box.find_parent("form") if box else None
    if form is None:
        return None
    fields: list[tuple[str, str]] = []
    for el in form.find_all(["input", "select", "textarea"]):
        name = el.get("name")
        if not name or el.has_attr("disabled"):
            continue
        if el.name == "select":
            opt = el.find("option", selected=True) or el.find("option")
            fields.append((name, (opt.get("value") if opt and opt.has_attr("value") else opt.get_text()) if opt else ""))
        elif el.name == "textarea":
            fields.append((name, el.get_text()))
        else:
            kind = (el.get("type") or "text").lower()
            if kind in ("submit", "button", "image", "file", "reset"):
                continue
            if kind in ("checkbox", "radio") and not el.has_attr("checked"):
                continue
            fields.append((name, el.get("value", "on" if kind in ("checkbox", "radio") else "")))
    wanted = {"stext": q.text}
    if q.min_price is not None:
        wanted["minprice"] = str(q.min_price)
    if q.max_price is not None:
        wanted["maxprice"] = str(q.max_price)
    if q.page > 1:
        wanted["offset"] = str((q.page - 1) * PER_PAGE)
    for key, value in wanted.items():
        idx = next((i for i, (n, _) in enumerate(fields) if n == key), None)
        if idx is None:
            fields.append((key, value))
        else:
            fields[idx] = (key, value)
    method = (form.get("method") or "get").upper()
    action = urljoin(f"{BASE}/aprok/index.html", form.get("action") or "keres.php")
    return method, action, fields


def search(q: SearchQuery) -> SourceResult:
    url = search_url(q)
    res = SourceResult(source=KEY, name=NAME, search_url=url)
    session = new_session()
    index_url = f"{BASE}/aprok/index.html"
    form = None
    try:
        form = search_form(fetch(session, index_url).text, q)
    except Exception:  # noqa: BLE001 - fall back to the plain search URL
        pass
    headers = {"Referer": index_url}
    if form is None:
        resp = fetch(session, url, headers=headers)
    elif form[0] == "POST":
        resp = fetch(session, form[1], method="POST", data=form[2], headers=headers)
    else:
        resp = fetch(session, f"{form[1]}?{urlencode(form[2])}", headers=headers)
    found = parse(resp.text)
    # The page also lists paid "Előresorolva" ads that have nothing to do with the
    # search; the site searches titles, so keep only ads whose title has every word.
    res.listings = [item for item in found if title_matches(item.title, q.text)]
    final = str(resp.url)
    if final.rstrip("/").endswith("/aprok/index.html") or final.rstrip("/") == BASE:
        res.note = "A Hardverapró a keresést a nyitóoldalra irányította" + ("" if form else " (keresőűrlap nem található)")
    elif found and not res.listings:
        res.note = f"{len(found)} hirdetés jött, egyik sem illett a keresésre"
    return res
