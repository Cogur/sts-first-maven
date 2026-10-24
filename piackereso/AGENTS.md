# Agent guide: Piackereső

Personal meta-search over Hungarian second-hand marketplaces. User guide (Hungarian): [`docs/utmutato.md`](docs/utmutato.md); [`README.md`](README.md) is only an overview and quick start.

## Layout

| Path | What |
|---|---|
| `server.py` | stdlib `ThreadingHTTPServer`: serves `static/` and `GET /api/search?q=&min=&max=&page=&sources=a,b&city=`, `GET /api/sources`, `GET`/`POST /api/settings`, `POST /api/export` (PDF bytes, or `{"clipboard": true}` → file on the clipboard; copies kept in `exports/`) |
| `core/search.py` | runs sources in parallel, re-applies the price filter, 2-minute cache, turns exceptions into a per-source `error` |
| `core/settings.py` | `settings.local.json` (git-ignored): the optional Facebook cookie |
| `core/common.py` | `Listing`, `SearchQuery`, `SourceResult`, HTTP session (curl_cffi if installed, else requests), `parse_price`, JSON helpers |
| `core/details.py` | ad pages for the AI export: description + bigger images via the site's description block, JSON-LD, embedded JSON (Facebook `redacted_description`), OpenGraph; host allowlist (`ALLOWED_HOSTS`) so the server never fetches arbitrary URLs |
| `core/export_pdf.py` | AI-export PDF (fpdf2 + bundled DejaVu Sans in `core/fonts/`, Bitstream Vera licence): instructions for the AI, price stats, overview, then each ad with ≤3 images shrunk to 800 px; batch size chosen in the UI (`#aiSize`, 5–100, default 30, kept in `localStorage`), server caps at `MAX_BATCH` 100 |
| `core/clipboard.py` | puts the PDF file itself on the OS clipboard: Windows PowerShell 5.1 `Set-Clipboard -LiteralPath` (via `-EncodedCommand`), macOS `osascript`, Linux `xclip` |
| `core/sources/<site>.py` | one module per site: `KEY`, `NAME`, `search_url(q)`, `parse(...)`, `search(q)` |
| `static/index.html` | the whole UI (no build step); saved searches and seen-ad IDs live in `localStorage` |
| `tools/diag_hardverapro.py` | run on the user's machine (`diag.bat`): tries request variants against Hardverapró, report in `debug/` |
| `tests/test_parsers.py` | parser tests on trimmed site markup; `python -m unittest discover -s tests` |

## How each site is read

- **Hardverapró:** HTML `li.media[data-uadid]`, `.uad-price`, `.uad-cities`, `.uad-time`. Paging: `offset` (50/page). Anti-bot, diagnosed on the user's machine with `tools/diag_hardverapro.py` (Oct 2026): a new visitor is identified via `auth.rios.hu` (cookies `_tc`, `sid`, `vid`), and a search sent within ~3 s of that first visit is redirected to `/aprok/index.html` (`"pageType":"mainpage"`); 8 s later the same search works, whatever the browser profile or headers. So `_Visitor` keeps one session for all searches, waits until it is `SETTLE_SECONDS` (8) old, retries once after another 8 s if still sent to the main page, and `server.py` warms it up in the background at start. A main-page answer makes the card `link_only`. The search submits the site's own form (`search_form`). Unrelated paid ads are dropped by `common.title_matches`.
- **Jófogás:** tries classic markup → JSON-LD / `__NEXT_DATA__` → any `…_<id>.htm` link. Paging: `o`. Confirmed live (Oct 2026): the embedded-JSON path is the one that fires; `date` is `{label, value}`. The search JSON links small `img.jofogas.hu/thumbs/<name>`; the same photo is full size at `/images/<name>` (`common.image_candidates`), so listings carry the `/images/` URL with the thumbnail as `image_fallback` (UI `imgFailed`, PDF `load_first`).
- **Vinted:** GET `www.vinted.hu/` → `access_token_web` cookie + `X-Anon-Id` response header; then `api.vinted.hu/svc-catalogue/items` with `Cookie`, `X-Anon-Id`, `Locale: hu-HU`, `Platform: web`, `X-Next-App: marketplace-web`. The old `/api/v2/catalog/items` returns 404 since Sep 2026 (kept as fallback). Reference: the `vinted_scraper` PyPI package v5.
- **Facebook Marketplace:** parses JSON in `<script type="application/json">` for dicts with `marketplace_listing_title`. Logged out by default, and confirmed on the user's machine (Oct 2026) that logged-out searches return results, so the cookie is a fallback, not a requirement. With no ads it falls back to `link_only` with a `note`. Optional user cookie (`c_user` + `xs`) from `settings.local.json` (git-ignored, written via `POST /api/settings`, never echoed back). First page only.

## Rules

- The cloud sandbox cannot reach these sites (proxy 403), so parsers cannot be checked live there. When a site misbehaves, ask the user to run `start.bat --debug`, search once, and send the `debug/` folder (`log.txt` has status, final URL after redirects, Set-Cookie names; one `.html` per fetched URL). Trim the HTML into a test fixture, then fix the parser.
- Keep every source failure isolated: a source raises, `search.py` reports it, the UI still shows the site's own search link.
- New source: add a module with the interface above, register it in `sources/__init__.py`, add a `--<key>` colour in `static/index.html` (light and dark), add tests, update this file and `docs/utmutato.md`.
- Any user-visible change (button, setting, behaviour, error text) updates `docs/utmutato.md` in the same commit.
- Remote access is documented, not built: the app must run at home because Vinted / Facebook (and likely Hardverapró) reject datacenter IPs. `docs/utmutato.md` §7 covers Tailscale and Cloudflare Tunnel + Access; the app has no login of its own, so never suggest exposing it without one.
- Be polite to the sites: no background polling from the server, keep the cache.
- Never ask the user to paste passwords or cookies into a chat; they go into the app's settings on their own machine.
- `start.bat` / `start.sh` reinstall packages whenever `requirements.txt` differs from `.venv/installed-requirements.txt`, so adding a dependency needs no manual step from the user.
- Hardverapró ad pages go through `hardverapro.fetch_page` (the settled `_Visitor` session), never a fresh session, or they get sent to the main page.
