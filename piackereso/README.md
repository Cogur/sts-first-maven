# Piackereső

Egy keresés, több használtpiac: **Hardverapró**, **Jófogás** és **Vinted** találatai
egy listában, a **Facebook Marketplace** keresés pedig egy kattintással megnyílik
(ott be kell lenni jelentkezve, ezért azt az app nem kéri le, csak megnyitja).

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

## Ha egy oldal nem ad találatot

Az oldalak időnként átalakítják a felépítésüket vagy védekeznek az automatikus lekérés ellen. Ilyenkor az adott oldal kártyáján „nem sikerült lekérni” vagy 0 találat látszik, a többi oldal működik tovább, és a **Megnyitás ↗** link akkor is jó.

- **Minden oldalnál `curl: (77) error adding trust anchors` hiba:** régebbi verzió hibája volt, ha a mappa nevében ékezet van (pl. `piac-kereső`). Töltsd le az új verziót; az már ékezetes mappából is működik.
- **Vinted:** a `curl_cffi` csomaggal (benne van a `requirements.txt`-ben) sokkal megbízhatóbb. Ha gyakran keresel gyorsan egymás után, ideiglenesen letilthat; pár perc múlva újra megy.
- **Jófogás / Hardverapró:** ha tartósan 0 találat jön, valószínűleg megváltozott az oldal HTML-je; a `piackereso/sources/` alatti fájlban kell igazítani.

A találatok 2 percig gyorsítótárban maradnak, hogy ugyanaz a keresés ne terhelje feleslegesen az oldalakat.

## Fejlesztés

```
pip install -r requirements.txt
python -m unittest discover -s tests
python server.py --no-browser
```

Felépítés és új forrás hozzáadása: [`AGENTS.md`](AGENTS.md).
