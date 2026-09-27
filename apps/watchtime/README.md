# Watch Time pe Alpine

Instalatorul original (`install.sh`) este pentru Ubuntu/Debian (apt, systemd, sudo).
`install-alpine.sh` face același lucru pe Alpine: serviciu OpenRC, utilizator de sistem `watchtime`,
aplicația în `/opt/watchtime`, port `8765` deschis doar pentru rețeaua de acasă.
Codul aplicației nu este în acest repo (repo-ul este public). Se copiază de pe laptop.

## Instalare

Pe laptop (PowerShell), în folderul cu arhiva:

```powershell
scp .\watchtime.zip alex@192.168.0.187:~
ssh alex@192.168.0.187
```

Pe mini PC:

```sh
unzip -o watchtime.zip
cd watchtime
wget -O install-alpine.sh https://raw.githubusercontent.com/85ydm98vfb-cyber/MiniPc/claude/mini-pc-ssh-config-jx93hs/apps/watchtime/install-alpine.sh
doas sh install-alpine.sh
```

Scriptul cere cheia TMDB (API Read Access Token) — sau Enter și o pui mai târziu din Setări, ca admin.
Prima deschidere, pentru contul de admin, se face din Wi-Fi-ul de acasă: **http://192.168.0.187:8765**.

## Acces de oriunde

Pe duckdns.org adaugi încă un subdomeniu (ex. `watchtime-alex`), apoi:

```sh
doas env SITES="psgames:8095 watchtime-alex:8765" sh public-web.sh
```

Adminul rămâne blocat din afara casei (aplicația îl permite doar din Wi-Fi); utilizatorii normali merg de oriunde.

## Administrare

| Ce          | Comandă                                  |
|-------------|------------------------------------------|
| Stare       | `doas rc-service watchtime status`       |
| Restart     | `doas rc-service watchtime restart`      |
| Log         | `doas tail -f /var/log/watchtime.log`    |
| Actualizare | copiezi noua arhivă și rulezi din nou `doas sh install-alpine.sh` (datele și setările rămân) |
| Backup      | `/opt/watchtime/data/watchtime.db` sau din aplicație: Sistem → Backup complet |
