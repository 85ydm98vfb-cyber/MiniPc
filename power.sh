#!/bin/sh
# Oprire si pornire automata a mini PC-ului (implicit: oprire la 23:00, pornire la 06:30).
#
# Pornirea foloseste ceasul placii (RTC): inainte de oprire se programeaza ora de pornire.
# Merge doar daca placa poate porni singura din starea "oprit" -> TESTEAZA INTAI!
#
# Utilizare (logat prin SSH cu utilizatorul tau):
#   doas sh power.sh --check        arata daca placa are ceas programabil si programul curent
#   doas sh power.sh --test         TEST: se opreste ACUM si porneste singur peste 5 minute
#   doas sh power.sh --enable       activeaza programul (oprire 23:00, pornire 06:30)
#   doas sh power.sh --disable      dezactiveaza programul (mini PC-ul ramane pornit mereu)
#   doas minipc-power --skip        in seara asta NU se opreste (doar pentru o noapte)
#
# Variabile (optionale): OFF=23:00  ON=06:30  TEST_MIN=5
#
# La --enable, treburile de noapte se muta inainte de oprire:
#   actualizari zilnice 02:00 -> 22:00, intretinere saptamanala sam. 03:00 -> sam. 22:10,
#   lunara 05:00 -> 22:20, backup pe stick luni 03:30 -> luni 22:30.
# La --disable ele revin la orele initiale (backup-ul ramane luni 22:30).
set -eu

OFF="${OFF:-23:00}"
ON="${ON:-06:30}"
TEST_MIN="${TEST_MIN:-5}"
MODE="${1:-}"
CRON=/etc/crontabs/root
SELF=/usr/local/sbin/minipc-power
BOOT=/etc/local.d/minipc-power.start
LOG=/var/log/minipc-power.log
RTC="${RTC:-/sys/class/rtc/rtc0}"

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mEROARE:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Ruleaza cu doas:  doas sh power.sh --check"
for t in "$OFF" "$ON"; do
    case "$t" in [0-2][0-9]:[0-5][0-9]) ;; *) die "Ora invalida: $t (format HH:MM)" ;; esac
done
case "$TEST_MIN" in ''|*[!0-9]*) die "TEST_MIN invalid: $TEST_MIN" ;; esac

# --- programul care ruleaza seara (instalat in /usr/local/sbin/minipc-power) -------
write_helper() {
    mkdir -p /usr/local/sbin /var/lib/minipc-power
    cat > "$SELF" <<'EOF'
#!/bin/sh
# Generat de power.sh. Programeaza pornirea in ceasul placii, apoi opreste mini PC-ul.
#   minipc-power --night     (din cron) oprire, cu pornire la ora ON
#   minipc-power --skip      in seara asta nu se opreste
#   minipc-power --in MIN    oprire acum, pornire peste MIN minute (test)
set -u
. /etc/minipc-power.conf
RTC="${RTC:-/sys/class/rtc/rtc0}"
LOG=/var/log/minipc-power.log
SKIP=/var/lib/minipc-power/skip
say() { echo "$(date '+%F %T') $*" >> "$LOG"; echo "$*"; }

case "${1:-}" in
    --skip)
        date +%F > "$SKIP"
        say "in seara asta ($(date +%F)) mini PC-ul NU se opreste"
        exit 0 ;;
    --night)
        if [ -f "$SKIP" ] && [ "$(cat "$SKIP")" = "$(date +%F)" ]; then
            rm -f "$SKIP"; say "oprire sarita (--skip)"; exit 0
        fi
        now=$(date +%s)
        t=$(date -d "$(date +%Y-%m-%d) $ON" +%s)
        [ "$t" -gt $((now + 600)) ] || t=$(date -d "$(date -d @$((now + 86400)) +%Y-%m-%d) $ON" +%s)
        secs=$((t - now)) ;;
    --in)
        secs=$(( ${2:-5} * 60 )) ;;
    *)
        echo "Utilizare: minipc-power --night | --skip | --in MINUTE"; exit 1 ;;
esac

# programeaza pornirea; daca nu reuseste, NU se opreste (altfel ar ramane oprit)
if ! { echo 0 > "$RTC/wakealarm" && echo "+$secs" > "$RTC/wakealarm"; } 2>/dev/null \
   || [ -z "$(cat "$RTC/wakealarm" 2>/dev/null)" ]; then
    say "EROARE: nu pot programa pornirea in ceasul placii - raman pornit"
    exit 1
fi
say "oprire acum; pornire programata peste $((secs / 60)) minute ($(date -d @$(( $(date +%s) + secs )) '+%F %H:%M'))"
sync
[ -n "${DRY_RUN:-}" ] && { say "(DRY_RUN: nu opresc)"; exit 0; }
poweroff
EOF
    chmod 755 "$SELF"
    printf 'ON=%s\nOFF=%s\n' "$ON" "$OFF" > /etc/minipc-power.conf
}

# la pornire: nota in log (asa vedem ca pornirea programata a mers) + IP-ul nou in DuckDNS imediat
write_boot() {
    mkdir -p /etc/local.d
    cat > "$BOOT" <<EOF
#!/bin/sh
# Generat de power.sh
echo "\$(date '+%F %T') a pornit" >> $LOG
[ -x /etc/periodic/15min/duckdns ] && /etc/periodic/15min/duckdns &
EOF
    chmod 755 "$BOOT"
    rc-update add local default >/dev/null 2>&1 || true
}

# muta / readuce ora unei linii din crontab: $1 = text care identifica linia, $2 = minut, $3 = ora
set_time() {
    grep -q "$1" "$CRON" || return 0
    awk -v pat="$1" -v m="$2" -v h="$3" 'index($0, pat) { $1 = m; $2 = h } { print }' "$CRON" > "$CRON.tmp"
    cat "$CRON.tmp" > "$CRON"; rm -f "$CRON.tmp"
}

show() {
    echo
    echo "  Ceas placa (RTC):   $([ -e "$RTC/wakealarm" ] && echo "da, se poate programa pornirea" || echo "NU are pornire programabila")"
    echo "  Ora acum:           $(date '+%F %H:%M')"
    if grep -q "$SELF --night" "$CRON" 2>/dev/null; then
        echo "  Program:            ACTIV - oprire $(awk -v s="$SELF --night" 'index($0,s){printf "%02d:%02d", $2, $1}' "$CRON"), pornire $(. /etc/minipc-power.conf; echo "$ON")"
    else
        echo "  Program:            inactiv (mini PC-ul ramane pornit)"
    fi
    echo "  Treburi de noapte:"
    awk '/periodic\/daily/ {n="actualizari + intretinere zilnica"} /periodic\/weekly/ {n="intretinere saptamanala (sambata)"}
         /periodic\/monthly/ {n="intretinere lunara (pe 1)"} /minipc-backup --cron/ {n="backup pe stick (luni)"}
         n != "" {printf "    %02d:%02d  %s\n", $2, $1, n; n=""}' "$CRON" 2>/dev/null
    [ -f "$LOG" ] && { echo "  Ultimele evenimente:"; tail -n 3 "$LOG" | sed 's/^/    /'; }
    echo
}

case "$MODE" in
    --check)
        show ;;

    --test)
        [ -e "$RTC/wakealarm" ] || die "Placa nu are ceas cu pornire programabila ($RTC/wakealarm lipseste)."
        write_helper
        write_boot
        warn "Mini PC-ul se opreste ACUM si ar trebui sa porneasca singur peste $TEST_MIN minute."
        warn "Daca dupa $((TEST_MIN + 3)) minute nu a pornit, apasa butonul de pornire: placa nu suporta"
        warn "pornirea programata (sau trebuie activata in BIOS: 'RTC Power On' / 'Wake on RTC')."
        printf "Continui? Scrie da: "
        read -r ans
        [ "$ans" = da ] || die "Anulat."
        "$SELF" --in "$TEST_MIN" ;;

    --enable)
        [ -e "$RTC/wakealarm" ] || die "Placa nu are ceas cu pornire programabila ($RTC/wakealarm lipseste)."
        grep -q "pornire programata" "$LOG" 2>/dev/null && grep -q "a pornit" "$LOG" 2>/dev/null || \
            warn "Nu vad un test reusit in $LOG. Recomandat: doas sh power.sh --test inainte."
        write_helper
        mkdir -p /etc/crontabs /etc/local.d
        touch "$CRON"
        sed -i "\|$SELF|d" "$CRON"
        echo "${OFF#*:} ${OFF%:*} * * * $SELF --night" >> "$CRON"
        # treburile de noapte, inainte de oprire
        set_time "run-parts /etc/periodic/daily"   0  22
        set_time "run-parts /etc/periodic/weekly"  10 22
        set_time "run-parts /etc/periodic/monthly" 20 22
        set_time "minipc-backup --cron"            30 22
        write_boot
        rc-update add crond default >/dev/null
        rc-service crond restart >/dev/null 2>&1 || true
        log "Program activat: oprire zilnic la $OFF, pornire la $ON."
        show ;;

    --disable)
        [ -f "$CRON" ] && sed -i "\|$SELF|d" "$CRON"
        set_time "run-parts /etc/periodic/daily"   0 2
        set_time "run-parts /etc/periodic/weekly"  0 3
        set_time "run-parts /etc/periodic/monthly" 0 5
        [ -e "$RTC/wakealarm" ] && echo 0 > "$RTC/wakealarm" 2>/dev/null || true
        rc-service crond restart >/dev/null 2>&1 || true
        log "Program dezactivat: mini PC-ul ramane pornit."
        show ;;

    *)
        sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
        exit 1 ;;
esac
exit 0
