# Piackereső – használati útmutató

A Piackereső egyetlen kereséssel átnézi a **Hardverapró**, a **Jófogás**, a **Vinted** és a **Facebook Marketplace** hirdetéseit, és egy listában mutatja őket. A találatokból képes PDF-et is készít, amit feltölthetsz egy AI-ba (Claude, ChatGPT, Gemini), hogy segítsen dönteni.

Az app a saját gépeden fut, a keresések a te internetkapcsolatodról mennek ki. Ezért működik olyan oldalakkal is, amelyek a szervereket kitiltják.

**Tartalom**

1. [Telepítés](#1-telepítés)
2. [Indítás és leállítás](#2-indítás-és-leállítás)
3. [Keresés](#3-keresés)
4. [AI-export: PDF a döntéshez](#4-ai-export-pdf-a-döntéshez)
5. [Facebook Marketplace](#5-facebook-marketplace)
6. [Telefonról, otthon](#6-telefonról-otthon)
7. [Elérés bárhonnan (online)](#7-elérés-bárhonnan-online)
8. [Frissítés új verzióra](#8-frissítés-új-verzióra)
9. [Ha valami nem működik](#9-ha-valami-nem-működik)
10. [Hol vannak az adataim?](#10-hol-vannak-az-adataim)

---

## 1. Telepítés

### Python

Az apphoz **Python 3.10 vagy újabb** kell.

1. Töltsd le: <https://www.python.org/downloads/>
2. Windowson a telepítő első ablakában **pipáld be az „Add python.exe to PATH” opciót**, utána *Install Now*.

### Az app letöltése

- **GitHubról:** <https://github.com/cogur/sts-first-maven/archive/refs/heads/ccr-8d9bb3c4-tgq8da.zip> (privát repónál előbb jelentkezz be a GitHubra). A zipben a `piackereso` mappa kell.
- Vagy a kapott `piackereso.zip` fájlból.

Csomagold ki egy mappába, például `Dokumentumok\piackereso`. Ékezetes mappanév is jó.

---

## 2. Indítás és leállítás

- **Windows:** dupla kattintás a `start.bat` fájlra.
- **macOS / Linux:** terminálban a mappában: `./start.sh`

Az **első indítás** 1–2 percig tart, mert letölti a szükséges csomagokat. Ugyanez történik egy olyan frissítés után is, ami új csomagot igényel. Utána magától megnyílik a böngésző a <http://localhost:8765> címen.

A fekete ablak (konzol) az app maga: **amíg használod, hagyd nyitva**. Leállítás: az ablakban **Ctrl+C**, vagy zárd be az ablakot.

Az indítás után az app a háttérben „belátogat” a Hardverapróra (lásd [9. pont](#9-ha-valami-nem-működik)), ezért közvetlenül indítás után az első keresésnél a Hardverapró-találatok néhány másodperccel később jönnek.

---

## 3. Keresés

1. Írd be, mit keresel (pl. `rtx 3060`, `kávéfőző`), és ha kell, adj meg minimum és maximum árat.
2. Pipáld be, mely oldalakon keressen.
3. **Keresés**.

**A találati kártyák** (a lista fölött, oldalanként):
- **„N találat”**: ennyi hirdetés jött az oldalról.
- **„csak megnyitható”**: az oldal most nem adott találatot az appnak (pl. a Facebook belépés nélkül). A **Megnyitás ↗** linkkel ugyanez a keresés megnyílik az oldalon, a böngésződben.
- **„nem sikerült lekérni”**: az oldal nem válaszolt; a link ilyenkor is működik.

**A lista:**
- **Rendezés** (jobbra fent): vegyes (minden oldal legújabbjai felváltva), ár szerint növekvő vagy csökkenő, illetve forrás szerint.
- **Következő oldal betöltése** (a lista alján): további találatok.
- **ÚJ** címke: ha egy keresést korábban már lefuttattál, az azóta megjelent hirdetések kapják.
- A hirdetésre kattintva az eredeti oldalon nyílik meg.

**Egyéb:**
- **☆ Mentés:** elmenti a keresést; a mentett kereséseket a keresőmező alatt egy kattintással újra lefuttathatod.
- **Összes oldal megnyitása ↗:** mind a négy oldalon megnyitja a keresést új lapokon. A böngésző elsőre letilthatja a felugró ablakokat: engedélyezd a címsor jobb oldalán megjelenő ikonnal.
- **Beállítások:** a Facebook-kereséshez használt város (pl. `szeged`, `debrecen`), és a nem kötelező Facebook-belépés (lásd [5. pont](#5-facebook-marketplace)).

---

## 4. AI-export: PDF a döntéshez

A találatok fölötti **AI-export** dobozzal PDF-et készíthetsz a hirdetésekből, képekkel együtt. Ezt feltöltheted a Claude-ba, a ChatGPT-be vagy a Geminibe, és megkérheted, hogy segítsen dönteni.

### Csomagok

Egy PDF-be alapból **30 hirdetés** kerül: `1–30`, `31–60` és így tovább, a képernyőn beállított rendezés szerint. Ha például ár szerint növekvőre rendezel, az `1–30` a 30 legolcsóbb. Ha több hirdetés kell, előbb töltsd be a „Következő oldal” gombbal.

A **Csomagméret** mezőben ezt 5 és 100 között bármire átállíthatod (pl. `50` → `1–50`, `51–100`); az app megjegyzi. Nagyobb csomagnál nagyobb a PDF, és tovább tart elkészíteni: 30 hirdetés jellemzően néhány MB és 10–15 oldal, 100 hirdetés akár 10–20 MB és 35–40 oldal. Ha egy AI nem fogadja el a fájlt (túl nagy), válassz kisebb csomagot.

### Mi van a PDF-ben

- **Utasítás az AI-nak:** azonosítsa minden hirdetésnél a pontos típust; ha nem egyértelmű, csak annyit adjon meg, amennyi biztos (pl. csak a márkát), vagy azt, hogy „nem meghatározható”. Nézze meg, kapható-e még újként, mennyi a legalacsonyabb és az átlagos új ár, értékelje az árat, és ajánlja a 3 legjobb vételt.
- **Árstatisztika** oldalanként (darab, minimum, medián, maximum), az összes betöltött találatból.
- **Áttekintő lista** a csomag hirdetéseiről.
- **Hirdetésenként:** cím, ár, hely, dátum, link, leírás és legfeljebb 3 kép.

### Nagyobb képek + leírás

Ha be van pipálva (alapból igen), az app a hirdetések saját oldaláról letölti a leírást és a nagyobb képeket. Így az AI sokkal pontosabban felismeri a típust, de 30 hirdetésnél ez **20–60 másodpercig** is tarthat (nagyobb csomagnál arányosan tovább). Kikapcsolva gyors, de csak a lista képei kerülnek bele.

### Átadás az AI-nak

- **📋 Vágólapra:** a PDF-fájl a vágólapra kerül, mintha az Intézőben Ctrl+C-t nyomtál volna rajta. Nyisd meg az AI-chatet, kattints a beviteli mezőbe, **Ctrl+V**, és írd mellé:
  > Kövesd a PDF elején lévő utasítást.
- **⬇ Letöltés:** letölti a PDF-et; utána húzd be a chatbe, vagy csatold a gemkapocs ikonnal.

Minden elkészült PDF megmarad az app **`exports`** mappájában is.

**Tudnivalók:**
- A **Vágólapra** gomb csak azon a gépen működik, ahol az app fut. Telefonról használd a Letöltést, és onnan oszd meg az AI-appal.
- Az **új árat** az AI csak akkor tudja megnézni, ha a chatben be van kapcsolva a **webes keresés**. Ha nincs, ezt jeleznie kell; kitalált árat nem írhat.
- Az AI a képek alapján tévedhet. Ha valamit csak a képről következtet, az utasítás szerint ezt jelölnie kell; fontos vásárlás előtt kérdezz rá az eladónál.
- Több csomagot egymás után is feltölthetsz ugyanabba a beszélgetésbe; a végén kérhetsz összesítést.

---

## 5. Facebook Marketplace

A Facebook-találatok **bejelentkezés nélkül is jönnek**, ehhez semmit nem kell beállítani. Az app ugyanúgy kéri le őket, mint egy kijelentkezett böngésző.

Ha egyszer mégis „csak megnyitható” jelenik meg a Facebook kártyáján (a Facebook időnként szigorít a kijelentkezett látogatókkal szemben), két lehetőséged van:
- a **Megnyitás ↗** link a saját, bejelentkezett böngésződben nyitja meg a keresést;
- vagy add meg a Facebook-belépést az appnak, lásd lent.

### Belépéssel (csak ha belépés nélkül nem jön találat)

1. Chrome-ban vagy Edge-ben nyisd meg a facebook.com-ot **bejelentkezve**.
2. Nyomd meg az **F12**-t → felül az **Application** (Alkalmazás) fül → bal oldalt **Cookies** → `https://www.facebook.com`.
3. Keresd meg a `c_user` és az `xs` sort, és másold ki a **Value** oszlop értékét.
4. Az appban: **Beállítások → Facebook belépés** → írd be a két értéket → **Mentés**.

**Fontos:**
- Ez a két érték olyan, mint egy jelszó: **ne küldd el senkinek**, ne írd chatbe, ne tedd fel sehova. Csak a te gépeden tárolódik, a `settings.local.json` fájlban.
- Az automatikus lekérés ellenkezik a Facebook szabályaival. Saját, ritka használatnál ritkán gond, de a Facebook a fiókodra biztonsági ellenőrzést vagy ideiglenes korlátozást tehet.
- Ha kijelentkezel a Facebookról, a sütik érvénytelenné válnak: a kártyán „A Facebook belépés lejárt” jelenik meg. Ilyenkor add meg újra a két értéket.
- Törlés: **Beállítások → Facebook belépés → Törlés**.
- A Facebookról csak az első oldalnyi, kb. 20–25 találat jön le.

---

## 6. Telefonról, otthon

Ha a telefon ugyanazon a Wi-Fin van, mint a gép, amin az app fut:

1. Indítsd az appot így:
   - Windows: nyiss parancssort a mappában, és írd be: `start.bat --lan`
   - vagy készíts parancsikont a `start.bat`-ra, és a *Cél* mező végére írd: ` --lan`
2. A konzol kiírja a címet, például: `Telefonról (ugyanazon a Wi-Fin): http://192.168.1.20:8765`
3. Ezt nyisd meg a telefon böngészőjében.

A Windows tűzfal az első alkalommal rákérdezhet: engedélyezd a **Magánhálózat** elérést.

A mentett keresések és az „ÚJ” jelölések eszközönként külön tárolódnak (a böngészőben).

---

## 7. Elérés bárhonnan (online)

**Miért nem egy bérelt szerveren fut?** A keresések annak a gépnek az internetéről mennek ki, ahol az app fut. A Vinted és a Facebook az adatközponti (bérelt szerveres) IP-címeket jellemzően kitiltja, a Hardverapró is gyanakvó. Ezért a legjobb, ha az app **otthon** fut, és kívülről egy biztonságos „alagúton” éred el.

Mindkét lenti megoldáshoz kell egy **otthoni gép, ami mindig be van kapcsolva** (asztali gép, régi laptop, Raspberry Pi), és amin az app fut.

### Előkészítés: az app automatikus indítása (Windows)

1. Nyomd meg a **Win+R**-t, írd be: `shell:startup`, Enter. Megnyílik az Indítópult mappa.
2. Jobb klikk → **Új → Parancsikon** → Tallózás: válaszd ki a `start.bat` fájlt.
3. Jobb klikk az új parancsikonon → **Tulajdonságok**:
   - a **Cél** mező végére írd: ` --lan --no-browser` (a Tailscale-hez kell a `--lan`; Cloudflare-hez elég a ` --no-browser`);
   - **Futtatás:** Kis méretű ablak.
4. **Gépház → Rendszer → Kikapcsolás és akkumulátor / Energiagazdálkodás:** állítsd be, hogy a gép hálózati tápról **ne menjen alvó állapotba**.

Így a gép bekapcsolásakor az app magától elindul.

### A) Tailscale – ajánlott, ingyenes, a legegyszerűbb

A Tailscale egy privát hálózat a saját eszközeid között. Csak az éri el az appot, akinek az eszköze be van jelentkezve a te Tailscale-fiókodba.

1. Regisztrálj és töltsd le: <https://tailscale.com/download>
2. Telepítsd **az otthoni gépre** és **a telefonodra** (meg bármelyik eszközre, amiről használni szeretnéd), és **mindegyiken ugyanazzal a fiókkal** jelentkezz be.
3. Az otthoni gépen indítsd az appot `--lan` kapcsolóval (lásd az előkészítést).
4. A telefonon a Tailscale appban látod az otthoni gépet: a nevét (pl. `otthoni-pc`) és egy `100.x.y.z` kezdetű IP-címét.
5. A telefon böngészőjében nyisd meg: `http://otthoni-pc:8765` vagy `http://100.x.y.z:8765`

Ha nem töltődik be: a telefonon legyen bekapcsolva a Tailscale (VPN-ikon a felső sávban), és a Windows tűzfal engedje a Pythont. Ha az első indításkor csak a *Magánhálózat*ot engedélyezted, és Tailscale-en így nem megy: **Windows Biztonság → Tűzfal és hálózatvédelem → Alkalmazás engedélyezése a tűzfalon** → a `python.exe` sorában pipáld be a *Nyilvános* oszlopot is.

### B) Cloudflare Tunnel – saját webcím, app telepítése nélkül

Rendes webcímet kapsz (pl. `https://piac.sajatdomain.hu`), ami bármelyik böngészőből megnyílik, a belépést pedig a Cloudflare intézi (pl. e-mailben kapott kóddal). Kell hozzá **egy saját domain**, ami a Cloudflare-nél van kezelve (évi néhány ezer forint).

Röviden a lépések; a Cloudflare felülete változhat, a pontos, aktuális leírás: <https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/>

1. Telepítsd a `cloudflared` programot az otthoni gépre.
2. A Cloudflare Zero Trust felületén hozz létre egy **Tunnel**-t, és telepítsd szolgáltatásként a gépre a felület által adott paranccsal.
3. Adj hozzá egy nyilvános címet (pl. `piac.sajatdomain.hu`), és állítsd be, hogy a `http://localhost:8765` címre mutasson.
4. **Kötelező:** a Zero Trust **Access** részében hozz létre egy alkalmazást erre a címre, és egy szabályt, ami csak a **te e-mail-címedet** engedi be.

> ⚠️ **Access-védelem nélkül ne tedd ki az appot az internetre!** Az appnak nincs saját jelszava: bárki keresgélhetne vele a te internetedről, és ha megadtad, a te Facebook-belépéseddel. Ugyanezért ne használd a jelszó nélküli „gyors” alagutakat (pl. `trycloudflare.com`) sem.

### Online használat korlátai

- A **📋 Vágólapra** gomb csak az otthoni gépen működik; távolról a **⬇ Letöltés**t használd, és a letöltött PDF-et oszd meg az AI-appal.
- Ha az otthoni gép ki van kapcsolva vagy alszik, az app nem érhető el.

---

## 8. Frissítés új verzióra

1. Állítsd le az appot (zárd be a konzolablakot).
2. Töltsd le az új verziót (lásd [1. pont](#1-telepítés)), és csomagold ki **a régi mappa fölé**, felülírva a fájlokat.
   - A `.venv` mappa (telepített csomagok), a `settings.local.json` (Facebook-belépés) és az `exports` mappa így megmarad.
   - Ha új mappába csomagolod ki, a `settings.local.json`-t másold át a régiből.
3. Indítsd el a `start.bat`-tal. Ha az új verzió új csomagot igényel, az első indításkor magától telepíti.

---

## 9. Ha valami nem működik

Az oldalak időnként átalakítják a felépítésüket, vagy védekeznek az automatikus lekérés ellen. Ilyenkor az adott oldal kártyáján hiba vagy 0 találat látszik, de a többi oldal működik tovább, és a **Megnyitás ↗** link akkor is jó.

| Jelenség | Mit jelent, mit tegyél |
|---|---|
| Minden oldalnál `curl: (77) error adding trust anchors` | Régi verzió hibája ékezetes mappanévvel. Frissíts. |
| **Hardverapró**: „csak megnyitható · a gépi keresést a nyitóoldalra irányította” | A Hardverapró az új látogatót pár másodpercig robotnak nézi. Az app ezért indításkor előre „belátogat”, és csak 8 másodperc múlva keres. Ha mégis előfordul, keress újra kicsit később. |
| **Hardverapró**: kevesebb találat, mint az oldalon | Az app csak azokat a hirdetéseket tartja meg, amelyek **címében** a keresés minden szava szerepel, mert a Hardverapró fizetett, a kereséshez nem illő hirdetéseket is mutat. |
| **Vinted**: hiba vagy 0 találat | Ha sokszor keresel gyorsan egymás után, a Vinted ideiglenesen letilthat; pár perc múlva újra megy. |
| **Facebook**: „csak megnyitható” | A Facebook most nem adott találatot belépés nélkül (máskor szokott). Próbáld később, használd a linket, vagy add meg a belépést ([5. pont](#5-facebook-marketplace)). |
| **Facebook**: „A Facebook belépés lejárt” | Add meg újra a `c_user` és `xs` értéket. |
| Képek helyén „nincs kép” | Az oldal nem adta ki a képet; a hirdetésre kattintva megnézheted. |
| PDF-ben „(leírás nem érhető el)” | Az app nem tudta kiolvasni a hirdetés oldalát. A link a PDF-ben ilyenkor is ott van. |
| **Vágólapra** gomb hibát ír | Használd a Letöltést. Windowson a vágólapot a beépített PowerShell kezeli. |

### Hibakereső mód (ha segítséget kérsz)

1. Indítsd így: `start.bat --debug` (parancssorból, vagy a parancsikon *Cél* mezőjének végére: ` --debug`).
2. Futtasd le a hibás keresést.
3. Az app mappájában létrejön egy **`debug`** mappa: a `log.txt` és a letöltött oldalak. Ezeket küldd el annak, aki segít. Belépési adat és süti nem kerül bele.

**Csak a Hardverapróhoz:** a `diag.bat` többféle módon próbál keresni, és kiírja, melyik működik. Az eredmény a `debug\diag_hardverapro.txt` fájlba kerül.

---

## 10. Hol vannak az adataim?

| Mi | Hol |
|---|---|
| Mentett keresések, „ÚJ” jelölések, beállított város | a böngésződben, eszközönként külön |
| Facebook-belépés (`c_user`, `xs`), ha megadtad | `settings.local.json` az app mappájában, csak a te gépeden |
| Elkészült PDF-ek | `exports` mappa az app mappájában |
| Hibakereső fájlok | `debug` mappa (csak `--debug` módban jön létre) |
| Telepített csomagok | `.venv` mappa |

Ezek közül a `settings.local.json`, az `exports`, a `debug` és a `.venv` soha nem kerül fel a GitHubra.

A keresések 2 percig gyorsítótárban maradnak, hogy ugyanaz a keresés ne terhelje feleslegesen az oldalakat.
