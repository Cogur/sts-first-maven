"""Runs one query against the selected sources in parallel, with a short cache."""

from __future__ import annotations

import time
from concurrent.futures import ThreadPoolExecutor

from .common import SearchQuery, SourceResult, in_price_range
from .sources import SOURCES

CACHE_SECONDS = 120
_cache: dict[tuple, tuple[float, SourceResult]] = {}
_pool = ThreadPoolExecutor(max_workers=8)


def _run_one(key: str, q: SearchQuery) -> SourceResult:
    cache_key = (key, q.text.lower(), q.min_price, q.max_price, q.page, q.fb_city)
    hit = _cache.get(cache_key)
    if hit and time.time() - hit[0] < CACHE_SECONDS:
        return hit[1]
    module = SOURCES[key]
    try:
        res = module.search(q)
        # Not every site honours the price filter in the URL, so filter again here.
        res.listings = [item for item in res.listings if in_price_range(item, q)]
    except Exception as exc:  # one broken site must not break the others
        res = SourceResult(source=key, name=module.NAME, search_url=module.search_url(q), error=str(exc) or type(exc).__name__)
    if not res.error:
        _cache[cache_key] = (time.time(), res)
    return res


def clear_cache() -> None:
    _cache.clear()


def run(q: SearchQuery, keys: list[str]) -> list[SourceResult]:
    keys = [k for k in keys if k in SOURCES] or list(SOURCES)
    return list(_pool.map(lambda k: _run_one(k, q), keys))
