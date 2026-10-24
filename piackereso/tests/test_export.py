"""AI export tests: ad-page extraction, PDF build, clipboard command. Run: python -m unittest discover -s tests"""

import base64
import io
import json
import sys
import tempfile
import threading
import unittest
import urllib.request
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from PIL import Image  # noqa: E402

from core import clipboard, details, export_pdf  # noqa: E402

HARDVERAPRO_AD = """<html><head>
<meta property="og:image" content="https://cdn.rios.hu/dl/uad/2026-10/7753376/main.jpg">
<meta property="og:description" content="A HardverApró adatbázisában friss hardver...">
</head><body>
<div class="uad-content"><div class="rtif-content">AEG beépíthető automata kávéfőző,
tejtartállyal.<br>Típus: CaffeLatte KKK994500M\ufeff</div></div>
<a href="https://cdn.rios.hu/dl/uad/2026-10/7753376/second.jpg">kép</a>
<img src="https://cdn.rios.hu/design/ha/logo.png">
</body></html>"""

JSONLD_AD = """<html><head><script type="application/ld+json">
{"@context": "https://schema.org", "@type": "Product", "name": "Delonghi Magnifica",
 "description": "Megkímélt állapotú Delonghi Magnifica S kávéfőző, vízkőtelenítve.",
 "image": ["https://img.jofogas.hu/images/a.jpg", {"url": "https://img.jofogas.hu/images/b.jpg"}]}
</script></head><body></body></html>"""

FACEBOOK_AD = """<html><head><meta property="og:image" content="https://scontent.xx.fbcdn.net/main.jpg"></head><body>
<script type="application/json">{"x": {"redacted_description": {"text": "Philips 3200 LatteGo, 1 éves, garanciális."},
 "description": "Facebook egy közösségi oldal, ahol ... (hosszú, de nem a hirdetés szövege) ................................"}}</script>
</body></html>"""


def jpeg(w=320, h=240):
    out = io.BytesIO()
    Image.new("RGB", (w, h), (180, 120, 60)).save(out, "JPEG")
    return out.getvalue()


class ExtractTests(unittest.TestCase):
    def test_site_block_beats_generic_og_description(self):
        d = details.extract(HARDVERAPRO_AD, "https://hardverapro.hu/apro/x/friss.html")
        self.assertIn("CaffeLatte KKK994500M", d.description)
        self.assertNotIn("\ufeff", d.description)
        self.assertNotIn("adatbázisában", d.description)
        self.assertEqual(d.images, ["https://cdn.rios.hu/dl/uad/2026-10/7753376/main.jpg", "https://cdn.rios.hu/dl/uad/2026-10/7753376/second.jpg"])

    def test_json_ld_product(self):
        d = details.extract(JSONLD_AD, "https://www.jofogas.hu/pest/x_150123456.htm")
        self.assertTrue(d.description.startswith("Megkímélt állapotú Delonghi"))
        self.assertEqual(d.images, ["https://img.jofogas.hu/images/a.jpg", "https://img.jofogas.hu/images/b.jpg"])

    def test_facebook_prefers_the_ads_own_text(self):
        d = details.extract(FACEBOOK_AD, "https://www.facebook.com/marketplace/item/1/")
        self.assertEqual(d.description, "Philips 3200 LatteGo, 1 éves, garanciális.")
        self.assertEqual(d.images, ["https://scontent.xx.fbcdn.net/main.jpg"])

    def test_long_description_is_cut(self):
        html = '<div class="description">' + "szó " * 1000 + "</div>"
        d = details.extract(html, "https://www.jofogas.hu/a_150123456.htm")
        self.assertLessEqual(len(d.description), details.MAX_DESCRIPTION + 2)
        self.assertTrue(d.description.endswith("…"))

    def test_only_marketplace_hosts_are_fetched(self):
        self.assertTrue(details.allowed("https://hardverapro.hu/apro/x/friss.html"))
        self.assertTrue(details.allowed("https://images1.vinted.net/t/a.jpg"))
        self.assertTrue(details.allowed("https://scontent-vie1-1.xx.fbcdn.net/p.jpg"))
        self.assertFalse(details.allowed("http://hardverapro.hu/x"))  # not https
        self.assertFalse(details.allowed("https://evilhardverapro.hu/x"))
        self.assertFalse(details.allowed("https://127.0.0.1/x"))
        with mock.patch.object(details, "_page") as page:
            self.assertEqual(details.get("jofogas", "https://example.com/x"), details.Details())
        page.assert_not_called()

    def test_unreadable_page_gives_empty_details(self):
        with mock.patch.object(details, "_page", side_effect=RuntimeError("HTTP 403")):
            self.assertEqual(details.get("jofogas", "https://www.jofogas.hu/z_150999999.htm"), details.Details())


ITEMS = [
    {"source": "hardverapro", "id": "1", "title": "AEG beépíthető kávéfőző 😀", "url": "https://hardverapro.hu/apro/aeg/friss.html",
     "price": 250000, "location": "Budapest", "image": "https://cdn.rios.hu/dl/uad/t1.jpg"},
    {"source": "facebook", "id": "2", "title": "Philips LatteGo", "url": "https://www.facebook.com/marketplace/item/2/",
     "price": None, "price_text": "Keresem", "image": ""},
]


class PdfTests(unittest.TestCase):
    def build(self, with_details=True):
        infos = [details.Details("Típus: CaffeLatte KKK994500M, őrlő hibátlan.", ["https://cdn.rios.hu/dl/uad/big.jpg"]), details.Details()]
        meta = {"query": "kávéfőző", "max": "300000", "offset": 30, "total": 75,
                "prices": [{"source": "hardverapro", "price": 250000}, {"source": "jofogas", "price": 40000}, {"source": "vinted", "price": None}]}
        with mock.patch.object(details, "get_many", return_value=infos), \
             mock.patch.object(export_pdf, "load_image", return_value=(jpeg(), 320, 240)) as load:
            pdf = export_pdf.build(meta, ITEMS, with_details=with_details)
        return pdf, load, meta

    def test_pdf_has_instructions_overview_and_ads(self):
        pdf, load, meta = self.build()
        self.assertTrue(pdf.startswith(b"%PDF"))
        # the bigger detail image replaces the thumbnail; the ad without any image gets none
        self.assertEqual([c.args[0] for c in load.call_args_list], ["https://cdn.rios.hu/dl/uad/big.jpg"])
        try:
            import pypdf
        except ImportError:
            self.skipTest("pypdf not installed")
        text = "\n".join(page.extract_text() for page in pypdf.PdfReader(io.BytesIO(pdf)).pages)
        for expected in ("Utasítás az AI-nak", "Csomag: 31–32. hirdetés", "összesen 75", "#31", "#32",
                         "CaffeLatte KKK994500M", "250 000 Ft", "Keresem", "https://hardverapro.hu/apro/aeg/friss.html", "medián"):
            self.assertIn(expected, text)
        self.assertEqual(export_pdf.filename(meta, 2), "piackereso_kavefozo_31-32.pdf")

    def test_without_details_uses_thumbnails(self):
        pdf, load, _ = self.build(with_details=False)
        self.assertEqual([c.args[0] for c in load.call_args_list], ["https://cdn.rios.hu/dl/uad/t1.jpg"])

    def test_falls_back_to_thumbnail_when_full_size_fails(self):
        item = {"source": "jofogas", "id": "9", "title": "Bicikli", "url": "https://www.jofogas.hu/a_150123459.htm", "price": 1000,
                "image": "https://img.jofogas.hu/images/Bicikli_9.jpg", "image_fallback": "https://img.jofogas.hu/thumbs/Bicikli_9.jpg"}
        tried = []

        def fake_load(url):
            tried.append(url)
            return (jpeg(), 320, 240) if "/thumbs/" in url else None

        with mock.patch.object(export_pdf, "load_image", side_effect=fake_load):
            export_pdf.build({"query": "x", "prices": []}, [item], with_details=False)
        self.assertEqual(tried, ["https://img.jofogas.hu/images/Bicikli_9.jpg", "https://img.jofogas.hu/thumbs/Bicikli_9.jpg"])

    def test_detail_page_thumbnails_are_upgraded_too(self):
        self.assertEqual(export_pdf.image_candidates("https://img.jofogas.hu/thumbs/a.jpg"),
                         ["https://img.jofogas.hu/images/a.jpg", "https://img.jofogas.hu/thumbs/a.jpg"])
        self.assertEqual(export_pdf.image_candidates("https://images1.vinted.net/t/x.jpg"), ["https://images1.vinted.net/t/x.jpg"])

    def test_price_stats(self):
        rows = export_pdf.price_stats([{"source": "jofogas", "price": 10000}, {"source": "jofogas", "price": 30000}, {"source": "vinted", "price": None}])
        self.assertEqual(rows[0], ("Jófogás", 2, "10 000 Ft", "20 000 Ft", "30 000 Ft"))
        self.assertEqual(rows[1], ("Vinted", 0, "–", "–", "–"))
        self.assertEqual(rows[-1][0], "Összesen")

    def test_load_image_shrinks_and_rejects_foreign_hosts(self):
        big = io.BytesIO()
        Image.new("RGB", (2400, 1600), (10, 20, 30)).save(big, "PNG")
        with mock.patch.object(export_pdf, "fetch", return_value=mock.Mock(content=big.getvalue())):
            data, w, h = export_pdf.load_image("https://img.jofogas.hu/big-unique-1.png")
        self.assertEqual((w, h), (800, 533))
        self.assertTrue(data.startswith(b"\xff\xd8"))  # JPEG
        self.assertIsNone(export_pdf.load_image("https://example.com/a.jpg"))


class ClipboardTests(unittest.TestCase):
    def test_windows_command_quotes_accented_path(self):
        cmd = clipboard.windows_command(Path("C:/Users/metal/piac-kereső/it's.pdf"))
        self.assertEqual(cmd[:4], ["powershell", "-NoProfile", "-NonInteractive", "-EncodedCommand"])
        script = base64.b64decode(cmd[4]).decode("utf-16-le")
        self.assertIn("Set-Clipboard -LiteralPath", script)
        self.assertIn("piac-kereső", script)
        self.assertIn("it''s.pdf'", script)

    def test_failure_is_reported(self):
        with mock.patch.object(clipboard.subprocess, "run", return_value=mock.Mock(returncode=1, stderr="boom", stdout="")):
            with self.assertRaisesRegex(RuntimeError, "boom"):
                clipboard.copy_file(Path("x.pdf"))


class ServerExportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import server

        cls.server_mod = server
        cls.tmp = tempfile.TemporaryDirectory()
        cls.exports_patch = mock.patch.object(server, "EXPORTS", Path(cls.tmp.name))
        cls.exports_patch.start()
        cls.httpd = server.ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()
        cls.base = f"http://127.0.0.1:{cls.httpd.server_address[1]}"

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.exports_patch.stop()
        cls.tmp.cleanup()

    def post(self, body):
        req = urllib.request.Request(self.base + "/api/export", data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        try:
            with opener.open(req) as resp:
                return resp.status, dict(resp.headers), resp.read()
        except urllib.error.HTTPError as err:
            return err.code, dict(err.headers), err.read()

    def test_download_and_clipboard(self):
        body = {"query": "kávé", "offset": 0, "total": 2, "details": False, "items": ITEMS, "prices": []}
        with mock.patch.object(export_pdf, "load_image", return_value=None):
            status, headers, data = self.post(body)
            self.assertEqual(status, 200)
            self.assertEqual(headers["Content-Type"], "application/pdf")
            self.assertIn('filename="piackereso_kave_1-2.pdf"', headers["Content-Disposition"])
            self.assertTrue(data.startswith(b"%PDF"))
            self.assertTrue((Path(self.tmp.name) / "piackereso_kave_1-2.pdf").exists())

            with mock.patch.object(self.server_mod.clipboard, "copy_file") as copy:
                status, _, data = self.post({**body, "clipboard": True})
            self.assertEqual(status, 200)
            self.assertTrue(json.loads(data)["ok"])
            copy.assert_called_once_with(Path(self.tmp.name) / "piackereso_kave_1-2.pdf")

            with mock.patch.object(self.server_mod.clipboard, "copy_file", side_effect=RuntimeError("nincs xclip")):
                status, _, data = self.post({**body, "clipboard": True})
            self.assertEqual(status, 500)
            self.assertIn("nincs xclip", json.loads(data)["error"])

    def test_empty_export_is_rejected(self):
        status, _, data = self.post({"items": []})
        self.assertEqual(status, 400)


if __name__ == "__main__":
    unittest.main()
