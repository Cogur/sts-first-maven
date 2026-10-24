"""AI export: a PDF of a batch of ads with images, built to be pasted into an AI chat.

The batch size is chosen in the UI (DEFAULT_BATCH, at most MAX_BATCH ads).

Page 1 carries the instructions for the AI, price statistics and a one-line
overview of every ad; then each ad follows with up to three images, its
details and description. Images are shrunk to IMAGE_MAX_PX so a batch stays a
few MB: small enough for any chat upload, big enough to read a model plate.
"""

from __future__ import annotations

import io
import re
import statistics
import threading
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse

from fpdf import FPDF
from PIL import Image

from . import details as ad_details
from .common import fetch, fold, format_huf, image_candidates, new_session
from .sources import SOURCES

DEFAULT_BATCH = 30
# ~3 ads per page: 100 ads stay well under the 100-page PDF limit some AI chats have.
MAX_BATCH = 100
IMAGE_MAX_PX = 800
IMAGE_QUALITY = 70
FONT_DIR = Path(__file__).resolve().parent / "fonts"
SHORT_NAMES = {"hardverapro": "Hardverapró", "jofogas": "Jófogás", "vinted": "Vinted", "facebook": "Facebook"}

INSTRUCTIONS = """Ez a dokumentum használt piaci hirdetéseket tartalmaz (Hardverapró, Jófogás, Vinted, Facebook Marketplace) a fenti keresésre. Minden hirdetésnél van sorszám (#), cím, ár, hely, link, leírás (ha elérhető) és kép(ek). Segíts dönteni a vásárlásról:

1. Típus: minden hirdetésnél add meg a termék pontos típusát (márka + modell) a cím, a leírás és a képek alapján. Ha nem egyértelmű, csak annyit adj meg, amennyi biztos (pl. csak a márkát), ha semmit, írd: „nem meghatározható”. Ne találgass; jelöld, ha valamit a képről következtetsz.
2. Új ár: ha tudsz webes keresést használni, nézd meg, kapható-e még újként Magyarországon, és mennyi a legalacsonyabb és az átlagos új ár (pl. Árukereső alapján, forrással). Ha nem tudsz keresni, írd meg, és ne becsülj számot.
3. Értékelés: mennyire jó ár a használt ár (az új árhoz és a többi hirdetéshez képest), mit tudunk az állapotról, mi hiányzik vagy gyanús (pl. irreálisan olcsó, hiányos leírás, csak „keresem” hirdetés).
4. Összegzés: táblázat (# | típus | használt ár | új ár min / átlag | megjegyzés), majd a 3 legjobb vétel indoklással, és mire kérdezzek rá az eladóknál.

Ha a dokumentum csak egy része a találatoknak (lásd „Csomag”), a többi csomagot külön kapod; a végén összesíthetsz."""

_IMG_CACHE: dict[str, tuple[bytes, int, int] | None] = {}
_img_lock = threading.Lock()
_local = threading.local()


def _session():
    if getattr(_local, "session", None) is None:
        _local.session = new_session()
    return _local.session


def load_image(url: str) -> tuple[bytes, int, int] | None:
    """Downloaded, shrunk JPEG (bytes, width px, height px), or None."""
    with _img_lock:
        if url in _IMG_CACHE:
            return _IMG_CACHE[url]
    result = None
    if ad_details.allowed(url):
        try:
            parts = urlparse(url)
            raw = fetch(_session(), url, headers={"Referer": f"{parts.scheme}://{parts.hostname}/"}).content
            with Image.open(io.BytesIO(raw)) as im:
                im = im.convert("RGB")
                im.thumbnail((IMAGE_MAX_PX, IMAGE_MAX_PX))
                out = io.BytesIO()
                im.save(out, "JPEG", quality=IMAGE_QUALITY, optimize=True)
                result = (out.getvalue(), im.width, im.height)
        except Exception:  # noqa: BLE001 - an ad without a picture is still useful
            result = None
    with _img_lock:
        if len(_IMG_CACHE) > 400:
            _IMG_CACHE.clear()
        _IMG_CACHE[url] = result
    return result


def load_first(urls: list[str]) -> tuple[bytes, int, int] | None:
    """The first of `urls` that downloads as an image (bigger variants come first)."""
    for url in urls:
        img = load_image(url)
        if img:
            return img
    return None


_UNSUPPORTED = re.compile("[\U00010000-\U0010ffff️‍]")  # emoji etc.: not in the font


def _t(text) -> str:
    return _UNSUPPORTED.sub("", str(text or ""))


def price_stats(prices: list[dict]) -> list[tuple[str, int, str, str, str]]:
    """(source name, count, min, median, max) per source plus a total row."""
    names = {k: m.NAME for k, m in SOURCES.items()}
    rows = []
    groups: dict[str, list[int]] = {}
    for p in prices:
        groups.setdefault(p.get("source", ""), [])
        if isinstance(p.get("price"), int) and p["price"] > 0:
            groups[p["source"]].append(p["price"])
    everything = [v for vals in groups.values() for v in vals]
    for key, vals in list(groups.items()) + [("", everything)]:
        name = names.get(key, key) if key else "Összesen"
        if vals:
            rows.append((name, len(vals), format_huf(min(vals)), format_huf(int(statistics.median(vals))), format_huf(max(vals))))
        else:
            rows.append((name, 0, "–", "–", "–"))
    return rows


class _PDF(FPDF):
    def footer(self):
        self.set_y(-10)
        self.set_font("DejaVu", "", 7)
        self.set_text_color(120)
        self.cell(0, 5, f"Piackereső AI-export · {self.page_no()}. oldal", align="C")
        self.set_text_color(0)


def build(meta: dict, items: list[dict], with_details: bool = True) -> bytes:
    """meta: query, min, max, offset (0-based), total, prices [{source, price}]."""
    infos = ad_details.get_many(items) if with_details else [ad_details.Details() for _ in items]
    image_urls = []  # per ad: per image, the URLs to try in order
    for it, info in zip(items, infos):
        urls = list(info.images) or ([it["image"]] if it.get("image") else [])
        tries = []
        for url in urls[: ad_details.MAX_IMAGES]:
            candidates = image_candidates(url)
            if url == it.get("image") and it.get("image_fallback"):
                candidates.append(it["image_fallback"])
            tries.append(list(dict.fromkeys(candidates)))
        image_urls.append(tries)
    with ThreadPoolExecutor(max_workers=6) as pool:
        flat = list(pool.map(load_first, [c for tries in image_urls for c in tries]))
    images, i = [], 0
    for tries in image_urls:
        images.append([img for img in flat[i : i + len(tries)] if img])
        i += len(tries)

    names = {k: m.NAME for k, m in SOURCES.items()}
    first = meta.get("offset", 0) + 1
    last = meta.get("offset", 0) + len(items)

    pdf = _PDF(format="A4")
    pdf.set_margins(12, 12, 12)
    pdf.set_auto_page_break(True, 14)
    pdf.add_font("DejaVu", "", str(FONT_DIR / "DejaVuSans.ttf"))
    pdf.add_font("DejaVu", "B", str(FONT_DIR / "DejaVuSans-Bold.ttf"))
    pdf.set_title(_t(f"Piackereső – {meta.get('query', '')} ({first}–{last})"))
    pdf.set_creator("Piackereső")
    pdf.add_page()

    pdf.set_font("DejaVu", "B", 15)
    pdf.multi_cell(0, 8, _t(f"Piackereső – „{meta.get('query', '')}”"), new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("DejaVu", "", 9.5)
    price_filter = ""
    if meta.get("min") or meta.get("max"):
        price_filter = f"Árszűrő: {meta.get('min') or 0} – {meta.get('max') or '∞'} Ft · "
    pdf.multi_cell(
        0, 5, align="L", text=
        _t(f"{price_filter}Készült: {datetime.now():%Y-%m-%d %H:%M} · Csomag: {first}–{last}. hirdetés "
           f"(összesen {meta.get('total', len(items))} betöltött találatból)"),
        new_x="LMARGIN", new_y="NEXT",
    )
    pdf.ln(2)

    # Price statistics of every loaded result, not only this batch.
    pdf.set_font("DejaVu", "B", 10)
    pdf.cell(0, 6, "Árak (minden betöltött találat)", new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("DejaVu", "B", 9)
    widths = (52, 22, 36, 36, 36)
    for w, head in zip(widths, ("Forrás", "db", "min", "medián", "max")):
        pdf.cell(w, 5.5, head, border="B")
    pdf.ln()
    pdf.set_font("DejaVu", "", 9)
    for row in price_stats(meta.get("prices", [])):
        for w, val in zip(widths, row):
            pdf.cell(w, 5, _t(val))
        pdf.ln()
    pdf.ln(3)

    pdf.set_font("DejaVu", "B", 10)
    pdf.cell(0, 6, "Utasítás az AI-nak", new_x="LMARGIN", new_y="NEXT")
    pdf.set_fill_color(240, 243, 246)
    pdf.set_font("DejaVu", "", 9)
    pdf.multi_cell(0, 4.6, _t(INSTRUCTIONS), fill=True, padding=3, align="L", new_x="LMARGIN", new_y="NEXT")
    pdf.ln(3)

    pdf.set_font("DejaVu", "B", 10)
    pdf.cell(0, 6, "Áttekintés", new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("DejaVu", "", 8.5)
    for n, it in enumerate(items, start=first):
        price = format_huf(it["price"]) if isinstance(it.get("price"), int) else (it.get("price_text") or "–")
        title = _t(it.get("title", ""))
        if len(title) > 80:
            title = title[:79] + "…"
        pdf.cell(10, 4.6, f"#{n}")
        pdf.cell(26, 4.6, _t(SHORT_NAMES.get(it.get("source"), it.get("source", ""))))
        pdf.cell(28, 4.6, _t(price))
        pdf.cell(0, 4.6, title, new_x="LMARGIN", new_y="NEXT")

    box_w, box_h, gap = 59.0, 44.0, 4.5
    bottom = pdf.h - 14
    for n, (it, info, imgs) in enumerate(zip(items, infos, images), start=first):
        if n == first or pdf.get_y() + 70 > bottom:
            pdf.add_page()
        else:
            pdf.ln(2)
            pdf.set_draw_color(200)
            pdf.line(12, pdf.get_y(), pdf.w - 12, pdf.get_y())
            pdf.ln(3)
        pdf.set_font("DejaVu", "B", 10.5)
        pdf.multi_cell(0, 5.2, _t(f"#{n}  {it.get('title', '')}"), align="L", new_x="LMARGIN", new_y="NEXT")
        price = format_huf(it["price"]) if isinstance(it.get("price"), int) else (it.get("price_text") or "ár nincs megadva")
        facts = [names.get(it.get("source"), it.get("source", "")), price, it.get("location"), it.get("posted"), it.get("extra")]
        pdf.set_font("DejaVu", "", 9)
        pdf.multi_cell(0, 4.6, _t(" · ".join(f for f in facts if f)), align="L", new_x="LMARGIN", new_y="NEXT")
        pdf.ln(1)

        if imgs:
            if pdf.get_y() + box_h > bottom:
                pdf.add_page()
            y0 = pdf.get_y()
            x = 12.0
            for data, w_px, h_px in imgs:
                scale = min(box_w / w_px, box_h / h_px)
                pdf.image(io.BytesIO(data), x=x, y=y0, w=w_px * scale, h=h_px * scale)
                x += box_w + 4.5
            pdf.set_y(y0 + box_h + 2)
        else:
            pdf.set_font("DejaVu", "", 8)
            pdf.cell(0, 4.5, "(nincs kép)", new_x="LMARGIN", new_y="NEXT")

        pdf.set_font("DejaVu", "", 8.5)
        description = info.description or ("(leírás nem érhető el)" if with_details else "")
        if description:
            pdf.multi_cell(0, 4.1, _t(description), align="L", new_x="LMARGIN", new_y="NEXT")
        pdf.set_font("DejaVu", "", 7.5)
        pdf.set_text_color(25, 90, 200)
        pdf.write(4, _t(it.get("url", "")), link=it.get("url", ""))
        pdf.set_text_color(0)
        pdf.ln(gap)
    return bytes(pdf.output())


def filename(meta: dict, count: int) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", fold(meta.get("query", "kereses"))).strip("-")[:40] or "kereses"
    first = meta.get("offset", 0) + 1
    return f"piackereso_{slug}_{first}-{meta.get('offset', 0) + count}.pdf"
