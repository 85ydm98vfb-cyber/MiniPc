#!/bin/sh
# Configurare si securizare SSH pentru Alpine Linux.
#
# Utilizare (ca root):
#   NEW_USER=andrei PUBKEY="ssh-ed25519 AAAA... andrei@laptop" sh setup-ssh.sh
#
# Variabile (toate optionale):
#   NEW_USER   utilizator nou cu drept de sudo (doas); daca lipseste, nu se creeaza
#   PUBKEY     cheia publica SSH care va fi adaugata pentru NEW_USER (sau root)
#   SSH_PORT   portul SSH (implicit 22)
#   FIREWALL   1 = instaleaza si activeaza ufw (implicit 1)
#   FAIL2BAN   1 = instaleaza si activeaza fail2ban (implicit 1)
#
# Parola la SSH si login-ul ca root sunt dezactivate DOAR daca exista cel putin
# o cheie in authorized_keys, ca sa nu ramai blocat pe dinafara.

set -eu

SSH_PORT="${SSH_PORT:-22}"
FIREWALL="${FIREWALL:-1}"
FAIL2BAN="${FAIL2BAN:-1}"
NEW_USER="${NEW_USER:-}"
PUBKEY="${PUBKEY:-}"

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mEROARE:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Ruleaza scriptul ca root (su -)."
[ -f /etc/alpine-release ] || die "Scriptul este doar pentru Alpine Linux."

case "$SSH_PORT" in
    ''|*[!0-9]*) die "SSH_PORT invalid: $SSH_PORT" ;;
esac

log "Alpine $(cat /etc/alpine-release)"

# --- Repository community (pentru ufw, fail2ban, doas) ----------------------
if ! grep -Eq '^[^#].*/community/?$' /etc/apk/repositories; then
    log "Activez repository-ul community"
    # doar pentru versiunea curenta, nu si edge
    sed -i -E '/edge/!s|^#[[:space:]]*(.*/community/?)$|\1|' /etc/apk/repositories
    grep -Eq '^[^#].*/community/?$' /etc/apk/repositories || \
        die "Nu am putut activa community in /etc/apk/repositories - activeaza-l manual."
fi

log "Actualizez pachetele"
apk update
apk upgrade

PKGS="openssh doas"
[ "$FIREWALL" = 1 ] && PKGS="$PKGS ufw"
[ "$FAIL2BAN" = 1 ] && PKGS="$PKGS fail2ban"
log "Instalez: $PKGS"
# shellcheck disable=SC2086
apk add $PKGS

# --- Utilizator -------------------------------------------------------------
TARGET_USER=root
TARGET_HOME=/root
if [ -n "$NEW_USER" ]; then
    if id "$NEW_USER" >/dev/null 2>&1; then
        log "Utilizatorul $NEW_USER exista deja"
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

# --- Cheie SSH --------------------------------------------------------------
AUTH_KEYS="$TARGET_HOME/.ssh/authorized_keys"
if [ -n "$PUBKEY" ]; then
    log "Adaug cheia publica pentru $TARGET_USER"
    mkdir -p "$TARGET_HOME/.ssh"
    touch "$AUTH_KEYS"
    grep -qxF "$PUBKEY" "$AUTH_KEYS" || echo "$PUBKEY" >> "$AUTH_KEYS"
    chmod 700 "$TARGET_HOME/.ssh"
    chmod 600 "$AUTH_KEYS"
    chown -R "$TARGET_USER:" "$TARGET_HOME/.ssh" 2>/dev/null || \
        chown -R "$TARGET_USER" "$TARGET_HOME/.ssh"
fi

HAS_KEY=0
if [ -s "$AUTH_KEYS" ] && grep -Eq '^(ssh-|ecdsa-|sk-)' "$AUTH_KEYS"; then
    HAS_KEY=1
fi

# --- sshd -------------------------------------------------------------------
SSHD_DIR=/etc/ssh/sshd_config.d
CONF="$SSHD_DIR/10-minipc.conf"
mkdir -p "$SSHD_DIR"
if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d/' /etc/ssh/sshd_config; then
    log "Adaug Include pentru $SSHD_DIR in sshd_config"
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

log "Scriu $CONF"
cat > "$CONF" <<EOF
# Generat de setup-ssh.sh
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
log "Verific configuratia sshd"
sshd -t || die "Configuratie sshd invalida - verifica $CONF"

rc-update add sshd default >/dev/null
rc-service sshd restart

# --- Firewall ---------------------------------------------------------------
if [ "$FIREWALL" = 1 ]; then
    log "Configurez ufw (permit doar SSH pe portul $SSH_PORT)"
    ufw default deny incoming
    ufw default allow outgoing
    ufw limit "$SSH_PORT/tcp"
    ufw --force enable
    rc-update add ufw default >/dev/null
fi

# --- fail2ban ---------------------------------------------------------------
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

IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1)}')"
log "Gata!"
echo
echo "  Conectare:  ssh -p $SSH_PORT $TARGET_USER@${IP:-<ip-mini-pc>}"
echo "  Parola SSH: $PASS_AUTH   |   Root login: $ROOT_LOGIN"
echo
warn "NU inchide sesiunea curenta pana nu verifici conectarea dintr-un terminal nou."
