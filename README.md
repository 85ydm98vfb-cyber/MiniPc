# MiniPc

Configurare SSH pentru un mini PC cu **Alpine Linux**.

## Ce face `setup-ssh.sh`

- activează repository-ul `community` și actualizează sistemul
- instalează `openssh`, `doas` (în loc de sudo), `ufw` și `fail2ban`
- creează opțional un utilizator nou, cu drepturi de administrator prin `doas`
- adaugă cheia ta publică SSH
- securizează `sshd`: dezactivează parola și login-ul ca root, limitează încercările de autentificare
  - parola este dezactivată **doar dacă există o cheie**, ca să nu rămâi blocat pe dinafară
- firewall: blochează tot traficul care intră, cu excepția SSH
- fail2ban: blochează 1 oră IP-urile care greșesc de 5 ori
- pornește serviciile automat la boot (OpenRC)

## Pași

### 1. Pe laptop / PC — generezi o cheie (dacă nu ai deja)

```sh
ssh-keygen -t ed25519
cat ~/.ssh/id_ed25519.pub      # copiezi linia afișată
```

(Pe Windows rulezi aceleași comenzi în PowerShell.)

### 2. Pe mini PC — logat ca root

```sh
apk add git
git clone -b claude/mini-pc-ssh-config-jx93hs https://github.com/85ydm98vfb-cyber/MiniPc.git
cd MiniPc

NEW_USER=numele_tau \
PUBKEY="ssh-ed25519 AAAA...cheia_ta... user@laptop" \
sh setup-ssh.sh
```

Dacă repo-ul este privat, copiază scriptul pe mini PC altfel, de exemplu pe un stick USB
sau cu `scp setup-ssh.sh root@IP:/root/`.

### 3. Testezi dintr-un terminal NOU (nu închide sesiunea veche!)

```sh
ssh numele_tau@IP-mini-pc
doas apk update                # test drepturi de administrator
```

## Opțiuni

| Variabilă  | Implicit | Descriere                                   |
|------------|----------|---------------------------------------------|
| `NEW_USER` | –        | utilizator nou, membru al grupului `wheel`  |
| `PUBKEY`   | –        | cheia publică SSH                           |
| `SSH_PORT` | `22`     | portul SSH                                  |
| `FIREWALL` | `1`      | `0` = nu instala / activa ufw               |
| `FAIL2BAN` | `1`      | `0` = nu instala / activa fail2ban          |

Scriptul poate fi rulat de mai multe ori fără probleme. Configurația SSH se află în
`/etc/ssh/sshd_config.d/10-minipc.conf`.
