#!/bin/sh
# Aplicatiile accesibile de oriunde, cu HTTPS valid: DuckDNS (adrese gratuite) + Caddy (certificate).
#
# Inainte:
#   1. Cont pe https://www.duckdns.org -> adaugi cate un subdomeniu pentru fiecare aplicatie
#      -> copiezi tokenul (acelasi token pentru toate subdomeniile).
#   2. In router: port forwarding 80 si 443 (TCP) catre IP-ul mini PC-ului.
#
# Utilizare (logat prin SSH cu utilizatorul tau):
#   doas env SITES="psgames:8095 watchtime-alex:8765" DUCK_TOKEN=xxxxxxxx-... sh public-web.sh
#   (o singura aplicatie: doas env DUCK_DOMAIN=psgames DUCK_TOKEN=... sh public-web.sh)
#
# Variabile:
#   SITES        lista "subdomeniu:port" separate prin spatiu
#   DUCK_DOMAIN  + APP_PORT (implicit 8095): varianta pentru o singura aplicatie
#   DUCK_TOKEN   tokenul din pagina DuckDNS (la a doua rulare se ia din /etc/duckdns.conf)
#   EMAIL        email pentru Let's Encrypt (optional, anunta daca expira certificatul)
set -eu

CONF=/etc/duckdns.conf
OLD_SITES=
OLD_TOKEN=
if [ -f "$CONF" ]; then
    OLD_SITES="$(sed -n "s/^SITES='\(.*\)'$/\1/p" "$CONF")"
    OLD_TOKEN="$(sed -n "s/^DUCK_TOKEN='\{0,1\}\([^']*\)'\{0,1\}$/\1/p" "$CONF")"
    # config vechi, cu o singura aplicatie
    if [ -z "$OLD_SITES" ]; then
        d="$(sed -n "s/^DUCK_DOMAIN='\{0,1\}\([^']*\)'\{0,1\}$/\1/p" "$CONF")"
        [ -n "$d" ] && OLD_SITES="$d:8095"
    fi
fi

DUCK_DOMAIN="${DUCK_DOMAIN:-}"
APP_PORT="${APP_PORT:-8095}"
if [ -n "$DUCK_DOMAIN" ]; then
    SITES="${SITES:-$DUCK_DOMAIN:$APP_PORT}"
fi
SITES="${SITES:-$OLD_SITES}"
DUCK_TOKEN="${DUCK_TOKEN:-$OLD_TOKEN}"
EMAIL="${EMAIL:-}"

log() { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mEROARE:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Ruleaza cu doas (vezi instructiunile din capul scriptului)."
[ -f /etc/alpine-release ] || die "Scriptul este doar pentru Alpine Linux."
[ -n "$SITES" ] || die "Lipseste SITES (ex: SITES=\"psgames:8095 watchtime-alex:8765\")."
[ -n "$DUCK_TOKEN" ] || die "Lipseste DUCK_TOKEN (il gasesti sus pe pagina duckdns.org dupa login)."
case "$DUCK_TOKEN" in
    *[!a-zA-Z0-9-]*) die "DUCK_TOKEN invalid." ;;
esac

# --- Validare lista de aplicatii ----------------------------------------------
CLEAN=
DOMAINS=
for s in $SITES; do
    s="${s#https://}"; s="${s#http://}"
    d="${s%%:*}"
    p="${s##*:}"
    [ "$d" != "$s" ] || die "Lipseste portul la '$s' (format: subdomeniu:port)."
    d="${d%.duckdns.org}"
    case "$d" in
        ''|*[!a-z0-9-]*) die "Subdomeniu invalid: '$d' (doar litere mici, cifre si '-')." ;;
    esac
    case "$p" in
        ''|*[!0-9]*) die "Port invalid pentru $d: '$p'" ;;
    esac
    CLEAN="$CLEAN $d:$p"
    DOMAINS="${DOMAINS:+$DOMAINS,}$d"
done
SITES="${CLEAN# }"

# --- DuckDNS: adresele arata mereu spre IP-ul de acasa -------------------------
log "Configurez DuckDNS pentru: $DOMAINS"
umask 077
cat > "$CONF" <<EOF
SITES='$SITES'
DUCK_DOMAINS='$DOMAINS'
DUCK_TOKEN='$DUCK_TOKEN'
EOF
umask 022

cat > /etc/periodic/15min/duckdns <<'EOF'
#!/bin/sh
# Generat de public-web.sh - actualizeaza IP-ul in DuckDNS
. /etc/duckdns.conf
R="$(wget -qO- "https://www.duckdns.org/update?domains=$DUCK_DOMAINS&token=$DUCK_TOKEN&ip=" 2>&1)"
echo "$(date '+%F %T') $R" > /var/log/duckdns.log
EOF
chmod 755 /etc/periodic/15min/duckdns
rc-update add crond default >/dev/null
rc-service crond start >/dev/null 2>&1 || true

/etc/periodic/15min/duckdns
grep -q ' OK$' /var/log/duckdns.log || \
    die "DuckDNS a raspuns: $(cat /var/log/duckdns.log) - verifica subdomeniile (create pe duckdns.org?) si tokenul."
log "DuckDNS OK"

# --- Verificare IP public ----------------------------------------------------
PUB_IP="$(wget -qO- https://ifconfig.me 2>/dev/null || true)"
case "$PUB_IP" in
    10.*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*)
        warn "IP-ul tau de internet ($PUB_IP) nu este public - varianta asta nu va merge." ;;
esac

# --- Caddy: HTTPS + proxy catre aplicatii --------------------------------------
log "Instalez / configurez Caddy"
apk add caddy

mkdir -p /etc/caddy
[ -f /etc/caddy/Caddyfile ] && [ ! -f /etc/caddy/Caddyfile.orig ] && \
    cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.orig

{
    if [ -n "$EMAIL" ]; then
        printf '{\n\temail %s\n}\n\n' "$EMAIL"
    fi
    echo "# Generat de public-web.sh"
    for s in $SITES; do
        cat <<EOF

${s%%:*}.duckdns.org {
	encode gzip
	reverse_proxy 127.0.0.1:${s##*:}
	header {
		Strict-Transport-Security "max-age=31536000"
		-Server
	}
}
EOF
    done
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

# --- Verificare certificate --------------------------------------------------
# (nu testam adresele de pe mini PC: multe routere nu permit accesul la propriul IP public)
log "Astept certificatele HTTPS de la Let's Encrypt (pana la 2 minute)"
MISSING=
i=0
while [ "$i" -lt 24 ]; do
    MISSING=
    for s in $SITES; do
        f="${s%%:*}.duckdns.org"
        find /var/lib/caddy /root/.local/share/caddy -name "$f.crt" 2>/dev/null | grep -q . || \
            MISSING="$MISSING $f"
    done
    [ -z "$MISSING" ] && break
    i=$((i + 1))
    sleep 5
done

LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1)}')"
echo
if [ -z "$MISSING" ]; then
    log "GATA!"
else
    warn "Certificat HTTPS inca neobtinut pentru:$MISSING"
    warn "Verifica port forwarding-ul 80 si 443 (TCP) in router catre acest mini PC."
    warn "Caddy reincearca singur. Stare: doas rc-service caddy status"
fi
echo
for s in $SITES; do
    echo "  https://${s%%:*}.duckdns.org   (acasa: http://${LAN_IP:-<ip-mini-pc>}:${s##*:})"
done
echo
echo "  Testeaza de pe telefon, pe DATE MOBILE (din Wi-Fi-ul de acasa unele routere nu le deschid)."
echo "  IP-ul in DuckDNS se actualizeaza automat la 15 minute (log: /var/log/duckdns.log)."
exit 0
