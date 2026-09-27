# MiniPc

Setup complet pentru un mini PC cu **Alpine Linux**: un singur script, `setup.sh`,
rulat o singură dată.

## Ce face

| Parte            | Detalii                                                                   |
|------------------|---------------------------------------------------------------------------|
| Sistem           | activează repository-ul `community`, actualizează tot                     |
| Utilizator       | creează utilizatorul tău (dacă nu există), admin prin `doas`              |
| SSH              | doar cu cheie, fără login root, max. 3 încercări                          |
| Firewall (`ufw`) | blochează tot ce intră, în afară de SSH, interfața web și porturile 80/443 |
| `fail2ban`       | blochează 1 oră IP-urile care greșesc de 5 ori                            |
| Ora              | fus orar `Europe/Bucharest`, sincronizare automată (chrony)               |
| Utilitare        | `bash`, `curl`, `git`, `nano`, `htop`                                     |
| **Python**       | `python3`, `pip`, `venv`, `pipx`, compilatoare pentru pachete native      |
| **Docker**       | `docker` + `docker compose`, utilizabil fără `doas`                       |
| **Interfață web**| Portainer pe **https://IP-mini-pc:9443**                                  |
| Actualizări      | automate, zilnic, prin `crond` (log: `/var/log/auto-update.log`)          |
| Desktop          | opțional: interfață grafică pe monitorul mini PC-ului                     |

Parola SSH se dezactivează **doar dacă există o cheie**, ca să nu rămâi blocat pe dinafară.
Scriptul poate fi rulat de mai multe ori fără probleme.

## Rulare

### Dacă te poți loga deja prin SSH cu utilizatorul tău

```sh
cd MiniPc && git pull          # sau: git clone -b claude/mini-pc-ssh-config-jx93hs https://github.com/85ydm98vfb-cyber/MiniPc.git
doas sh setup.sh
```

### Instalare nouă, logat ca root

Pe laptop: `ssh-keygen -t ed25519` și `cat ~/.ssh/id_ed25519.pub`. Apoi pe mini PC:

```sh
apk add git
git clone -b claude/mini-pc-ssh-config-jx93hs https://github.com/85ydm98vfb-cyber/MiniPc.git
cd MiniPc
NEW_USER=numele_tau PUBKEY="ssh-ed25519 AAAA...cheia_ta..." sh setup.sh
```

### Interfață grafică (desktop) + Remote Desktop din Windows

```sh
wget -O desktop.sh https://raw.githubusercontent.com/85ydm98vfb-cyber/MiniPc/claude/mini-pc-ssh-config-jx93hs/desktop.sh
doas sh desktop.sh
doas reboot
```

Instalează XFCE, Firefox și câteva aplicații, plus `xrdp` pe portul 3389 (doar din rețeaua de acasă).
Din Windows: **Remote Desktop Connection** (`mstsc`) → IP-ul mini PC-ului → utilizatorul și parola ta → *Session: Xorg*.

## După rulare

1. Testează SSH-ul dintr-un **terminal nou** înainte să-l închizi pe cel vechi.
2. Deschide **https://IP-mini-pc:9443** în primele 5 minute și creează contul de admin
   (altfel: `doas docker restart portainer`). Avertismentul de certificat este normal.
3. Delogează-te și loghează-te din nou, ca să poți folosi `docker` fără `doas`.

Python — folosește medii virtuale (pe Alpine `pip install` global este blocat):

```sh
python3 -m venv ~/venv && . ~/venv/bin/activate && pip install requests
pipx install httpie            # pentru aplicații de linie de comandă
```

Actualizările automate nu repornesc niciodată mini PC-ul. Dacă se instalează un kernel nou,
apare mesajul în `/var/log/auto-update.log` și fișierul `/run/reboot-required`; atunci rulezi `doas reboot`.

> Docker ocolește `ufw` pentru porturile containerelor. Nu deschide portul 9443
> spre internet din router.

## Opțiuni

| Variabilă   | Implicit                   | Descriere                                   |
|-------------|----------------------------|---------------------------------------------|
| `NEW_USER`  | cel care a rulat `doas`    | utilizatorul tău                            |
| `PUBKEY`    | –                          | cheie publică SSH de adăugat                |
| `SSH_PORT`  | cel configurat deja / `22` | portul SSH                                  |
| `TZ_NAME`   | `Europe/Bucharest`         | fusul orar                                  |
| `FIREWALL`  | `1`                        | `0` = fără ufw                              |
| `FAIL2BAN`  | `1`                        | `0` = fără fail2ban                         |
| `PYTHON`    | `1`                        | `0` = fără Python                           |
| `DOCKER`    | `1`                        | `0` = fără Docker (și fără Portainer)       |
| `PORTAINER` | `1`                        | `0` = fără interfață web                    |
| `WEB_PORTS` | `1`                        | `0` = nu deschide porturile 80 și 443       |
| `AUTO_UPDATE` | `1`                      | `0` = fără actualizări automate             |
| `DESKTOP`   | –                          | `xfce`, `gnome`, `plasma`, `mate`, `sway`   |

Configurația SSH: `/etc/ssh/sshd_config.d/10-minipc.conf`.
