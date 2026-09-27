#!/bin/sh
# Aplicatia accesibila de oriunde, cu HTTPS valid: DuckDNS (adresa gratuita) + Caddy (certificat).
#
# Inainte:
#   1. Cont pe https://www.duckdns.org -> adaugi un subdomeniu (ex: jocurile-mele) -> copiezi tokenul.
#   2. In router: port forwarding 80 si 443 (TCP) catre IP-ul mini PC-ului.
#
# Utilizare (logat prin SSH cu utilizatorul tau):
#   doas env DUCK_DOMAIN=jocurile-mele DUCK_TOKEN=xxxxxxxx-xxxx-... sh public-web.sh
#
# Variabile:
#   DUCK_DOMAIN  subdomeniul DuckDNS (fara .duckdns.org)          - obligatoriu
#   DUCK_TOKEN   tokenul din pagina DuckDNS                        - obligatoriu
#   APP_PORT     portul aplicatiei (implicit 8095 = PlayStation Games)
#   EMAIL        email pentru Let's Encrypt (optional, anunta daca expira certificatul)
set -eu

DUCK_DOMAIN="${DUCK_DOMAIN:-}"
DUCK_TOKEN="${DUCK_TOKEN:-}"
APP_PORT="${APP_PORT:-8095}"
EMAIL="${EMAIL:-}"

log() { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mEROARE:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Ruleaza cu doas (vezi instructiunile din capul scriptului)."
[ -f /etc/alpine-release ] || die "Scriptul este doar pentru Alpine Linux."

DUCK_DOMAIN="${DUCK_DOMAIN%.duckdns.org}"
DUCK_DOMAIN="${DUCK_DOMAIN#https://}"
DUCK_DOMAIN="${DUCK_DOMAIN#http://}"
[ -n "$DUCK_DOMAIN" ] || die "Lipseste DUCK_DOMAIN (ex: DUCK_DOMAIN=jocurile-mele)."
[ -n "$DUCK_TOKEN" ] || die "Lipseste DUCK_TOKEN (il gasesti sus pe pagina duckdns.org dupa login)."
case "$DUCK_DOMAIN" in
    *[!a-z0-9-]*) die "DUCK_DOMAIN poate contine doar litere mici, cifre si '-': $DUCK_DOMAIN" ;;
esac
case "$APP_PORT" in
    ''|*[!0-9]*) die "APP_PORT invalid: $APP_PORT" ;;
esac
FQDN="$DUCK_DOMAIN.duckdns.org"

# --- DuckDNS: adresa arata mereu spre IP-ul de acasa ---------------------------
log "Configurez DuckDNS pentru $FQDN"
umask 077
cat > /etc/duckdns.conf <<EOF
DUCK_DOMAIN=$DUCK_DOMAIN
DUCK_TOKEN=$DUCK_TOKEN
EOF
umask 022

cat > /etc/periodic/15min/duckdns <<'EOF'
#!/bin/sh
# Generat de public-web.sh - actualizeaza IP-ul in DuckDNS
. /etc/duckdns.conf
R="$(wget -qO- "https://www.duckdns.org/update?domains=$DUCK_DOMAIN&token=$DUCK_TOKEN&ip=" 2>&1)"
echo "$(date '+%F %T') $R" > /var/log/duckdns.log
EOF
chmod 755 /etc/periodic/15min/duckdns
rc-update add crond default >/dev/null
rc-service crond start >/dev/null 2>&1 || true

/etc/periodic/15min/duckdns
grep -q ' OK$' /var/log/duckdns.log || \
    die "DuckDNS a raspuns: $(cat /var/log/duckdns.log) - verifica subdomeniul si tokenul."
log "DuckDNS OK"

# --- Verificare IP public ----------------------------------------------------
PUB_IP="$(wget -qO- https://ifconfig.me 2>/dev/null || true)"
case "$PUB_IP" in
    10.*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*)
        warn "IP-ul tau de internet ($PUB_IP) nu este public - varianta asta nu va merge." ;;
esac

# --- Caddy: HTTPS + proxy catre aplicatie --------------------------------------
log "Instalez Caddy"
apk add caddy

mkdir -p /etc/caddy
[ -f /etc/caddy/Caddyfile ] && [ ! -f /etc/caddy/Caddyfile.orig ] && \
    cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.orig

{
    if [ -n "$EMAIL" ]; then
        printf '{\n\temail %s\n}\n\n' "$EMAIL"
    fi
    cat <<EOF
# Generat de public-web.sh
$FQDN {
	encode gzip
	reverse_proxy 127.0.0.1:$APP_PORT
	header {
		Strict-Transport-Security "max-age=31536000"
		-Server
	}
}
EOF
} > /etc/caddy/Caddyfile

caddy fmt --overwrite /etc/caddy/Caddyfile >/dev/null 2>&1 || true
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null || \
    die "Caddyfile invalid - vezi /etc/caddy/Caddyfile"

rc-update add caddy default >/dev/null
rc-service caddy restart

# --- Firewall ---------------------------------------------------------------
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow 80/tcp comment 'HTTP' >/dev/null
    ufw allow 443/tcp comment 'HTTPS' >/dev/null
fi

# --- Verificare certificat ---------------------------------------------------
# (nu testam https://$FQDN de pe mini PC: multe routere nu permit accesul la propriul IP public)
log "Astept certificatul HTTPS de la Let's Encrypt (pana la 90 de secunde)"
OK=0
i=0
while [ "$i" -lt 18 ]; do
    if find /var/lib/caddy /root/.local/share/caddy -name "$FQDN.crt" 2>/dev/null | grep -q .; then
        OK=1; break
    fi
    i=$((i + 1))
    sleep 5
done

echo
if [ "$OK" = 1 ]; then
    log "GATA!  Aplicatia de oriunde:  https://$FQDN"
    echo "  Testeaza de pe telefon, pe DATE MOBILE (din Wi-Fi-ul de acasa unele routere nu o deschid)."
else
    warn "Certificatul HTTPS nu a fost obtinut inca."
    warn "Verifica port forwarding-ul 80 si 443 (TCP) in router catre acest mini PC."
    warn "Caddy reincearca singur. Stare: doas rc-service caddy status"
    warn "Log: doas ls /var/log/caddy/ ; doas tail -n 50 /var/log/caddy/*.log"
fi
echo
echo "  Din casa merge in continuare si:  http://$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1)}'):$APP_PORT"
echo "  IP-ul in DuckDNS se actualizeaza automat la 15 minute (log: /var/log/duckdns.log)."
exit 0
