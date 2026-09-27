#!/bin/sh
# Acces la aplicatie de oriunde (date mobile, alta retea) prin Tailscale, cu HTTPS valid.
#   PUBLIC=1 (implicit): Tailscale Funnel - adresa https://minipc.xxx.ts.net merge din ORICE
#            browser, fara nimic instalat pe telefon (aplicatia e protejata de parola ei).
#   PUBLIC=0: doar dispozitivele tale care au aplicatia Tailscale pornita.
#
# Utilizare (logat prin SSH cu utilizatorul tau):
#   doas sh tailscale.sh
#
# Variabile (optionale):
#   TS_HOSTNAME  numele mini PC-ului in Tailscale (implicit minipc)
#   APP_PORT     portul aplicatiei publicate pe https (implicit 8095 = PlayStation Games)
#   PUBLIC       1 = oricine are adresa (Funnel), 0 = doar dispozitivele tale (implicit 1)
set -eu

TS_HOSTNAME="${TS_HOSTNAME:-minipc}"
APP_PORT="${APP_PORT:-8095}"
PUBLIC="${PUBLIC:-1}"

log() { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mEROARE:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Ruleaza cu doas: doas sh tailscale.sh"
[ -f /etc/alpine-release ] || die "Scriptul este doar pentru Alpine Linux."

log "Instalez Tailscale"
apk update
apk add tailscale

# Tailscale are nevoie de modulul tun
modprobe tun 2>/dev/null || true
grep -qx tun /etc/modules 2>/dev/null || echo tun >> /etc/modules

rc-update add tailscale default >/dev/null
rc-service tailscale restart
sleep 2

# --- Firewall ---------------------------------------------------------------
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    log "Firewall: permit tot traficul care vine prin Tailscale (doar dispozitivele tale)"
    ufw allow in on tailscale0 comment 'Tailscale' >/dev/null
    ufw allow 41641/udp comment 'Tailscale direct' >/dev/null
fi

# --- Conectare la contul tau ------------------------------------------------
if ! tailscale status >/dev/null 2>&1; then
    log "Conectare la contul Tailscale"
    echo "Deschide linkul care apare mai jos (pe laptop sau telefon) si logheaza-te"
    echo "cu Google / Microsoft / Apple / GitHub. Scriptul continua singur dupa login."
    echo
    tailscale up --hostname="$TS_HOSTNAME"
else
    log "Tailscale este deja conectat"
fi

# --- HTTPS pentru aplicatie -------------------------------------------------
echo "Daca apare un link pentru activarea HTTPS / Funnel, deschide-l, apasa Enable, apoi revino."
if [ "$PUBLIC" = 1 ]; then
    log "Public aplicatia (port $APP_PORT) pe internet, cu HTTPS (Tailscale Funnel)"
    tailscale serve reset >/dev/null 2>&1 || true
    tailscale funnel --bg "http://127.0.0.1:$APP_PORT"
else
    log "Public aplicatia (port $APP_PORT) pe HTTPS doar in reteaua ta Tailscale"
    tailscale funnel reset >/dev/null 2>&1 || true
    tailscale serve --bg --https=443 "http://127.0.0.1:$APP_PORT"
fi

# --- Rezumat ------------------------------------------------------------------
DNS="$(tailscale status --json 2>/dev/null | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null || true)"
TS_IP="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"

log "GATA!"
echo
echo "  Aplicatia de oriunde:  https://${DNS:-$TS_HOSTNAME.<reteaua-ta>.ts.net}"
echo "  SSH de oriunde:        ssh $(printf '%s' "${DOAS_USER:-alex}")@${TS_IP:-<ip-tailscale>}"
echo "  Remote Desktop:        ${TS_IP:-<ip-tailscale>}"
echo
if [ "$PUBLIC" = 1 ]; then
    warn "Adresa aplicatiei merge din orice browser, fara Tailscale pe telefon."
    warn "SSH si Remote Desktop de oriunde merg doar de pe dispozitive cu Tailscale instalat."
else
    warn "Pe telefon / laptop: instaleaza aplicatia Tailscale si logheaza-te cu ACELASI cont."
fi
exit 0
