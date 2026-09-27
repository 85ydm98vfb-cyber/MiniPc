#!/bin/sh
# Instalare PlayStation Games pe mini PC cu Alpine Linux (OpenRC).
# Se ruleaza din folderul aplicatiei (cel cu server.py si public/):
#   doas sh install-alpine.sh                          instalare / actualizare
#   doas sh install-alpine.sh PlayStation_Games.json   instalare + incarca datele tale
#   doas env PORT=8096 sh install-alpine.sh            alt port (implicit 8095)
set -eu

APP=/opt/ps-games
PORT="${PORT:-8095}"
SVC=ps-games
LOG=/var/log/ps-games.log
cd "$(dirname "$0")"

die() { printf '\033[1;31mEROARE:\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "Ruleaza cu doas:  doas sh install-alpine.sh"
[ -f server.py ] && [ -f public/index.html ] && [ -f public/login.html ] || \
    die "Ruleaza scriptul din folderul aplicatiei (cel cu server.py si public/)."
if [ -n "${1:-}" ] && [ ! -f "$1" ]; then
    die "Nu gasesc fisierul $1"
fi
case "$PORT" in
    ''|*[!0-9]*) die "PORT invalid: $PORT" ;;
esac

command -v python3 >/dev/null || apk add python3

# --- utilizator de sistem, fara login -----------------------------------------
if ! id psgames >/dev/null 2>&1; then
    log "Creez utilizatorul de sistem psgames"
    addgroup -S psgames
    adduser -S -D -H -h "$APP" -s /sbin/nologin -G psgames psgames
fi

# --- fisierele aplicatiei ------------------------------------------------------
log "Copiez aplicatia in $APP"
mkdir -p "$APP/public" "$APP/data"
install -m 644 server.py "$APP/server.py"
install -m 644 public/index.html public/login.html "$APP/public/"
chown -R psgames:psgames "$APP/data"
chmod 700 "$APP/data"

if [ -n "${1:-}" ]; then
    install -o psgames -g psgames -m 600 "$1" "$APP/data/PlayStation_Games.json"
    log "Datele din $1 au fost copiate pe server."
fi

if [ ! -f "$APP/data/config.json" ]; then
    echo
    echo "Alege parola cu care intri in aplicatie (de pe telefon si din afara casei)."
    su -s /bin/sh psgames -c "python3 $APP/server.py --set-password"
fi

# --- serviciu OpenRC (porneste la boot, reporneste daca se opreste) ----------
log "Configurez serviciul $SVC (port $PORT)"
cat > /etc/conf.d/$SVC <<EOF
# Portul aplicatiei PlayStation Games
PSG_PORT=$PORT
EOF

cat > /etc/init.d/$SVC <<'EOF'
#!/sbin/openrc-run
name="PlayStation Games"
description="PlayStation Games - server Python"

supervisor=supervise-daemon
respawn_delay=3
respawn_max=0

directory="/opt/ps-games"
command="/usr/bin/env"
command_args="PSG_PORT=${PSG_PORT:-8095} PYTHONUNBUFFERED=1 /usr/bin/python3 /opt/ps-games/server.py"
command_user="psgames:psgames"
output_log="/var/log/ps-games.log"
error_log="/var/log/ps-games.log"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -f -o psgames:psgames -m 0640 /var/log/ps-games.log
}
EOF
chmod 755 /etc/init.d/$SVC

# logul creste la fiecare cerere - il pastram mic
cat > /etc/periodic/weekly/ps-games-log <<EOF
#!/bin/sh
[ -f $LOG ] && tail -n 5000 $LOG > $LOG.tmp && cat $LOG.tmp > $LOG && rm -f $LOG.tmp
EOF
chmod 755 /etc/periodic/weekly/ps-games-log

rc-update add $SVC default >/dev/null
rc-service $SVC restart

# --- firewall: doar reteaua de acasa ------------------------------------------
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow from 192.168.0.0/16 to any port "$PORT" proto tcp comment 'PS Games (LAN)' >/dev/null
    log "Firewall: portul $PORT e deschis doar pentru reteaua de acasa."
fi

sleep 2
IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1)}')"
echo
if rc-service $SVC status >/dev/null 2>&1; then
    log "Gata. Din reteaua de acasa:  http://${IP:-<ip-mini-pc>}:$PORT"
else
    die "Serviciul nu a pornit - vezi: doas tail -n 50 $LOG"
fi
echo "  Stare:     doas rc-service $SVC status"
echo "  Restart:   doas rc-service $SVC restart"
echo "  Log:       doas tail -f $LOG"
echo "  Parola:    doas su -s /bin/sh psgames -c 'python3 $APP/server.py --set-password' && doas rc-service $SVC restart"
echo "  Date:      $APP/data  (backup zilnic automat in $APP/data/backup)"
