#!/bin/sh
# Instalare Watch Time pe mini PC cu Alpine Linux (OpenRC).
# Se ruleaza din folderul aplicatiei (cel cu server.py si static/):
#   doas sh install-alpine.sh              instalare / actualizare (datele si setarile raman)
#   doas env TMDB_KEY=eyJ... sh install-alpine.sh   cu cheia TMDB data direct
set -eu

APP=/opt/watchtime
SVC=watchtime
LOG=/var/log/watchtime.log
cd "$(dirname "$0")"

die() { printf '\033[1;31mEROARE:\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "Ruleaza cu doas:  doas sh install-alpine.sh"
[ -f server.py ] && [ -f static/index.html ] || \
    die "Ruleaza scriptul din folderul aplicatiei (cel cu server.py si static/)."

command -v python3 >/dev/null || apk add python3

# --- utilizator de sistem, fara login -----------------------------------------
if ! id watchtime >/dev/null 2>&1; then
    log "Creez utilizatorul de sistem watchtime"
    addgroup -S watchtime
    adduser -S -D -H -h "$APP" -s /sbin/nologin -G watchtime watchtime
fi

# --- fisierele aplicatiei ------------------------------------------------------
log "Copiez aplicatia in $APP"
mkdir -p "$APP/static" "$APP/data"
install -m 644 server.py "$APP/server.py"
cp -R static/. "$APP/static/"
chmod -R a+rX "$APP/static"

# --- config.json (se pastreaza la actualizare; aplicatia il modifica din Setari) --
if [ ! -f "$APP/config.json" ]; then
    KEY="${TMDB_KEY:-}"
    if [ -z "$KEY" ] && [ -f config.json ]; then
        KEY="$(python3 -c 'import json; print(json.load(open("config.json")).get("tmdb_key",""))' 2>/dev/null || true)"
        [ "$KEY" = "PUNE_AICI_CHEIA_TMDB" ] && KEY=
    fi
    if [ -z "$KEY" ]; then
        echo
        printf "Cheia TMDB (API Read Access Token) - sau Enter ca s-o pui mai tarziu din Setari: "
        read -r KEY || KEY=
    fi
    TMDB_KEY_IN="$KEY" python3 - "$APP/config.json" <<'PY'
import json, os, sys
cfg = {"tmdb_key": os.environ.get("TMDB_KEY_IN", "").strip(),
       "language": "en-US", "port": 8765, "host": "0.0.0.0"}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
PY
fi
PORT="$(python3 -c 'import json; print(json.load(open("'"$APP"'/config.json")).get("port", 8765))')"

chown -R watchtime:watchtime "$APP/data" "$APP/config.json"
chmod 700 "$APP/data"
chmod 600 "$APP/config.json"

# --- serviciu OpenRC (porneste la boot, reporneste daca se opreste) ----------
log "Configurez serviciul $SVC (port $PORT)"
cat > /etc/init.d/$SVC <<'EOF'
#!/sbin/openrc-run
name="Watch Time"
description="Watch Time - tracker seriale si filme"

supervisor=supervise-daemon
respawn_delay=3
respawn_max=0

directory="/opt/watchtime"
command="/usr/bin/env"
command_args="PYTHONUNBUFFERED=1 /usr/bin/python3 /opt/watchtime/server.py"
command_user="watchtime:watchtime"
output_log="/var/log/watchtime.log"
error_log="/var/log/watchtime.log"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -f -o watchtime:watchtime -m 0640 /var/log/watchtime.log
}
EOF
chmod 755 /etc/init.d/$SVC

cat > /etc/periodic/weekly/watchtime-log <<EOF
#!/bin/sh
[ -f $LOG ] && tail -n 5000 $LOG > $LOG.tmp && cat $LOG.tmp > $LOG && rm -f $LOG.tmp
EOF
chmod 755 /etc/periodic/weekly/watchtime-log

rc-update add $SVC default >/dev/null
rc-service $SVC restart

# --- firewall: doar reteaua de acasa ------------------------------------------
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow from 192.168.0.0/16 to any port "$PORT" proto tcp comment 'Watch Time (LAN)' >/dev/null
    log "Firewall: portul $PORT e deschis doar pentru reteaua de acasa."
fi

sleep 2
IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1)}')"
echo
if rc-service $SVC status >/dev/null 2>&1; then
    log "Gata. Din Wi-Fi-ul de acasa:  http://${IP:-<ip-mini-pc>}:$PORT"
    echo "  Prima data iti creezi contul de admin (merge doar din Wi-Fi-ul de acasa)."
else
    die "Serviciul nu a pornit - vezi: doas tail -n 50 $LOG"
fi
echo "  Stare:     doas rc-service $SVC status"
echo "  Restart:   doas rc-service $SVC restart"
echo "  Log:       doas tail -f $LOG"
echo "  Date:      $APP/data/watchtime.db   Setari: $APP/config.json"
