# Agent guide: Piackereső

Personal meta-search over Hungarian second-hand marketplaces. User docs (Hungarian): [`README.md`](README.md).

## Layout

| Path | What |
|---|---|
| `server.py` | stdlib `ThreadingHTTPServer`: serves `static/` and `GET /api/search?q=&min=&max=&page=&sources=a,b&city=`, `GET /api/sources`, `GET`/`POST /api/settings` |
| `piackereso/search.py` | runs sources in parallel, re-applies the price filter, 2-minute cache, turns exceptions into a per-source `error` |
| `piackereso/settings.py` | `settings.local.json` (git-ignored): the optional Facebook cookie |
| `piackereso/common.py` | `Listing`, `SearchQuery`, `SourceResult`, HTTP session (curl_cffi if installed, else requests), `parse_price`, JSON helpers |
| `piackereso/sources/<site>.py` | one module per site: `KEY`, `NAME`, `search_url(q)`, `parse(...)`, `search(q)` |
| `static/index.html` | the whole UI (no build step); saved searches and seen-ad IDs live in `localStorage` |
| `tests/test_parsers.py` | parser tests on trimmed site markup; `python -m unittest discover -s tests` |

## How each site is read

- **Hardverapró:** HTML `li.media[data-uadid]`, `.uad-price`, `.uad-cities`, `.uad-time`. Paging: `offset` (50/page). The page also carries unrelated paid "Előresorolva" ads, so results are filtered to titles containing every query word (`common.title_matches`, accent-insensitive).
- **Jófogás:** tries classic markup → JSON-LD / `__NEXT_DATA__` → any `…_<id>.htm` link. Paging: `o`. Confirmed live (Oct 2026): the embedded-JSON path is the one that fires; `date` is `{label, value}`.
- **Vinted:** GET `www.vinted.hu/` → `access_token_web` cookie + `X-Anon-Id` response header; then `api.vinted.hu/svc-catalogue/items` with `Cookie`, `X-Anon-Id`, `Locale: hu-HU`, `Platform: web`, `X-Next-App: marketplace-web`. The old `/api/v2/catalog/items` returns 404 since Sep 2026 (kept as fallback). Reference: the `vinted_scraper` PyPI package v5.
- **Facebook Marketplace:** parses JSON in `<script type="application/json">` for dicts with `marketplace_listing_title`. Logged out by default; falls back to `link_only` with a `note`. Optional user cookie (`c_user` + `xs`) from `settings.local.json` (git-ignored, written via `POST /api/settings`, never echoed back). First page only.

## Rules

- The cloud sandbox cannot reach these sites (proxy 403), so parsers cannot be checked live there. When a site changes, ask the user to save the result page (Ctrl+S) or the JSON, trim it into a test fixture, then fix the parser.
- Keep every source failure isolated: a source raises, `search.py` reports it, the UI still shows the site's own search link.
- New source: add a module with the interface above, register it in `sources/__init__.py`, add a `--<key>` colour in `static/index.html` (light and dark), add tests, update this file and `README.md`.
- Be polite to the sites: no background polling from the server, keep the cache.
- Never ask the user to paste passwords or cookies into a chat; they go into the app's settings on their own machine.
