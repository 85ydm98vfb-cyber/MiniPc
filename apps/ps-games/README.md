# PlayStation Games pe Alpine

Instalatorul original al aplicației (`install.sh`) este pentru Ubuntu/Debian (apt, systemd, sudo).
`install-alpine.sh` face același lucru pe Alpine: serviciu OpenRC, utilizator de sistem `psgames`,
date în `/opt/ps-games/data`, port `8095` deschis doar pentru rețeaua de acasă.

Codul aplicației nu este în acest repo (repo-ul este public). Se copiază de pe laptop.

## Instalare

Pe laptop (PowerShell), în folderul unde este arhiva:

```powershell
scp .\ps-games-server.zip alex@192.168.0.187:~
ssh alex@192.168.0.187
```

Pe mini PC:

```sh
unzip -o ps-games-server.zip
cd ps-games-server
wget -O install-alpine.sh https://raw.githubusercontent.com/85ydm98vfb-cyber/MiniPc/claude/mini-pc-ssh-config-jx93hs/apps/ps-games/install-alpine.sh
doas sh install-alpine.sh
```

Cu datele existente: copiază și `PlayStation_Games.json` cu `scp`, apoi
`doas sh install-alpine.sh ~/PlayStation_Games.json`.

Aplicația: **http://192.168.0.187:8095**

## Administrare

| Ce            | Comandă                                         |
|---------------|-------------------------------------------------|
| Stare         | `doas rc-service ps-games status`               |
| Restart       | `doas rc-service ps-games restart`              |
| Log           | `doas tail -f /var/log/ps-games.log`            |
| Schimbă parola| `doas su -s /bin/sh psgames -c 'python3 /opt/ps-games/server.py --set-password'` apoi restart |
| Actualizare   | copiezi noua arhivă, apoi rulezi din nou `doas sh install-alpine.sh` (datele și parola rămân) |
