"""Facebook Marketplace: link only.

Marketplace shows results only to a logged-in user and loads them through a
private GraphQL API, and automated access breaks Facebook's terms. So the app
does not fetch it; it builds the same search URL and opens it in the browser,
where the user is already logged in.
"""

from __future__ import annotations

from urllib.parse import quote, urlencode

from ..common import SearchQuery, SourceResult

KEY = "facebook"
NAME = "Facebook Marketplace"


def search_url(q: SearchQuery) -> str:
    params: dict = {"query": q.text, "exact": "false"}
    if q.min_price is not None:
        params["minPrice"] = q.min_price
    if q.max_price is not None:
        params["maxPrice"] = q.max_price
    city = quote((q.fb_city or "budapest").strip().lower())
    return f"https://www.facebook.com/marketplace/{city}/search?{urlencode(params)}"


def search(q: SearchQuery) -> SourceResult:
    return SourceResult(source=KEY, name=NAME, search_url=search_url(q), link_only=True)
