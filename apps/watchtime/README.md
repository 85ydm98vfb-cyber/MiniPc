# Watch Time – tracker de seriale și filme (înlocuitor TV Time)

Rulează pe mini PC-ul cu Ubuntu/Debian și are mai mulți utilizatori, fiecare cu listele lui.
Are nevoie doar de Python 3, care vine deja cu Ubuntu.

## 1. Cheia gratuită TMDB (seriale, filme, postere, episoade)

1. Fă-ți cont pe https://www.themoviedb.org/signup
2. Mergi la Settings → API și cere o cheie de tip „Developer”, pentru uz personal.
3. Copiază **API Read Access Token** (textul lung).

## 2. Instalare pe mini PC

Merge pe **Alpine Linux** (doas, OpenRC) și pe Ubuntu/Debian. Copiază `watchtime.zip` pe mini PC, apoi:

```sh
cd ~
unzip -o watchtime.zip
cd watchtime
./install.sh
```

Pe Alpine, dacă lipsește `unzip`, rulează `doas apk add unzip`.

## 3. Prima pornire: contul de admin

De pe telefon sau laptop conectat la **Wi-Fi-ul de acasă**, deschide `http://IP-mini-pc:8765`.
Adresa exactă o afișează scriptul la final.

Există două tipuri de conturi:

- **Admin**: doar administrează și merge **doar din Wi-Fi-ul de acasă**. Nu are liste de seriale.
  - **Utilizatori**: creează conturi, schimbă parole, redenumește, deconectează de pe toate dispozitivele, șterge.
  - **Setări**: cheia și limba TMDB, rețelele considerate „acasă”, cât timp rămâne logat un dispozitiv, limita de parole greșite.
  - **Sistem**: statistici server, backup complet al bazei, golire cache.
- **Utilizatori normali**: doar folosesc aplicația (Seriale, Filme, Discover, Caută, Profil).
  Fiecare pornește de la zero, cu listele lui, și merge de oriunde cu utilizator și parolă.

La prima pornire îți creezi adminul, apoi din **Utilizatori** îți faci contul tău normal.
Dacă n-ai pus cheia TMDB la instalare, o pui din **Setări**.

## 4. Acces din afara casei

**DuckDNS + Caddy (varianta ta, cu `public-web.sh`).** Watch Time trebuie să fie în `SITES`,
de exemplu `watch-time:8765`. Adresa de oriunde devine `https://watch-time.duckdns.org`.
Prin această adresă merg doar conturile normale. Contul **admin** îl folosești de acasă,
pe adresa directă `http://IP-mini-pc:8765`.

**Alternativă: Tailscale.** Rulezi `tailscale serve --bg 8765`, pentru acces doar de pe dispozitivele tale,
sau `tailscale funnel --bg 8765`, pentru acces public protejat de logare.

## 5. Pe ecranul iPhone-ului, ca aplicație

Deschide adresa în **Safari** → Share → **Add to Home Screen**.
Te loghezi o singură dată; sesiunea ține un an pe acel dispozitiv.

## Limbă: română și engleză

Aplicația are interfața completă în **română** și **engleză**, inclusiv mesajele de eroare.

- Pe ecranul de logare alegi limba din butoanele **Română / English**. La prima deschidere
  se folosește limba telefonului.
- După logare, limba se schimbă din **Profil → Limbă** (sau **Setări → Contul meu** la admin)
  și se salvează pe cont, deci o regăsești pe toate dispozitivele.
- Fiecare utilizator își alege limba lui.
- Titlurile și descrierile serialelor vin de la TMDB, în limba setată de admin
  (Setări → Limba titlurilor). `en-US` e cea mai completă.

## Ecranul Seriale

- **De văzut** (se deschide implicit): serialele pe care le urmărești, cu următorul episod de bifat.
  Când apar episoade sau un sezon nou, serialul revine singur aici (cu eticheta „Sezon nou”).
- **Neîncepute**: seriale adăugate din care n-ai văzut încă nimic.
- **În curând**: episoade și premiere anunțate, cu numărul de zile rămase.
- **Văzute**: istoricul episoadelor văzute stă deasupra listei, ascuns. Derulezi în sus ca să-l vezi;
  „Mai vechi” încarcă restul.
- **Colecția mea** (link sub taburi): toate serialele pe statusuri, inclusiv Rewatched, Terminate, Abandonate.

La **Filme**: De văzut / În curând / Văzute. Poți adăuga filme înainte de lansare; ele stau în
„În curând” cu zilele rămase și trec singure în „De văzut” din ziua lansării.

## Import din Trakt

**Profil → Importă date → Alege fișierul.** Poți încărca arhiva .zip din exportul Trakt, fișierele .json din ea
sau o copie de siguranță Watch Time.

Se preiau episoadele și filmele văzute (cu data), vizionările multiple, watchlist-ul și notele
(Trakt 1–10 devine 1–5 stele). Titlurile fără ID TMDB în export sunt sărite, iar la final vezi câte au fost.
Importul rulează pe server, așa că poți închide pagina. Îl poți repeta fără să se dubleze nimic.

## Profil → Listele mele

Toate serialele și filmele tale, pe categorii (Urmăresc, Rewatched, De văzut, Terminate, Abandonate;
filme De văzut / Văzut). Atingi o categorie și vezi toate titlurile din ea.

## Notificări

Serverul verifică **la 11:30 și 18:30** (orele se schimbă din admin → Setări) dacă au apărut episoade noi
la serialele tale sau filme din lista De văzut, și trimite o notificare pe telefon.

- Pe mini PC trebuie pachetul `py3-cryptography` (îl instalează `install.sh`, sau manual: `doas apk add py3-cryptography`).
- Pe iPhone (iOS 16.4+): deschide adresa **https** în Safari → Share → Add to Home Screen, deschide Watch Time
  de pe ecran, apoi **Profil → Notificări → Activează**.
- Fiecare utilizator alege ce primește (episoade / filme) și poate trimite o notificare de test.

## Rewatch și vizionări multiple

- Un episod bifat se poate marca **văzut din nou** (2×, 3×, …): atinge bifa verde.
  Din același meniu poți scoate o vizionare.
- La un serial văzut complet apare butonul **Revăd serialul**. Serialul trece în tab-ul
  **Rewatched** și în „Urmează” îți arată ce ai de revăzut. Când ai revăzut toate episoadele,
  iese singur din Rewatched și revine la statusul dinainte.
- La filme: **Văzut din nou** adaugă încă o vizionare.

## Comenzi utile

Pe Alpine:

```sh
doas rc-service watchtime restart    # repornire
doas rc-service watchtime status     # stare
tail -n 50 /var/log/watchtime.log    # ultimele mesaje sau erori
```

Pe Ubuntu: `sudo systemctl restart watchtime`, `journalctl -u watchtime -n 50`.

## Setări (`config.json`)

Majoritatea se schimbă din aplicație (admin → Setări). Direct în fișier rămân doar
`port` și `host`, după care repornești serviciul.
Limba `en-US` e cea mai completă; cu `ro-RO` multe episoade apar doar ca „Episodul 5”.

## Date și backup

Totul e în `data/watchtime.db` (SQLite). Copiază fișierul ca backup, sau folosește
**Profil → Copie de siguranță** (datele unui singur cont) sau, ca admin, **Sistem → Backup complet**.
