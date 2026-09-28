#!/bin/sh
# Instalare Watch Time ca serviciu care porneste singur la boot.
# Merge pe Alpine Linux (OpenRC, doas) si pe Ubuntu/Debian (systemd, sudo).
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
USR="$(id -un)"
if command -v doas >/dev/null 2>&1; then ROOT=doas; else ROOT=sudo; fi
[ "$(id -u)" -eq 0 ] && ROOT=""

# Python 3
if ! command -v python3 >/dev/null 2>&1; then
  if [ -f /etc/alpine-release ]; then $ROOT apk add python3; else $ROOT apt update && $ROOT apt install -y python3; fi
fi
PY="$(command -v python3)"

# pachet pentru notificari (optional: fara el aplicatia merge, doar fara notificari)
if ! "$PY" -c "import cryptography" >/dev/null 2>&1; then
  if [ -f /etc/alpine-release ]; then $ROOT apk add py3-cryptography || true
  else $ROOT apt install -y python3-cryptography || true; fi
fi

# config.json (cheia TMDB se poate pune si mai tarziu, din aplicatie: admin -> Setari)
if [ ! -f "$DIR/config.json" ]; then
  printf "Cheia TMDB (Enter ca s-o pui mai tarziu din Setari, ca admin): "
  read -r KEY
  cat > "$DIR/config.json" <<CFG
{
  "tmdb_key": "$KEY",
  "language": "en-US",
  "port": 8765,
  "host": "0.0.0.0"
}
CFG
fi
mkdir -p "$DIR/data"

if [ -f /etc/alpine-release ]; then
  # ---- Alpine / OpenRC ----
  $ROOT touch /var/log/watchtime.log
  $ROOT chown "$USR" /var/log/watchtime.log
  $ROOT tee /etc/init.d/watchtime >/dev/null <<SVC
#!/sbin/openrc-run
name="watchtime"
description="Watch Time - tracker seriale si filme"
supervisor="supervise-daemon"
command="$PY"
command_args="$DIR/server.py"
command_user="$USR"
directory="$DIR"
respawn_delay=5
output_log="/var/log/watchtime.log"
error_log="/var/log/watchtime.log"

depend() {
    need net
}
SVC
  $ROOT chmod 755 /etc/init.d/watchtime
  $ROOT rc-update add watchtime default >/dev/null
  $ROOT rc-service watchtime restart
  RESTART="doas rc-service watchtime restart"
else
  # ---- Ubuntu / Debian / systemd ----
  if systemctl list-unit-files | grep -q '^episod.service'; then $ROOT systemctl disable --now episod || true; fi
  $ROOT tee /etc/systemd/system/watchtime.service >/dev/null <<SVC
[Unit]
Description=Watch Time - tracker seriale si filme
After=network-online.target
Wants=network-online.target

[Service]
User=$USR
WorkingDirectory=$DIR
ExecStart=$PY $DIR/server.py
Restart=on-failure

[Install]
WantedBy=multi-user.target
SVC
  $ROOT systemctl daemon-reload
  $ROOT systemctl enable --now watchtime
  $ROOT systemctl restart watchtime
  RESTART="sudo systemctl restart watchtime"
fi

sleep 2
LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1)}')"
if wget -qO- http://127.0.0.1:8765/api/me >/dev/null 2>&1 || curl -fs http://127.0.0.1:8765/api/me >/dev/null 2>&1; then
  echo
  echo "Gata! Watch Time ruleaza."
  echo "  Acasa (Wi-Fi):  http://${LAN_IP:-<ip-mini-pc>}:8765   <- de aici creezi contul admin"
  echo "  Repornire:      $RESTART"
else
  echo "Serviciul nu raspunde inca. Vezi: /var/log/watchtime.log sau journalctl -u watchtime"
fi
