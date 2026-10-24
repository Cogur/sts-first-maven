# Piackereső

Egy keresés, több használtpiac: **Hardverapró**, **Jófogás**, **Vinted** és
**Facebook Marketplace** találatai egy listában, és a találatokból képes
**PDF az AI-nak** (Claude, ChatGPT, Gemini), hogy segítsen dönteni.

Saját használatra készült: a saját gépeden fut, a keresések a te internetkapcsolatodról mennek ki.

**📖 Használati útmutató: [`docs/utmutato.md`](docs/utmutato.md)**
(telepítés, keresés, AI-export, Facebook, telefonról és bárhonnan való elérés, hibaelhárítás)

## Gyors indítás

1. Telepítsd a Pythont (3.10+): <https://www.python.org/downloads/> – Windowson pipáld be az *Add python.exe to PATH* opciót.
2. Windows: dupla kattintás a `start.bat` fájlra. macOS / Linux: `./start.sh`
3. Megnyílik a böngésző: <http://localhost:8765>

Az első indítás 1–2 percig tart, mert telepíti a szükséges csomagokat.

## Fejlesztés

```
pip install -r requirements.txt
python -m unittest discover -s tests
python server.py --no-browser
```

Felépítés, az oldalak lekérésének részletei és új forrás hozzáadása: [`AGENTS.md`](AGENTS.md).
