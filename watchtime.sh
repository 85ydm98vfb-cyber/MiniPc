#!/bin/sh
# Watch Time pe mini PC cu Alpine Linux: instalare, actualizare si (optional) acces de oriunde.
#
# Utilizare (logat prin SSH cu utilizatorul tau):
#   doas sh watchtime.sh ~/watchtime.zip              instalare / actualizare din arhiva
#   doas sh watchtime.sh ~/watchtime                  ... sau din folderul dezarhivat
#   doas env DOMAIN=watch-time sh watchtime.sh ~/watchtime.zip
#                                                     + adresa https://watch-time.duckdns.org
#
# Variabile (optionale):
#   TMDB_KEY    cheia TMDB (API Read Access Token) - doar la prima instalare; apoi din Setari
#   DOMAIN      adresa de oriunde; nume separate prin virgula:
#                 watch-time                  -> https://watch-time.duckdns.org
#                 watch-time,seriale.alex.ro   -> si domeniul tau (in DNS: CNAME seriale.alex.ro -> watch-time.duckdns.org)
#   DUCK_TOKEN  tokenul DuckDNS (doar prima data; apoi se ia din /etc/duckdns.conf)
#
# Datele (data/watchtime.db) si setarile (config.json) raman neatinse la actualizare.
# Nu folosi install.sh din arhiva: el ruleaza aplicatia din alt folder, cu o baza de date goala.
set -eu

APP=/opt/watchtime
SVC=watchtime
LOG=/var/log/watchtime.log
DOMAIN="${DOMAIN:-}"
PUBLIC_URL=
log() { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mEROARE:\033[0m %s\n' "$*" >&2; exit 1; }

lan_ip() {
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1)}'
}

# Gaseste folderul aplicatiei: argumentul (folder sau .zip) sau folderul curent.
# $1 = argumentul, $2 = fisierul care trebuie sa existe in folder (ex: server.py)
find_src() {
    arg="$1"; need="$2"
    if [ -z "$arg" ]; then
        for d in . "$(dirname "$0")"; do
            [ -f "$d/$need" ] && { SRC="$(cd "$d" && pwd)"; return; }
        done
        die "Nu gasesc aplicatia. Da arhiva .zip sau folderul ca argument (vezi capul scriptului)."
    fi
    [ -e "$arg" ] || die "Nu exista: $arg"
    if [ -d "$arg" ]; then
        SRC="$(cd "$arg" && pwd)"
    else
        case "$arg" in
            *.zip|*.ZIP) ;;
            *) die "Argumentul trebuie sa fie o arhiva .zip sau un folder: $arg" ;;
        esac
        TMP="$(mktemp -d)"
        trap 'rm -rf "$TMP"' EXIT
        unzip -q -o "$arg" -d "$TMP" || die "Nu pot dezarhiva $arg"
        f="$(find "$TMP" -name "$need" ! -path '*/__MACOSX/*' | head -n 1)"
        [ -n "$f" ] || die "Arhiva nu contine $need: $arg"
        SRC="$(dirname "$f")"
    fi
    [ -f "$SRC/$need" ] || die "Folderul nu contine $need: $SRC"
}

# --- Publicare pe internet: DuckDNS + Caddy (HTTPS) ----------------------------
# $1 = numele aplicatiei, separate prin virgula:
#        psgames                     -> https://psgames.duckdns.org
#        jocuri.alex.ro              -> domeniul tau (in DNS: CNAME catre un subdomeniu duckdns)
#        psgames,jocuri.alex.ro      -> ambele
# $2 = portul aplicatiei
# Toate aplicatiile publicate sunt tinute in /etc/duckdns.conf (SITES = nume:port ...).
# DuckDNS tine la zi IP-ul de acasa; domeniile proprii arata spre el prin CNAME.
host_of() { case "$1" in *.*) echo "$1" ;; *) echo "$1.duckdns.org" ;; esac; }

publish() {
    port="$2"; names=
    for n in $(echo "$1" | tr ',' ' '); do
        n="$(echo "$n" | tr 'A-Z' 'a-z')"
        n="${n#https://}"; n="${n#http://}"; n="${n%%/*}"; n="${n%.}"; n="${n%.duckdns.org}"
        case "$n" in
            ''|*[!a-z0-9.-]*|.*|*..*) die "Nume invalid in DOMAIN: '$n'" ;;
        esac
        names="$names $n"
    done
    names="${names# }"
    [ -n "$names" ] || die "DOMAIN e gol."
    PUBLIC_URL=
    for n in $names; do PUBLIC_URL="${PUBLIC_URL:+$PUBLIC_URL  }https://$(host_of "$n")"; done

    conf=/etc/duckdns.conf
    sites=; token=
    if [ -f "$conf" ]; then
        sites="$(sed -n "s/^SITES='\(.*\)'$/\1/p" "$conf")"
        token="$(sed -n "s/^DUCK_TOKEN='\{0,1\}\([^']*\)'\{0,1\}$/\1/p" "$conf")"
        if [ -z "$sites" ]; then          # format vechi, o singura aplicatie
            d="$(sed -n "s/^DUCK_DOMAIN='\{0,1\}\([^']*\)'\{0,1\}$/\1/p" "$conf")"
            [ -n "$d" ] && sites="$d:8095"
        fi
    fi
    token="${DUCK_TOKEN:-$token}"
    [ -n "$token" ] || die "Lipseste DUCK_TOKEN (il gasesti sus pe pagina duckdns.org dupa login)."
    case "$token" in
        *[!a-zA-Z0-9-]*) die "DUCK_TOKEN invalid." ;;
    esac

    # numele vechi ale aplicatiei (acelasi port) si aceleasi nume la alta aplicatie -> inlocuite
    new=
    for s in $sites; do
        [ "${s##*:}" = "$port" ] && continue
        skip=0
        for n in $names; do [ "${s%:*}" = "$n" ] && skip=1; done
        [ "$skip" = 1 ] || new="$new $s"
    done
    for n in $names; do new="$new $n:$port"; done
    sites="${new# }"

    domains=
    for s in $sites; do
        case "${s%:*}" in *.*) ;; *) domains="${domains:+$domains,}${s%:*}" ;; esac
    done
    [ -n "$domains" ] || die "E nevoie de cel putin un subdomeniu DuckDNS (el tine la zi IP-ul de acasa). Ex: DOMAIN=psgames,jocuri.alex.ro"

    log "DuckDNS: $domains"
    # verificam intai subdomeniile si tokenul; config-ul se salveaza doar daca DuckDNS raspunde OK
    r="$(wget -qO- "https://www.duckdns.org/update?domains=$domains&token=$token&ip=" 2>&1 || true)"
    [ "$r" = OK ] || die "DuckDNS a raspuns '$r' - verifica subdomeniul (creat pe duckdns.org?) si tokenul."
    umask 077
    cat > "$conf" <<EOF
SITES='$sites'
DUCK_DOMAINS='$domains'
DUCK_TOKEN='$token'
EOF
    umask 022
    cat > /etc/periodic/15min/duckdns <<'EOF'
#!/bin/sh
# Generat de scripturile MiniPc - actualizeaza IP-ul in DuckDNS
. /etc/duckdns.conf
R="$(wget -qO- "https://www.duckdns.org/update?domains=$DUCK_DOMAINS&token=$DUCK_TOKEN&ip=" 2>&1)"
echo "$(date '+%F %T') $R" > /var/log/duckdns.log
EOF
    chmod 755 /etc/periodic/15min/duckdns
    rc-update add crond default >/dev/null
    rc-service crond start >/dev/null 2>&1 || true
    /etc/periodic/15min/duckdns

    # domeniile proprii trebuie sa arate spre casa (CNAME catre duckdns), altfel nu primesc certificat
    target="${domains%%,*}"
    for n in $names; do case "$n" in *.*) ;; *) target="$n"; break ;; esac; done
    target="$target.duckdns.org"
    home_ip="$(nslookup "$target" 2>/dev/null | awk '/^Address/ && !/#53/ {print $NF}' | tail -n 1)"
    for n in $names; do
        case "$n" in *.*) ;; *) continue ;; esac
        ip="$(nslookup "$n" 2>/dev/null | awk '/^Address/ && !/#53/ {print $NF}' | tail -n 1)"
        if [ -z "$ip" ]; then
            warn "$n nu exista inca in DNS. Pune la firma de domeniu: CNAME $n -> $target"
        elif [ -n "$home_ip" ] && [ "$ip" != "$home_ip" ]; then
            warn "$n arata spre $ip, dar casa ta e $home_ip. Verifica CNAME-ul: $n -> $target"
        fi
    done

    log "Caddy: HTTPS pentru toate aplicatiile publicate"
    command -v caddy >/dev/null || apk add caddy
    mkdir -p /etc/caddy
    [ -f /etc/caddy/Caddyfile ] && [ ! -f /etc/caddy/Caddyfile.orig ] && \
        cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.orig
    {
        echo "# Generat de scripturile MiniPc - aplicatiile din /etc/duckdns.conf"
        for s in $sites; do
            cat <<EOF

$(host_of "${s%:*}") {
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

    if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow 80/tcp comment 'HTTP' >/dev/null
        ufw allow 443/tcp comment 'HTTPS' >/dev/null
    fi

    # nu testam adresele de pe mini PC: multe routere nu permit accesul la propriul IP public
    for n in $names; do
        h="$(host_of "$n")"
        log "Astept certificatul HTTPS pentru $h (pana la 90 de secunde)"
        i=0
        until find /var/lib/caddy /root/.local/share/caddy -name "$h.crt" 2>/dev/null | grep -q .; do
            i=$((i + 1))
            if [ "$i" -gt 18 ]; then
                warn "Certificatul pentru $h nu a fost obtinut inca (DNS / port forwarding 80+443?)."
                warn "Caddy reincearca singur. Stare: doas rc-service caddy status"
                break
            fi
            sleep 5
        done
    done
}

# --- Watchdog: reporneste aplicatia daca nu mai raspunde ----------------------
# (supervise-daemon reporneste doar un proces oprit, nu si unul blocat)
# $1 = serviciul, $2 = adresa locala care trebuie sa raspunda
install_watchdog() {
    mkdir -p /usr/local/sbin /etc/crontabs
    cat > /usr/local/sbin/app-watchdog <<'WD'
#!/bin/sh
# Generat de scripturile MiniPc: app-watchdog SERVICIU URL
# Daca aplicatia nu raspunde de doua ori la rand (la 30s distanta), o reporneste.
svc="$1"; url="$2"; log=/var/log/app-watchdog.log
rc-service "$svc" status >/dev/null 2>&1 || exit 0     # oprita intentionat -> nu ne atingem
wget -q -T 15 -O /dev/null "$url" 2>/dev/null && exit 0
sleep 30
wget -q -T 15 -O /dev/null "$url" 2>/dev/null && exit 0
echo "$(date '+%F %T') $svc nu raspunde - restart" >> "$log"
tail -n 30 "/var/log/$svc.log" 2>/dev/null | sed "s/^/    /" >> "$log"
rc-service "$svc" restart >/dev/null 2>&1
[ "$(wc -l < "$log")" -gt 2000 ] && tail -n 1000 "$log" > "$log.tmp" && mv "$log.tmp" "$log"
exit 0
WD
    chmod 755 /usr/local/sbin/app-watchdog
    touch /etc/crontabs/root
    sed -i "\|app-watchdog $1 |d" /etc/crontabs/root
    echo "*/5 * * * * /usr/local/sbin/app-watchdog $1 $2" >> /etc/crontabs/root
    rc-update add crond default >/dev/null
    rc-service crond restart >/dev/null 2>&1 || true
}

# =============================================================================
[ "$(id -u)" -eq 0 ] || die "Ruleaza cu doas:  doas sh watchtime.sh ~/watchtime.zip"
[ -f /etc/alpine-release ] || die "Scriptul este doar pentru Alpine Linux."

find_src "${1:-}" server.py
[ -f "$SRC/static/index.html" ] || die "Aplicatia nu pare Watch Time (lipseste static/index.html): $SRC"
log "Instalez Watch Time din $SRC"

command -v python3 >/dev/null || apk add python3

# --- oprește o instalare facuta cu install.sh din arhiva (alt folder / alt utilizator) --
if [ -f /etc/init.d/$SVC ] && ! grep -q '/opt/watchtime/server.py' /etc/init.d/$SVC; then
    warn "Am gasit un serviciu watchtime instalat altfel - il inlocuiesc cu cel din $APP."
    rc-service $SVC stop >/dev/null 2>&1 || true
fi

# --- utilizator de sistem, fara login -----------------------------------------
if ! id watchtime >/dev/null 2>&1; then
    addgroup -S watchtime
    adduser -S -D -H -h "$APP" -s /sbin/nologin -G watchtime watchtime
fi

# --- fisierele aplicatiei ------------------------------------------------------
mkdir -p "$APP/static" "$APP/data"
install -m 644 "$SRC/server.py" "$APP/server.py"
cp -R "$SRC/static/." "$APP/static/"
chmod -R a+rX "$APP/static"

# --- config.json: se creeaza o singura data, apoi il schimbi din aplicatie (Setari) ---
if [ ! -f "$APP/config.json" ]; then
    KEY="${TMDB_KEY:-}"
    if [ -z "$KEY" ] && [ -f "$SRC/config.json" ]; then
        KEY="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("tmdb_key",""))' "$SRC/config.json" 2>/dev/null || true)"
    fi
    [ "$KEY" = "PUNE_AICI_CHEIA_TMDB" ] && KEY=
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
PORT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("port", 8765))' "$APP/config.json")"

chown -R watchtime:watchtime "$APP/data" "$APP/config.json"
chmod 700 "$APP/data"
chmod 600 "$APP/config.json"

# --- serviciu OpenRC ------------------------------------------------------------
cat > /etc/init.d/$SVC <<'INIT'
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
INIT
chmod 755 /etc/init.d/$SVC

cat > /etc/periodic/weekly/watchtime-log <<CRON
#!/bin/sh
[ -f $LOG ] && tail -n 5000 $LOG > $LOG.tmp && cat $LOG.tmp > $LOG && rm -f $LOG.tmp
CRON
chmod 755 /etc/periodic/weekly/watchtime-log

rc-update add $SVC default >/dev/null
rc-service $SVC restart

if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow from 192.168.0.0/16 to any port "$PORT" proto tcp comment 'Watch Time (LAN)' >/dev/null
fi

sleep 2
rc-service $SVC status >/dev/null 2>&1 || die "Serviciul nu a pornit - vezi: doas tail -n 50 $LOG"

install_watchdog watchtime "http://127.0.0.1:$PORT/api/me"

[ -n "$DOMAIN" ] && publish "$DOMAIN" "$PORT"

IP="$(lan_ip)"
log "GATA! Watch Time ruleaza."
echo
echo "  Acasa (Wi-Fi):   http://${IP:-<ip-mini-pc>}:$PORT   <- contul admin merge doar de aici"
[ -n "$PUBLIC_URL" ] && echo "  De oriunde:      $PUBLIC_URL   (conturile normale)"
echo "  Stare:           doas rc-service $SVC status"
echo "  Restart:         doas rc-service $SVC restart"
echo "  Log:             doas tail -f $LOG"
echo "  Watchdog:        verifica la 5 minute; restarturi in /var/log/app-watchdog.log"
echo "  Date:            $APP/data/watchtime.db   Setari: $APP/config.json"
exit 0
