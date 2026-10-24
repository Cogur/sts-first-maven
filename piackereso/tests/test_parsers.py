"""Parser tests on trimmed copies of each site's markup. Run: python -m unittest discover -s tests"""

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from piackereso import search  # noqa: E402
from piackereso.common import Listing, SearchQuery, SourceResult, ascii_ca_bundle, in_price_range, parse_price  # noqa: E402
from piackereso.sources import facebook, hardverapro, jofogas, vinted  # noqa: E402

HARDVERAPRO_HTML = """
<div class="uad-list"><ul class="list-unstyled">
<li class="media" data-uadid="1234567">
  <a class="uad-image align-self-center" href="/apro/rtx_3060_12gb/friss.html">
    <img src="https://cdn.rios.hu/dl/uad/abc.jpg" alt=""></a>
  <div class="media-body">
    <div class="uad-col uad-col-title">
      <h1><a href="https://hardverapro.hu/apro/rtx_3060_12gb/friss.html">MSI RTX 3060 12GB  Ventus</a></h1>
    </div>
    <div class="uad-col uad-col-info">
      <div class="uad-price">85 000 Ft</div>
      <div class="uad-cities">Budapest</div>
      <div class="uad-time"><time datetime="2026-10-23">tegnap 18:02</time></div>
    </div>
  </div>
</li>
<li class="media" data-uadid="7654321">
  <div class="media-body"><h1><a href="/apro/gigabyte_rtx_3060/friss.html">Gigabyte RTX 3060</a></h1>
  <div class="uad-price">Keresem</div></div>
</li>
</ul></div>
"""

JOFOGAS_MARKUP = """
<div class="list-item">
  <section class="reLiSection imageBox"><img class="img-thumbnail" src="https://img.jofogas.hu/x.jpg"></section>
  <h3 class="item-title"><a class="subject" href="https://www.jofogas.hu/budapest/iphone-13-128gb_150123456.htm">iPhone 13 128GB</a></h3>
  <h3 class="item-price"><span class="price-value">180.000</span> <span class="currency">Ft</span></h3>
  <section class="reLiSection cityname">Budapest XI. kerület</section>
  <div class="time">Ma 10:15</div>
</div>
"""

JOFOGAS_NEXT_DATA = """
<html><body><script id="__NEXT_DATA__" type="application/json">%s</script></body></html>
""" % json.dumps(
    {
        "props": {
            "pageProps": {
                "ads": [
                    {
                        "subject": "Nike Air Max 42",
                        "url": "https://www.jofogas.hu/pest/nike-air-max_150999888.htm",
                        "price": {"value": 25000},
                        "images": [{"url": "https://img.jofogas.hu/n.jpg"}],
                        "location": {"city": "Érd"},
                    },
                    {"title": "Navigation link", "url": "https://www.jofogas.hu/belepes"},
                ]
            }
        }
    }
)

VINTED_JSON = {
    "items": [
        {
            "id": 555,
            "title": "Nike Air Force 1",
            "price": {"amount": "12000.0", "currency_code": "HUF"},
            "url": "https://www.vinted.hu/items/555-nike-air-force-1",
            "photo": {"url": "https://images.vinted.net/full.jpg", "thumbnails": [{"type": "thumb310x430", "url": "https://images.vinted.net/t.jpg"}]},
            "brand_title": "Nike",
            "size_title": "42",
            "user": {"login": "anna"},
        },
        {"id": 556, "title": "Old API shape", "price": "3 500,0", "currency": "HUF", "url": "/items/556", "photo": None},
    ]
}


class DebugDumpTests(unittest.TestCase):
    def test_fetch_saves_page_and_log(self):
        from piackereso import common

        resp = mock.Mock(status_code=200, text="<html>ok</html>", content=b"<html>ok</html>", url="https://hardverapro.hu/aprok/index.html", headers={"Set-Cookie": "prf_ls_uad=1; path=/, PHPSESSID=abc; path=/"})
        session = mock.Mock(get=mock.Mock(return_value=resp))
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(common, "DEBUG_DIR", tmp):
            common.fetch(session, "https://hardverapro.hu/aprok/keres.php?stext=x")
            files = sorted(os.listdir(tmp))
            with open(os.path.join(tmp, "log.txt"), encoding="utf-8") as f:
                log = f.read()
        self.assertEqual(files, ["hardverapro_hu_aprok_keres_php.html", "log.txt"])
        self.assertIn("final url: https://hardverapro.hu/aprok/index.html", log)
        self.assertIn("PHPSESSID, prf_ls_uad", log)


class PriceTests(unittest.TestCase):
    def test_title_matches_ignores_accents(self):
        from piackereso.common import title_matches

        self.assertTrue(title_matches("Mobil klima+páramentesitő", "páramentesítő"))
        self.assertTrue(title_matches("MSI RTX 3060 12GB", "rtx 3060"))
        self.assertFalse(title_matches("Windows 11 Pro licenc", "páramentesítő"))

    def test_parse_price(self):
        self.assertEqual(parse_price("85 000 Ft"), 85000)
        self.assertEqual(parse_price("12.500,- Ft"), 12500)
        self.assertEqual(parse_price("1.299.000 Ft"), 1299000)
        self.assertEqual(parse_price("12000.0"), 12000)
        self.assertEqual(parse_price("1 299,99"), 1299)
        self.assertEqual(parse_price("Ingyenes"), 0)
        self.assertIsNone(parse_price("Keresem"))
        self.assertIsNone(parse_price(None))

    def test_price_range_keeps_unpriced(self):
        q = SearchQuery("x", min_price=1000, max_price=5000)
        self.assertTrue(in_price_range(Listing("s", "1", "t", "u", price=None), q))
        self.assertFalse(in_price_range(Listing("s", "1", "t", "u", price=999), q))
        self.assertFalse(in_price_range(Listing("s", "1", "t", "u", price=5001), q))


class CaBundleTests(unittest.TestCase):
    def test_non_ascii_path_is_copied_to_ascii_folder(self):
        with tempfile.TemporaryDirectory() as tmp:
            src_dir = os.path.join(tmp, "piac-kereső")
            os.mkdir(src_dir)
            src = os.path.join(src_dir, "cacert.pem")
            with open(src, "w") as f:
                f.write("CERT")
            self.assertEqual(ascii_ca_bundle(tmp + "/ok.pem", []), tmp + "/ok.pem")
            dst = ascii_ca_bundle(src, [None, src_dir, tmp])
            self.assertEqual(dst, os.path.join(tmp, "piackereso-cacert.pem"))
            with open(dst) as f:
                self.assertEqual(f.read(), "CERT")
            self.assertIsNone(ascii_ca_bundle(src, [src_dir]))


class HardveraproTests(unittest.TestCase):
    def test_promoted_unrelated_ads_are_dropped(self):
        page = mock.Mock(text=HARDVERAPRO_HTML, url="https://hardverapro.hu/aprok/index.html")
        with mock.patch.object(hardverapro, "fetch", return_value=page) as fetch:
            res = hardverapro.search(SearchQuery("msi 3060"))
            # the ad index is visited first, then the search with that page as referer
            self.assertEqual(fetch.call_args_list[0].args[1], "https://hardverapro.hu/aprok/index.html")
            self.assertIn("keres.php?stext=msi+3060", fetch.call_args_list[1].args[1])
            unrelated = hardverapro.search(SearchQuery("páramentesítő"))
        self.assertEqual([i.id for i in res.listings], ["1234567"])

        res = unrelated
        self.assertEqual(res.listings, [])
        self.assertIn("2 hirdetés jött", res.note)
        self.assertIn("átirányítva", res.note)

    def test_parse(self):
        items = hardverapro.parse(HARDVERAPRO_HTML)
        self.assertEqual(len(items), 2)
        a = items[0]
        self.assertEqual(a.id, "1234567")
        self.assertEqual(a.title, "MSI RTX 3060 12GB Ventus")
        self.assertEqual(a.url, "https://hardverapro.hu/apro/rtx_3060_12gb/friss.html")
        self.assertEqual(a.price, 85000)
        self.assertEqual(a.location, "Budapest")
        self.assertEqual(a.posted, "tegnap 18:02")
        self.assertTrue(a.image.endswith("abc.jpg"))
        self.assertIsNone(items[1].price)
        self.assertEqual(items[1].url, "https://hardverapro.hu/apro/gigabyte_rtx_3060/friss.html")

    def test_url(self):
        url = hardverapro.search_url(SearchQuery("rtx 3060", min_price=50000, page=2))
        self.assertEqual(url, "https://hardverapro.hu/aprok/keres.php?stext=rtx+3060&minprice=50000&offset=50")


class JofogasTests(unittest.TestCase):
    def test_markup(self):
        items = jofogas.parse(JOFOGAS_MARKUP)
        self.assertEqual(len(items), 1)
        a = items[0]
        self.assertEqual((a.id, a.title, a.price), ("150123456", "iPhone 13 128GB", 180000))
        self.assertEqual(a.location, "Budapest XI. kerület")
        self.assertEqual(a.image, "https://img.jofogas.hu/x.jpg")

    def test_embedded_json(self):
        items = jofogas.parse(JOFOGAS_NEXT_DATA)
        self.assertEqual(len(items), 1)
        a = items[0]
        self.assertEqual((a.id, a.title, a.price, a.location), ("150999888", "Nike Air Max 42", 25000, "Érd"))
        self.assertEqual(a.image, "https://img.jofogas.hu/n.jpg")

    def test_posted_label(self):
        html = JOFOGAS_NEXT_DATA.replace('"subject"', '"date": {"label": "okt 5., 16:09", "value": "1791209390"}, "subject"')
        self.assertEqual(jofogas.parse(html)[0].posted, "okt 5., 16:09")

    def test_link_fallback(self):
        html = '<a href="/budapest/bicikli_150111222.htm">Trek bicikli</a><a href="/szabalyzat">Szabályzat</a>'
        items = jofogas.parse(html)
        self.assertEqual([(i.id, i.title) for i in items], [("150111222", "Trek bicikli")])


class VintedTests(unittest.TestCase):
    def test_parse(self):
        items = vinted.parse(VINTED_JSON)
        a, b = items
        self.assertEqual((a.id, a.title, a.price), ("555", "Nike Air Force 1", 12000))
        self.assertEqual(a.image, "https://images.vinted.net/t.jpg")
        self.assertEqual(a.extra, "Nike · 42 · @anna")
        self.assertEqual(b.price, 3500)
        self.assertEqual(b.url, "https://www.vinted.hu/items/556")

    def test_api_url(self):
        url = vinted.api_url(SearchQuery("nike", max_price=20000))
        self.assertTrue(url.startswith("https://api.vinted.hu/svc-catalogue/items?"), url)
        self.assertIn("price_to=20000", url)
        self.assertIn("currency=HUF", url)


FACEBOOK_HTML = """<html><body>
<script type="application/json" data-sjs>%s</script>
<script>var x = 1;</script></body></html>""" % json.dumps(
    {"require": [["ScheduledServerJS", "handle", None, [{"__bbox": {"result": {"data": {"marketplace_search": {"feed_units": {"edges": [
        {"node": {"listing": {
            "id": "1122334455",
            "marketplace_listing_title": "Páramentesítő Midea 20L",
            "listing_price": {"formatted_amount": "35 000 Ft", "amount": "35000.00"},
            "location": {"reverse_geocode": {"city": "Budapest", "state": "Budapest"}},
            "primary_listing_photo": {"image": {"uri": "https://scontent.xx.fbcdn.net/p.jpg"}},
            "is_sold": False}}},
        {"node": {"listing": {"id": "999", "marketplace_listing_title": "Eladva", "is_sold": True}}},
    ]}}}}}}]]]}
)


class FacebookTests(unittest.TestCase):
    def test_url(self):
        url = facebook.search_url(SearchQuery("bicikli", max_price=50000, fb_city="szeged"))
        self.assertEqual(url, "https://www.facebook.com/marketplace/szeged/search?query=bicikli&exact=false&maxPrice=50000")

    def test_parse_embedded_json(self):
        (a,) = facebook.parse(FACEBOOK_HTML)
        self.assertEqual((a.id, a.title, a.price, a.price_text, a.location), ("1122334455", "Páramentesítő Midea 20L", 35000, "35 000 Ft", "Budapest"))
        self.assertEqual(a.url, "https://www.facebook.com/marketplace/item/1122334455/")
        self.assertEqual(a.image, "https://scontent.xx.fbcdn.net/p.jpg")

    def test_falls_back_to_link_when_logged_out_and_blocked(self):
        with mock.patch.object(facebook.settings, "facebook_cookie", return_value=""), mock.patch.object(facebook, "fetch", side_effect=RuntimeError("HTTP 400")):
            res = facebook.search(SearchQuery("x"))
        self.assertTrue(res.link_only)
        self.assertEqual(res.error, "")
        self.assertIn("HTTP 400", res.note)

    def test_expired_cookie_is_reported(self):
        page = mock.Mock(text='<form id="login_form"></form>')
        with mock.patch.object(facebook.settings, "facebook_cookie", return_value="c_user=1; xs=2"), mock.patch.object(facebook, "fetch", return_value=page):
            with self.assertRaises(RuntimeError):
                facebook.search(SearchQuery("x"))


class OrchestrationTests(unittest.TestCase):
    def test_one_failing_source_does_not_break_others(self):
        ok = SourceResult("vinted", "Vinted", "u", listings=[Listing("vinted", "1", "a", "u1", price=100), Listing("vinted", "2", "b", "u2", price=99999)])
        with mock.patch.object(hardverapro, "search", side_effect=RuntimeError("HTTP 403")), mock.patch.object(vinted, "search", return_value=ok):
            results = search.run(SearchQuery("teszt-orch", max_price=1000), ["hardverapro", "vinted"])
        by_key = {r.source: r for r in results}
        self.assertEqual(by_key["hardverapro"].error, "HTTP 403")
        self.assertTrue(by_key["hardverapro"].search_url.startswith("https://hardverapro.hu/"))
        self.assertEqual([i.id for i in by_key["vinted"].listings], ["1"])  # 99999 Ft filtered out


if __name__ == "__main__":
    unittest.main()
