# Piackereső

Egy keresés, több használtpiac: **Hardverapró**, **Jófogás**, **Vinted** és
**Facebook Marketplace** találatai egy listában. Ha a Facebook nem ad találatot,
a keresés ott is egy kattintással megnyílik.

Saját használatra készült: a saját gépeden fut, a keresések a te internetkapcsolatodról mennek ki.

## Indítás

Kell hozzá Python 3.10 vagy újabb ([python.org](https://www.python.org/downloads/), Windowson telepítéskor pipáld be az *Add python.exe to PATH* opciót).

- **Windows:** dupla kattintás a `start.bat` fájlra.
- **macOS / Linux:** `./start.sh`

Az első indítás telepíti a szükséges csomagokat (`.venv` mappába), utána megnyílik a böngésző: <http://localhost:8765>.

### Telefonról

```
start.bat --lan        (Windows)
./start.sh --lan       (macOS / Linux)
```

A konzol kiírja a címet (pl. `http://192.168.1.20:8765`); ezt nyisd meg a telefonon, ugyanazon a Wi-Fin.
A Windows tűzfal első alkalommal rákérdezhet, ott engedélyezd a *Magánhálózat* elérést.

## Mit tud

- Egyszerre keres a bepipált oldalakon, min/max ár szűrővel.
- Rendezés: vegyes (minden oldal legújabbjai felváltva), ár szerint, forrás szerint.
- Oldalanként látszik, hány találat jött, vagy hogy az oldal nem válaszolt. A **Megnyitás ↗** link mindig ugyanazt a keresést nyitja meg az eredeti oldalon.
- **Összes oldal megnyitása ↗**: mind a négy keresés új lapokon (a böngésző elsőre blokkolhatja a felugró ablakokat; engedélyezd a `localhost`-nak).
- **Mentett keresések** (☆ Mentés), egy kattintással újrafuttathatók.
- **ÚJ** jelölés: ha egy keresést korábban már lefuttattál, az azóta megjelent hirdetések kapnak „ÚJ” címkét.
- Beállításokban: Facebook város (pl. `szeged`, `debrecen`), és hogy a Facebook keresés automatikusan megnyíljon-e.

A mentett keresések és a „látott” hirdetések a böngésződben tárolódnak (eszközönként külön).

## Facebook Marketplace

Alapból az app bejelentkezés nélkül próbálja lekérni a találatokat. Ha a Facebook ezt nem engedi, a kártyán „csak megnyitható” áll, és a **Megnyitás ↗** link a saját, bejelentkezett böngésződben nyitja meg a keresést.

Megbízhatóbb, ha megadod a saját Facebook-sütidet (*Beállítások → Facebook belépés*):

1. Chrome-ban vagy Edge-ben nyisd meg a facebook.com-ot bejelentkezve.
2. F12 → *Application* (Alkalmazás) fül → bal oldalt *Cookies* → `https://www.facebook.com`.
3. Másold ki a `c_user` és az `xs` sor *Value* értékét a két mezőbe, majd *Mentés*.

Tudnivalók:
- A sütik csak a te gépeden, a `settings.local.json` fájlban vannak; ne küldd el senkinek, és ne tedd fel GitHubra (a `.gitignore` kizárja).
- Az automatikus lekérés ellenkezik a Facebook szabályaival. Saját, ritka használatnál ritkán gond, de a Facebook a fiókra biztonsági ellenőrzést vagy ideiglenes korlátozást tehet.
- Ha kijelentkezel a Facebookról, vagy az `xs` lejár, a kártyán „A Facebook belépés lejárt” hiba jelenik meg: add meg újra a két értéket.
- Csak az első oldalnyi (kb. 20–25) találat jön le.

## Ha egy oldal nem ad találatot

Az oldalak időnként átalakítják a felépítésüket vagy védekeznek az automatikus lekérés ellen. Ilyenkor az adott oldal kártyáján „nem sikerült lekérni” vagy 0 találat látszik, a többi oldal működik tovább, és a **Megnyitás ↗** link akkor is jó.

- **Minden oldalnál `curl: (77) error adding trust anchors` hiba:** régebbi verzió hibája volt, ha a mappa nevében ékezet van (pl. `piac-kereső`). Töltsd le az új verziót; az már ékezetes mappából is működik.
- **Vinted:** 2026 szeptemberében a Vinted új címre költöztette a keresőjét; az app már az újat használja. A `curl_cffi` csomaggal (benne van a `requirements.txt`-ben) sokkal megbízhatóbb. Ha gyakran keresel gyorsan egymás után, ideiglenesen letilthat; pár perc múlva újra megy.
- **Hardverapró:** az oldal visszadobja a keresést, ha az túl hamar jön az első látogatás után. Ezért az app indításkor a háttérben „belátogat” a Hardverapró-ra, és csak 8 másodperc múlva keres; közvetlenül indítás után az első keresés ezért pár másodpercig tarthat. Ha az oldal mégis visszadobja, a kártyán „csak megnyitható” áll, és a link működik.
- **Hardverapró:** a találati oldalon fizetett, „Előresorolva” jelölésű hirdetések is vannak, amelyeknek semmi közük a kereséshez; az app csak azokat tartja meg, amelyek címében a keresés minden szava szerepel (ékezettől függetlenül).
- **Jófogás / Hardverapró:** ha tartósan 0 találat jön, valószínűleg megváltozott az oldal HTML-je; a `core/sources/` alatti fájlban kell igazítani.

### Hibakereső mód

Ha egy oldal furcsán viselkedik (pl. a link a böngészőben jó, az appban nem):

```
start.bat --debug        (Windows)
./start.sh --debug       (macOS / Linux)
```

Futtasd le a keresést, majd az app mappájában a `debug/` mappa tartalmazza, amit az app az oldalaktól kapott (`log.txt` és a letöltött `.html` fájlok). Ezeket el lehet küldeni a hibajavításhoz. Süti- és belépési adat nem kerül bele.

**Hardverapró-diagnosztika:** a `diag.bat` (macOS / Linux: `.venv/bin/python tools/diag_hardverapro.py kave`) többféle módon próbál keresni a Hardverapró-n, és kiírja, melyik ad találatot. Az eredmény a `debug/diag_hardverapro.txt` fájlba kerül.

A találatok 2 percig gyorsítótárban maradnak, hogy ugyanaz a keresés ne terhelje feleslegesen az oldalakat.

## Fejlesztés

```
pip install -r requirements.txt
python -m unittest discover -s tests
python server.py --no-browser
```

Felépítés és új forrás hozzáadása: [`AGENTS.md`](AGENTS.md).
