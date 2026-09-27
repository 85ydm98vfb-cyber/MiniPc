#!/bin/sh
# Setup complet pentru mini PC cu Alpine Linux - rulezi o data si se face tot:
#   SSH securizat, firewall, fail2ban, ora, utilitare, Python, Docker,
#   interfata web Portainer si (optional) interfata grafica pe monitor.
#
# Utilizare:
#   doas sh setup.sh                          (logat prin SSH cu utilizatorul tau)
#   NEW_USER=andrei PUBKEY="ssh-ed25519 AAAA..." sh setup.sh   (instalare noua, ca root)
#
# Variabile (toate optionale):
#   NEW_USER    utilizatorul tau (implicit: cel care a rulat doas); se creeaza daca nu exista
#   PUBKEY      cheie publica SSH de adaugat pentru NEW_USER
#   SSH_PORT    portul SSH (implicit: cel configurat deja, altfel 22)
#   TZ_NAME     fusul orar (implicit Europe/Bucharest)
#   FIREWALL    1 = ufw (implicit 1)
#   FAIL2BAN    1 = fail2ban (implicit 1)
#   PYTHON      1 = Python 3 + pip + venv + pipx (implicit 1)
#   DOCKER      1 = Docker + docker compose (implicit 1)
#   PORTAINER   1 = interfata web pe https://IP:9443 (implicit 1, necesita DOCKER=1)
#   WEB_PORTS   1 = deschide porturile 80 si 443 pentru aplicatii (implicit 1)
#   AUTO_UPDATE 1 = actualizari automate zilnice ale pachetelor (implicit 1)
#   DESKTOP     xfce / gnome / plasma / mate / sway = interfata grafica pe monitor
#
# Parola la SSH si login-ul ca root sunt dezactivate DOAR daca exista cel putin
# o cheie in authorized_keys, ca sa nu ramai blocat pe dinafara.
# Scriptul poate fi rulat de mai multe ori fara probleme.

set -eu

CONF=/etc/ssh/sshd_config.d/10-minipc.conf
OLD_PORT="$(awk '$1 == "Port" {print $2}' "$CONF" 2>/dev/null || true)"

NEW_USER="${NEW_USER:-${DOAS_USER:-${SUDO_USER:-}}}"
PUBKEY="${PUBKEY:-}"
SSH_PORT="${SSH_PORT:-${OLD_PORT:-22}}"
TZ_NAME="${TZ_NAME:-Europe/Bucharest}"
FIREWALL="${FIREWALL:-1}"
FAIL2BAN="${FAIL2BAN:-1}"
PYTHON="${PYTHON:-1}"
DOCKER="${DOCKER:-1}"
PORTAINER="${PORTAINER:-1}"
WEB_PORTS="${WEB_PORTS:-1}"
AUTO_UPDATE="${AUTO_UPDATE:-1}"
DESKTOP="${DESKTOP:-}"

[ "$NEW_USER" = root ] && NEW_USER=

log() { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mEROARE:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Ruleaza ca root sau cu doas: doas sh setup.sh"
[ -f /etc/alpine-release ] || die "Scriptul este doar pentru Alpine Linux."
case "$SSH_PORT" in
    ''|*[!0-9]*) die "SSH_PORT invalid: $SSH_PORT" ;;
esac
[ "$DOCKER" = 1 ] || PORTAINER=0

log "Alpine $(cat /etc/alpine-release)"

# === 1. Pachete ==============================================================
if ! grep -Eq '^[^#].*/community/?$' /etc/apk/repositories; then
    log "Activez repository-ul community"
    # doar pentru versiunea curenta, nu si edge
    sed -i -E '/edge/!s|^#[[:space:]]*(.*/community/?)$|\1|' /etc/apk/repositories
    grep -Eq '^[^#].*/community/?$' /etc/apk/repositories || \
        die "Nu am putut activa community in /etc/apk/repositories - activeaza-l manual."
fi

log "Actualizez sistemul"
apk update
apk upgrade

PKGS="openssh doas tzdata chrony bash curl git nano htop ca-certificates"
[ "$FIREWALL" = 1 ] && PKGS="$PKGS ufw"
[ "$FAIL2BAN" = 1 ] && PKGS="$PKGS fail2ban"
[ "$PYTHON" = 1 ] && PKGS="$PKGS python3 py3-pip py3-virtualenv pipx python3-dev build-base"
[ "$DOCKER" = 1 ] && PKGS="$PKGS docker docker-cli-compose"
log "Instalez pachetele"
# shellcheck disable=SC2086
apk add $PKGS

# === 2. Utilizator + cheie SSH ==============================================
TARGET_USER=root
TARGET_HOME=/root
if [ -n "$NEW_USER" ]; then
    if id "$NEW_USER" >/dev/null 2>&1; then
        log "Utilizator: $NEW_USER (exista deja)"
    else
        log "Creez utilizatorul $NEW_USER"
        adduser -D -s /bin/ash "$NEW_USER"
        warn "Seteaza o parola pentru $NEW_USER (necesara pentru doas):"
        passwd "$NEW_USER"
    fi
    addgroup "$NEW_USER" wheel 2>/dev/null || true
    mkdir -p /etc/doas.d
    echo 'permit persist :wheel' > /etc/doas.d/wheel.conf
    chmod 600 /etc/doas.d/wheel.conf
    TARGET_USER="$NEW_USER"
    TARGET_HOME="$(getent passwd "$NEW_USER" | cut -d: -f6)"
fi

AUTH_KEYS="$TARGET_HOME/.ssh/authorized_keys"
if [ -n "$PUBKEY" ]; then
    log "Adaug cheia publica pentru $TARGET_USER"
    mkdir -p "$TARGET_HOME/.ssh"
    touch "$AUTH_KEYS"
    grep -qxF "$PUBKEY" "$AUTH_KEYS" || echo "$PUBKEY" >> "$AUTH_KEYS"
    chmod 700 "$TARGET_HOME/.ssh"
    chmod 600 "$AUTH_KEYS"
    chown -R "$TARGET_USER" "$TARGET_HOME/.ssh"
fi

HAS_KEY=0
if [ -s "$AUTH_KEYS" ] && grep -Eq '^(ssh-|ecdsa-|sk-)' "$AUTH_KEYS"; then
    HAS_KEY=1
fi

# === 3. SSH =================================================================
mkdir -p /etc/ssh/sshd_config.d
if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d/' /etc/ssh/sshd_config; then
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
fi

if [ "$HAS_KEY" = 1 ]; then
    PASS_AUTH=no
    if [ "$TARGET_USER" = root ]; then ROOT_LOGIN=prohibit-password; else ROOT_LOGIN=no; fi
else
    warn "Nu exista nicio cheie in $AUTH_KEYS - las autentificarea cu parola activa."
    warn "Ruleaza din nou scriptul cu PUBKEY=... ca sa o dezactivezi."
    PASS_AUTH=yes
    if [ "$TARGET_USER" = root ]; then ROOT_LOGIN=yes; else ROOT_LOGIN=prohibit-password; fi
fi

log "Configurez SSH (port $SSH_PORT, parola: $PASS_AUTH, root: $ROOT_LOGIN)"
cat > "$CONF" <<EOF
# Generat de setup.sh
Port $SSH_PORT
PermitRootLogin $ROOT_LOGIN
PasswordAuthentication $PASS_AUTH
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowAgentForwarding no
EOF

ssh-keygen -A >/dev/null
sshd -t || die "Configuratie sshd invalida - verifica $CONF"
rc-update add sshd default >/dev/null

# === 4. Firewall ============================================================
# Regula SSH se adauga inainte de restartul sshd, ca sa nu pierzi conexiunea.
if [ "$FIREWALL" = 1 ]; then
    log "Configurez firewall-ul (ufw)"
    ufw default deny incoming
    ufw default allow outgoing
    ufw limit "$SSH_PORT/tcp" comment 'SSH'
    [ "$PORTAINER" = 1 ] && ufw allow 9443/tcp comment 'Portainer'
    if [ "$WEB_PORTS" = 1 ]; then
        ufw allow 80/tcp comment 'HTTP'
        ufw allow 443/tcp comment 'HTTPS'
    fi
    ufw --force enable
    rc-update add ufw default >/dev/null
fi

rc-service sshd restart

# === 5. fail2ban ============================================================
if [ "$FAIL2BAN" = 1 ]; then
    log "Configurez fail2ban"
    # Alpine logheaza sshd prin syslog in /var/log/messages
    rc-update add syslog boot >/dev/null 2>&1 || true
    rc-service syslog start >/dev/null 2>&1 || true
    touch /var/log/messages
    cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled  = true
port     = $SSH_PORT
logpath  = /var/log/messages
backend  = auto
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
    rc-update add fail2ban default >/dev/null
    rc-service fail2ban restart
fi

# === 6. Ora =================================================================
log "Fus orar: $TZ_NAME + sincronizare ora"
[ -f "/usr/share/zoneinfo/$TZ_NAME" ] || die "Fus orar necunoscut: $TZ_NAME"
cp "/usr/share/zoneinfo/$TZ_NAME" /etc/localtime
echo "$TZ_NAME" > /etc/timezone
rc-update add chronyd default >/dev/null
rc-service chronyd restart

# === 7. Actualizari automate ================================================
if [ "$AUTO_UPDATE" = 1 ]; then
    log "Activez actualizarile automate (zilnic, log in /var/log/auto-update.log)"
    cat > /etc/periodic/daily/auto-update <<'EOF'
#!/bin/sh
# Generat de setup.sh - actualizeaza zilnic pachetele Alpine.
LOG=/var/log/auto-update.log
# pastreaza logul mic
[ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 1000000 ] && \
    tail -n 2000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
{
    echo "=== $(date)"
    apk update -q && apk upgrade --no-progress
    # kernel nou instalat -> e nevoie de restart (nu reporneste singur)
    if [ ! -d "/lib/modules/$(uname -r)" ]; then
        echo "Kernel nou instalat - ruleaza: doas reboot"
        touch /run/reboot-required
    fi
} >> "$LOG" 2>&1
EOF
    chmod 755 /etc/periodic/daily/auto-update
    rc-update add crond default >/dev/null
    rc-service crond start >/dev/null 2>&1 || true
else
    rm -f /etc/periodic/daily/auto-update
fi

# === 8. Python ==============================================================
if [ "$PYTHON" = 1 ]; then
    log "Python: $(python3 --version)"
    if [ -n "$NEW_USER" ]; then
        # ca pipx install ... sa fie in PATH
        PROFILE="$TARGET_HOME/.profile"
        touch "$PROFILE"
        grep -q '.local/bin' "$PROFILE" || \
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$PROFILE"
        chown "$TARGET_USER" "$PROFILE"
    fi
fi

# === 9. Docker + Portainer ==================================================
if [ "$DOCKER" = 1 ]; then
    log "Pornesc Docker"
    rc-update add docker default >/dev/null
    rc-service docker start
    i=0
    until docker info >/dev/null 2>&1; do
        i=$((i + 1))
        [ "$i" -le 30 ] || die "Docker nu a pornit - vezi /var/log/docker.log"
        sleep 1
    done
    [ -n "$NEW_USER" ] && addgroup "$NEW_USER" docker 2>/dev/null || true
fi

if [ "$PORTAINER" = 1 ]; then
    log "Instalez interfata web Portainer"
    docker pull portainer/portainer-ce:lts
    docker rm -f portainer >/dev/null 2>&1 || true
    docker run -d \
        --name portainer \
        --restart=always \
        -p 9443:9443 \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v portainer_data:/data \
        portainer/portainer-ce:lts >/dev/null
fi

# === 10. Interfata grafica pe monitor (optional) =============================
if [ -n "$DESKTOP" ]; then
    command -v setup-desktop >/dev/null || apk add alpine-conf
    log "Instalez interfata grafica: $DESKTOP"
    setup-desktop "$DESKTOP"
fi

# === Rezumat ================================================================
IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1)}')"
IP="${IP:-<ip-mini-pc>}"
log "GATA!"
echo
echo "  SSH:        ssh -p $SSH_PORT $TARGET_USER@$IP   (parola: $PASS_AUTH, root: $ROOT_LOGIN)"
echo "  Ora:        $(date)"
[ "$PYTHON" = 1 ] && echo "  Python:     $(python3 --version 2>&1)"
[ "$DOCKER" = 1 ] && echo "  Docker:     $(docker --version)"
[ "$WEB_PORTS" = 1 ] && [ "$FIREWALL" = 1 ] && echo "  Porturi:    80 si 443 deschise pentru aplicatii"
[ "$AUTO_UPDATE" = 1 ] && echo "  Update:     automat, zilnic (log: /var/log/auto-update.log)"
if [ "$PORTAINER" = 1 ]; then
    echo "  Interfata:  https://$IP:9443"
    sleep 3
    TOKEN_LINE="$(docker logs portainer 2>&1 | grep -i 'token' | tail -n 1 || true)"
    [ -n "$TOKEN_LINE" ] && echo "  Setup token (din logul Portainer): $TOKEN_LINE"
    echo
    warn "Deschide interfata in 5 minute si creeaza contul de admin."
    warn "Daca expira: doas docker restart portainer (token nou: doas docker logs portainer)"
    warn "Browserul va avertiza de certificat (e auto-semnat) - alege 'Continua'."
fi
echo
[ -n "$NEW_USER" ] && warn "Delogheaza-te si logheaza-te din nou (docker fara doas, PATH pentru pipx)."
[ -n "$DESKTOP" ] && warn "Reporneste (doas reboot) ca sa apara interfata grafica pe monitor."
warn "NU inchide sesiunea curenta pana nu verifici conectarea SSH dintr-un terminal nou."
exit 0
