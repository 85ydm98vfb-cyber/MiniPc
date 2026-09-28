# MiniPc

Mini PC cu **Alpine Linux**: patru scripturi, fiecare rulat cu `doas` prin SSH.

| Script         | Ce face |
|----------------|---------|
| `setup.sh`     | sistemul: SSH doar cu cheie, firewall, fail2ban, ora, Python, actualizări automate, desktop XFCE + Remote Desktop |
| `PSgames.sh`   | instalează / actualizează **PlayStation Games** (port 8095) și, opțional, adresa `https://…duckdns.org` |
| `watchtime.sh` | instalează / actualizează **Watch Time** (port 8765) și, opțional, adresa `https://…duckdns.org` |
| `backup.sh`    | backup pe stick USB pentru datele ambelor aplicații (manual sau automat, lunea) |

Scripturile pot fi rulate de oricâte ori: datele, parolele și setările rămân.
Codul aplicațiilor nu este în acest repo — arhivele `.zip` le copiezi de pe laptop.

## 1. `setup.sh` — sistemul

Instalare nouă, logat ca root (cheia publică de pe laptop: `cat ~/.ssh/id_ed25519.pub`):

```sh
wget -O setup.sh https://raw.githubusercontent.com/85ydm98vfb-cyber/MiniPc/claude/mini-pc-ssh-config-jx93hs/setup.sh
NEW_USER=alex PUBKEY="ssh-ed25519 AAAA..." sh setup.sh
doas reboot
```

Pe un sistem deja configurat, logat ca utilizatorul tău: `doas sh setup.sh`.

| Variabilă     | Implicit                   | Descriere |
|---------------|----------------------------|-----------|
| `NEW_USER`    | cel care a rulat `doas`    | utilizatorul tău (admin prin `doas`) |
| `PUBKEY`      | –                          | cheie publică SSH de adăugat |
| `SSH_PORT`    | cel configurat / `22`      | portul SSH |
| `TZ_NAME`     | `Europe/Bucharest`         | fusul orar |
| `FIREWALL`    | `1`                        | ufw: SSH, 80, 443 deschise; restul doar din LAN |
| `FAIL2BAN`    | `1`                        | blochează IP-urile care greșesc SSH |
| `PYTHON`      | `1`                        | python3, pip, venv, pipx, compilatoare |
| `AUTO_UPDATE` | `1`                        | `apk upgrade` zilnic, fără restart automat |
| `DESKTOP`     | `1`                        | XFCE + Firefox + Remote Desktop (3389, doar LAN) |
| `DOCKER`      | `0`                        | `1` = Docker + Portainer |
| `WEB_PORTS`   | `1`                        | deschide 80 și 443 pentru aplicații |

Remote Desktop din Windows: `mstsc` → `192.168.0.187` → *Session: Xorg*, utilizatorul și parola ta.

## 2. Aplicațiile

Copiezi arhiva de pe laptop (PowerShell), apoi rulezi scriptul pe mini PC:

```powershell
scp .\watchtime.zip alex@192.168.0.187:~
```

```sh
wget -O watchtime.sh https://raw.githubusercontent.com/85ydm98vfb-cyber/MiniPc/claude/mini-pc-ssh-config-jx93hs/watchtime.sh
doas sh watchtime.sh ~/watchtime.zip
```

La fel pentru PlayStation Games:

```sh
wget -O PSgames.sh https://raw.githubusercontent.com/85ydm98vfb-cyber/MiniPc/claude/mini-pc-ssh-config-jx93hs/PSgames.sh
doas sh PSgames.sh ~/ps-games-server.zip
```

**Actualizare** = aceiași pași cu arhiva nouă. Scripturile nu ating `data/` și `config.json`.
Nu folosi `install.sh` din arhive: acela rulează aplicația din alt folder, cu o bază de date goală.

### Acces de oriunde (DuckDNS + Caddy, HTTPS)

Condiții: IP public, port forwarding **80** și **443** (TCP) în router către mini PC,
câte un subdomeniu pe https://www.duckdns.org pentru fiecare aplicație.

```sh
doas env DOMAIN=psgames DUCK_TOKEN=tokenul-tau sh PSgames.sh ~/ps-games-server.zip
doas env DOMAIN=watch-time sh watchtime.sh ~/watchtime.zip      # tokenul se ia din /etc/duckdns.conf
```

Toate aplicațiile publicate sunt ținute în `/etc/duckdns.conf`; Caddy obține și reînnoiește singur certificatele.
Adminul Watch Time merge doar de acasă, pe `http://192.168.0.187:8765`.

| Aplicație        | Serviciu     | Date                          | Log |
|------------------|--------------|-------------------------------|-----|
| PlayStation Games| `ps-games`   | `/opt/ps-games/data`          | `/var/log/ps-games.log` |
| Watch Time       | `watchtime`  | `/opt/watchtime/data`         | `/var/log/watchtime.log` |

Comenzi: `doas rc-service <serviciu> status | restart`, `doas tail -f <log>`.

**Watchdog:** la fiecare 5 minute se verifică dacă fiecare aplicație răspunde; dacă nu (de două ori la rând),
serviciul e repornit automat. Restarturile, cu ultimele linii din log, sunt în `/var/log/app-watchdog.log`.

## 3. `backup.sh` — backup pe stick USB

```sh
wget -O backup.sh https://raw.githubusercontent.com/85ydm98vfb-cyber/MiniPc/claude/mini-pc-ssh-config-jx93hs/backup.sh
doas sh backup.sh           # backup acum (prima dată pregătește stick-ul)
doas sh backup.sh --auto    # + automat în fiecare luni la 03:30
doas sh backup.sh --list    # backup-urile de pe stick
doas sh backup.sh --no-auto # oprește backup-ul automat
```

Pe stick (FAT32, exFAT sau NTFS): `minipc-backup/AAAA-LL-ZZ_HH-MM/` cu `ps-games/*.json` și
`watchtime/watchtime.db` + `config.json`. Fiecare copie e verificată (`SHA256SUMS`); se păstrează ultimele 30.
Backup-ul automat scrie doar pe un stick care are deja folderul `minipc-backup/`.
Între backup-uri stick-ul e deconectat din sistem (rămâne în port, dar nu e vizibil și nu se scrie nimic pe el);
scriptul îl reconectează singur înainte de backup. Log: `/var/log/minipc-backup.log`.

**Restaurare** (ex. Watch Time): `doas rc-service watchtime stop`, copiezi `watchtime.db` de pe stick în
`/opt/watchtime/data/` (`doas chown watchtime:watchtime` pe fișier), apoi `doas rc-service watchtime start`.
La PS Games la fel, cu fișierele `.json` în `/opt/ps-games/data/` și `psgames:psgames`.
