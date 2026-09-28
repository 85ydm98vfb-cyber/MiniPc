#!/bin/sh
# PlayStation Games pe mini PC cu Alpine Linux: instalare, actualizare si (optional) acces de oriunde.
#
# Utilizare (logat prin SSH cu utilizatorul tau):
#   doas sh PSgames.sh ~/ps-games-server.zip          instalare / actualizare din arhiva
#   doas sh PSgames.sh ~/ps-games-server              ... sau din folderul dezarhivat
#   doas env DOMAIN=psgames sh PSgames.sh ~/ps-games-server.zip
#                                                     + adresa https://psgames.duckdns.org
#
# Variabile (optionale):
#   DATA        fisierul PlayStation_Games.json de incarcat (inlocuieste datele de pe server)
#   PORT        portul aplicatiei (implicit 8095)
#   DOMAIN      adresa de oriunde; nume separate prin virgula:
#                 psgames                  -> https://psgames.duckdns.org
#                 psgames,jocuri.alex.ro   -> si domeniul tau (in DNS: CNAME jocuri.alex.ro -> psgames.duckdns.org)
#   DUCK_TOKEN  tokenul DuckDNS (doar prima data; apoi se ia din /etc/duckdns.conf)
#
# Datele si parola raman neatinse la actualizare. Backup zilnic automat in /opt/ps-games/data/backup.
set -eu

APP=/opt/ps-games
SVC=ps-games
LOG=/var/log/ps-games.log
PORT="${PORT:-8095}"
DATA="${DATA:-}"
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
[ "$(id -u)" -eq 0 ] || die "Ruleaza cu doas:  doas sh PSgames.sh ~/ps-games-server.zip"
[ -f /etc/alpine-release ] || die "Scriptul este doar pentru Alpine Linux."
case "$PORT" in ''|*[!0-9]*) die "PORT invalid: $PORT" ;; esac
[ -z "$DATA" ] || [ -f "$DATA" ] || die "Nu gasesc fisierul de date: $DATA"

find_src "${1:-}" server.py
[ -f "$SRC/public/index.html" ] && [ -f "$SRC/public/login.html" ] || \
    die "Aplicatia nu pare PlayStation Games (lipseste public/index.html): $SRC"
log "Instalez PlayStation Games din $SRC"

command -v python3 >/dev/null || apk add python3

# --- utilizator de sistem, fara login -----------------------------------------
if ! id psgames >/dev/null 2>&1; then
    addgroup -S psgames
    adduser -S -D -H -h "$APP" -s /sbin/nologin -G psgames psgames
fi

# --- fisierele aplicatiei ------------------------------------------------------
mkdir -p "$APP/public" "$APP/data"
install -m 644 "$SRC/server.py" "$APP/server.py"
install -m 644 "$SRC/public/index.html" "$SRC/public/login.html" "$APP/public/"
chown -R psgames:psgames "$APP/data"
chmod 700 "$APP/data"

if [ -n "$DATA" ]; then
    install -o psgames -g psgames -m 600 "$DATA" "$APP/data/PlayStation_Games.json"
    log "Datele din $DATA au fost copiate pe server."
fi

if [ ! -f "$APP/data/config.json" ]; then
    echo
    echo "Alege parola cu care intri in aplicatie (minim 8 caractere; recomandat 12+)."
    su -s /bin/sh psgames -c "python3 $APP/server.py --set-password"
fi

# --- serviciu OpenRC ------------------------------------------------------------
cat > /etc/conf.d/$SVC <<CONF
# Portul aplicatiei PlayStation Games
PSG_PORT=$PORT
CONF

cat > /etc/init.d/$SVC <<'INIT'
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
INIT
chmod 755 /etc/init.d/$SVC

cat > /etc/periodic/weekly/ps-games-log <<CRON
#!/bin/sh
[ -f $LOG ] && tail -n 5000 $LOG > $LOG.tmp && cat $LOG.tmp > $LOG && rm -f $LOG.tmp
CRON
chmod 755 /etc/periodic/weekly/ps-games-log

rc-update add $SVC default >/dev/null
rc-service $SVC restart

if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow from 192.168.0.0/16 to any port "$PORT" proto tcp comment 'PS Games (LAN)' >/dev/null
fi

sleep 2
rc-service $SVC status >/dev/null 2>&1 || die "Serviciul nu a pornit - vezi: doas tail -n 50 $LOG"

install_watchdog ps-games "http://127.0.0.1:$PORT/login"

[ -n "$DOMAIN" ] && publish "$DOMAIN" "$PORT"

IP="$(lan_ip)"
log "GATA! PlayStation Games ruleaza."
echo
echo "  Acasa (Wi-Fi):   http://${IP:-<ip-mini-pc>}:$PORT"
[ -n "$PUBLIC_URL" ] && echo "  De oriunde:      $PUBLIC_URL"
echo "  Stare:           doas rc-service $SVC status"
echo "  Restart:         doas rc-service $SVC restart"
echo "  Log:             doas tail -f $LOG"
echo "  Watchdog:        verifica la 5 minute; restarturi in /var/log/app-watchdog.log"
echo "  Schimba parola:  doas su -s /bin/sh psgames -c 'python3 $APP/server.py --set-password' && doas rc-service $SVC restart"
echo "  Date:            $APP/data  (backup zilnic in $APP/data/backup)"
exit 0
