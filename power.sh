#!/bin/sh
# Oprire seara si pornire dimineata a mini PC-ului + fereastra "Program mini PC" pe desktop.
#
# Pornirea foloseste ceasul placii (RTC): inainte de oprire se programeaza ora de pornire.
# Merge doar daca placa poate porni singura din starea "oprit" -> TESTEAZA INTAI!
#
# Utilizare (logat prin SSH cu utilizatorul tau):
#   doas sh power.sh --check        ceasul placii + programul curent
#   doas sh power.sh --test         TEST: se opreste ACUM si porneste singur peste 5 minute
#   doas sh power.sh --enable       activeaza programul + instaleaza fereastra de pe desktop
#   doas sh power.sh --disable      mini PC-ul ramane pornit mereu
#   doas minipc-power --skip        in seara asta NU se opreste
#
# Variabile (optionale, doar la --enable): OFF=23:00  ON=06:30  BACKUP_DAY=1 (0=duminica ... 6=sambata; ex. 1,4)
# Dupa instalare, orele se schimba cel mai usor din fereastra "Program mini PC" (Remote Desktop).
#
# Actualizarile ruleaza cu o ora inainte de oprire. Backup-ul pe stick si intretinerea (saptamanala,
# lunara) au orele lor, alese in fereastra (tab-ul "Backup si intretinere").
set -eu

TEST_MIN="${TEST_MIN:-5}"
MODE="${1:-}"
ENV_OFF="${OFF:-}"; ENV_ON="${ON:-}"; ENV_DAY="${BACKUP_DAY:-}"   # din linia de comanda (optional)
SELF=/usr/local/sbin/minipc-power
GUI=/usr/local/bin/minipc-program
BOOT=/etc/local.d/minipc-power.start
CONF=/etc/minipc-power.conf
LOG=/var/log/minipc-power.log
RTC="${RTC:-/sys/class/rtc/rtc0}"

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mEROARE:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Ruleaza cu doas:  doas sh power.sh --check"
case "$TEST_MIN" in ''|*[!0-9]*) die "TEST_MIN invalid: $TEST_MIN" ;; esac

# ============================================================================
# minipc-power: tot ce tine de program (folosit de acest script, de cron si de fereastra)
# ============================================================================
write_helper() {
    mkdir -p /usr/local/sbin /var/lib/minipc-power
    cat > "$SELF" <<'EOF'
#!/bin/sh
# Generat de power.sh - programul de oprire/pornire al mini PC-ului.
#   minipc-power --status                 starea (cheie=valoare), pentru fereastra
#   minipc-power --set OFF ON ACTIV       oprire / pornire (ex: --set 23:00 06:30 1)
#   minipc-power --backup ZILE ORA ACTIV  backup pe stick (ex: --backup 1,4 22:30 1; 0=duminica ... 6=sambata)
#   minipc-power --maint ZI ORA ZI_LUNA ORA   intretinere saptamanala + lunara (ex: --maint 6 22:10 1 22:20)
#   minipc-power --apply                  reaplica orele din config in cron
#   minipc-power --skip | --unskip        in seara asta nu se opreste / anuleaza
#   minipc-power --stick-info             ultimul backup + starea stick-ului
#   minipc-power --backup-now | --stick-list | --stick-open | --stick-close
#   minipc-power --night                  (din cron) programeaza pornirea si opreste
#   minipc-power --in MINUTE              oprire acum, pornire peste MINUTE (test)
set -u
CONF=/etc/minipc-power.conf
CRON=/etc/crontabs/root
RTC="${RTC:-/sys/class/rtc/rtc0}"
LOG=/var/log/minipc-power.log
SKIP=/var/lib/minipc-power/skip
SELF=/usr/local/sbin/minipc-power
BK=/usr/local/sbin/minipc-backup
BKLOG=/var/log/minipc-backup.log
BKSTATE=/var/lib/minipc-backup
MNT=/mnt/minipc-backup
BKOFF="#minipc-power-off# "
OFF=23:00; ON=06:30; BACKUP_DAY=1; ENABLED=0
[ -f "$CONF" ] && . "$CONF"

say() { echo "$(date '+%F %T') $*" >> "$LOG"; echo "$*"; }
fail() { echo "EROARE: $*" >&2; exit 1; }
valid_time() { case "$1" in [01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) return 0 ;; esac; return 1; }
tomin() { h=${1%:*}; m=${1#*:}; h=${h#0}; m=${m#0}; echo $(( h * 60 + m )); }
fmt() { printf '%02d:%02d' $(( $1 / 60 )) $(( $1 % 60 )); }
before() { echo $(( ($(tomin "$OFF") - $1 + 1440) % 1440 )); }   # minute ale zilei, cu $1 min inainte de oprire
dayname() { d=$1; set -- duminica luni marti miercuri joi vineri sambata; shift "$d"; echo "$1"; }
daynames() { out=; for d in $(echo "$1" | tr ',' ' '); do out="${out:+$out, }$(dayname "$d")"; done; echo "$out"; }
# zile: 0-6 separate prin virgula -> sortate, fara dubluri (gol daca e invalid)
valid_days() {
    echo "$1" | grep -Eq '^[0-6](,[0-6])*$' || return 1
    echo "$1" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//'
}
backup_auto() { grep -q "^[0-9].*minipc-backup --cron" "$CRON" 2>/dev/null; }
valid_mday() { case "$1" in [1-9]|1[0-9]|2[0-8]) return 0 ;; esac; return 1; }
keep() { k=$(sed -n 's/.*KEEP=\([0-9]*\).*minipc-backup --cron.*/\1/p' "$CRON" 2>/dev/null | head -n 1); echo "${k:-30}"; }

# muta ora unei linii din crontab: $1 text, $2 minute-ale-zilei, $3 ziua saptamanii, $4 ziua lunii (optionale)
set_time() {
    grep -q "$1" "$CRON" 2>/dev/null || return 0
    awk -v pat="$1" -v m=$(( $2 % 60 )) -v h=$(( $2 / 60 )) -v d="${3:-}" -v md="${4:-}" \
        'index($0, pat) { $1 = m; $2 = h; if (d != "") $5 = d; if (md != "") $3 = md } { print }' "$CRON" > "$CRON.tmp"
    cat "$CRON.tmp" > "$CRON"; rm -f "$CRON.tmp"
}

# orele backup-ului si ale intretinerii: din config; la prima rulare = cele de pana acum (relative la oprire)
[ -n "${BACKUP_TIME:-}" ]  || BACKUP_TIME=$(fmt $(before 30))
[ -n "${WEEKLY_DAY:-}" ]   || WEEKLY_DAY=6
[ -n "${WEEKLY_TIME:-}" ]  || WEEKLY_TIME=$(fmt $(before 50))
[ -n "${MONTHLY_DAY:-}" ]  || MONTHLY_DAY=1
[ -n "${MONTHLY_TIME:-}" ] || MONTHLY_TIME=$(fmt $(before 40))

write_conf() {
    { printf 'OFF=%s\nON=%s\nENABLED=%s\n' "$OFF" "$ON" "$ENABLED"
      printf 'BACKUP_DAY=%s\nBACKUP_TIME=%s\n' "$BACKUP_DAY" "$BACKUP_TIME"
      printf 'WEEKLY_DAY=%s\nWEEKLY_TIME=%s\n' "$WEEKLY_DAY" "$WEEKLY_TIME"
      printf 'MONTHLY_DAY=%s\nMONTHLY_TIME=%s\n' "$MONTHLY_DAY" "$MONTHLY_TIME"; } > "$CONF.tmp"
    mv "$CONF.tmp" "$CONF"; chmod 644 "$CONF"
}

# pune orele din config in cron; $1 = backup automat pe stick: 1 pornit, 0 oprit, gol = ramane cum e
apply_cron() {
    mkdir -p /etc/crontabs; touch "$CRON"
    sed -i "\|$SELF --night|d" "$CRON"
    if [ "$ENABLED" = 1 ]; then
        o=$(tomin "$OFF")
        echo "$(( o % 60 )) $(( o / 60 )) * * * $SELF --night" >> "$CRON"
        set_time "run-parts /etc/periodic/daily" "$(before 60)"     # actualizarile: inainte de oprire
    else
        set_time "run-parts /etc/periodic/daily" 120
    fi
    set_time "run-parts /etc/periodic/weekly"  "$(tomin "$WEEKLY_TIME")"  "$WEEKLY_DAY"
    set_time "run-parts /etc/periodic/monthly" "$(tomin "$MONTHLY_TIME")" "*" "$MONTHLY_DAY"
    # backup-ul oprit din fereastra = linia din cron comentata (pastreaza KEEP / DETACH)
    bk=${1:-}
    [ -n "$bk" ] || { backup_auto && bk=1 || bk=0; }
    sed -i "s|^$BKOFF||" "$CRON"
    set_time "minipc-backup --cron" "$(tomin "$BACKUP_TIME")" "$BACKUP_DAY"
    [ "$bk" = 1 ] || sed -i "/minipc-backup --cron/s|^|$BKOFF|" "$CRON"
    rc-service crond restart >/dev/null 2>&1 || true
}

strip() { tr -d '\033' | sed 's/\[[0-9;]*m//g'; }     # fara culorile din terminal
usb_disk() { for b in /sys/block/sd*; do [ -e "$b" ] && readlink -f "$b" | grep -q '/usb' && return 0; done; return 1; }
opened() { grep -q " $MNT " /proc/mounts; }
need_bk() { [ -x "$BK" ] || fail "backup-ul pe stick nu e instalat: ruleaza o data  doas sh backup.sh --auto"; }

case "${1:-}" in
    --status)
        echo "ENABLED=$ENABLED"; echo "OFF=$OFF"; echo "ON=$ON"; echo "BACKUP_DAY=$BACKUP_DAY"
        echo "T_UPDATES=$( [ "$ENABLED" = 1 ] && fmt $(before 60) || echo 02:00)"
        echo "T_BACKUP=$BACKUP_TIME"; echo "WEEKLY_DAY=$WEEKLY_DAY"; echo "T_WEEKLY=$WEEKLY_TIME"
        echo "MONTHLY_DAY=$MONTHLY_DAY"; echo "T_MONTHLY=$MONTHLY_TIME"
        backup_auto && echo "BACKUP_AUTO=1" || echo "BACKUP_AUTO=0"
        [ -x "$BK" ] && echo "BACKUP_INSTALLED=1" || echo "BACKUP_INSTALLED=0"
        echo "KEEP=$(keep)"
        [ -f "$SKIP" ] && [ "$(cat "$SKIP")" = "$(date +%F)" ] && echo "SKIP_TONIGHT=1" || echo "SKIP_TONIGHT=0"
        [ -e "$RTC/wakealarm" ] && echo "RTC_OK=1" || echo "RTC_OK=0"
        exit 0 ;;

    --set)
        [ $# -eq 4 ] || fail "utilizare: --set OFF ON ACTIV"
        valid_time "$2" || fail "ora de oprire invalida: $2"
        valid_time "$3" || fail "ora de pornire invalida: $3"
        case "$4" in [01]) ;; *) fail "ACTIV trebuie sa fie 0 sau 1" ;; esac
        gap=$(( ($(tomin "$3") - $(tomin "$2") + 1440) % 1440 ))
        [ "$gap" -ge 15 ] || fail "pornirea trebuie sa fie la cel putin 15 minute dupa oprire"
        [ "$4" = 0 ] || [ -e "$RTC/wakealarm" ] || fail "placa nu are ceas cu pornire programabila"
        OFF=$2; ON=$3; ENABLED=$4
        write_conf
        apply_cron
        if [ "$ENABLED" = 1 ]; then
            say "program salvat: oprire $OFF, pornire $ON"
        else
            say "program oprit: mini PC-ul ramane pornit"
        fi
        exit 0 ;;

    --backup)
        [ $# -eq 4 ] || fail "utilizare: --backup ZILE ORA ACTIV"
        days=$(valid_days "$2") || fail "alege cel putin o zi pentru backup"
        valid_time "$3" || fail "ora backup-ului invalida: $3"
        case "$4" in [01]) ;; *) fail "ACTIV trebuie sa fie 0 sau 1" ;; esac
        if [ "$4" = 1 ]; then
            need_bk
            grep -q "minipc-backup --cron" "$CRON" 2>/dev/null \
                || fail "backup-ul automat a fost scos: ruleaza o data  doas sh backup.sh --auto"
        fi
        BACKUP_DAY=$days; BACKUP_TIME=$3
        write_conf
        apply_cron "$4"
        if [ "$4" = 1 ]; then
            say "backup pe stick: $(daynames "$BACKUP_DAY") la $BACKUP_TIME"
        else
            say "backup-ul automat pe stick e oprit (se face doar cand apesi 'Fa backup acum')"
        fi
        exit 0 ;;

    --maint)
        [ $# -eq 5 ] || fail "utilizare: --maint ZI ORA ZI_LUNA ORA"
        case "$2" in [0-6]) ;; *) fail "ziua intretinerii saptamanale invalida: $2 (0-6)" ;; esac
        valid_time "$3" || fail "ora intretinerii saptamanale invalida: $3"
        valid_mday "$4" || fail "ziua lunii invalida: $4 (1-28)"
        valid_time "$5" || fail "ora intretinerii lunare invalida: $5"
        WEEKLY_DAY=$2; WEEKLY_TIME=$3; MONTHLY_DAY=$4; MONTHLY_TIME=$5
        write_conf
        apply_cron
        say "intretinere: saptamanala $(dayname "$WEEKLY_DAY") la $WEEKLY_TIME, lunara pe $MONTHLY_DAY la $MONTHLY_TIME"
        exit 0 ;;

    --apply)
        apply_cron
        exit 0 ;;

    --stick-info)
        id=$(cat "$BKSTATE/usb-id" 2>/dev/null || true)
        if opened; then st=open
        elif [ -n "$id" ] && [ -e "/sys/bus/usb/devices/$id" ] && [ ! -e "/sys/bus/usb/devices/$id/driver" ]; then st=detached
        elif usb_disk; then st=connected
        else st=absent; fi
        echo "STICK=$st"
        exit 0 ;;

    --backup-now)
        need_bk
        opened && fail "stick-ul e deschis: apasa intai 'Ascunde stick-ul'"
        out=$(KEEP=$(keep) DETACH=1 "$BK" 2>&1); rc=$?
        printf '%s\n' "$out" | strip
        exit $rc ;;

    --stick-list)
        need_bk
        out=$(DETACH=1 "$BK" --list 2>&1); rc=$?
        printf '%s\n' "$out" | strip | grep -v "Stick: /dev/"
        exit $rc ;;

    --stick-open)
        need_bk
        if ! opened; then
            out=$(DETACH=0 "$BK" --list 2>&1) || fail "$(printf '%s\n' "$out" | strip | tail -n 1)"
            dev=$(printf '%s\n' "$out" | strip | sed -n 's/.*Stick: \(\/dev\/[^,]*\),.*/\1/p' | head -n 1)
            [ -b "$dev" ] || fail "nu gasesc stick-ul"
            mkdir -p "$MNT"
            mount -o ro "$dev" "$MNT" 2>/dev/null || mount -t ntfs3 -o ro "$dev" "$MNT" 2>/dev/null \
                || fail "nu pot deschide stick-ul ($dev)"
            say "stick deschis doar pentru citire in $MNT"
        fi
        echo "DIR=$MNT/minipc-backup"
        exit 0 ;;

    --stick-close)
        if opened; then
            umount "$MNT" 2>/dev/null \
                || fail "stick-ul e inca folosit: inchide fereastra lui (managerul de fisiere) si mai incearca"
        fi
        [ -x "$BK" ] && DETACH=1 "$BK" --detach >/dev/null 2>&1
        say "stick ascuns (deconectat pana la urmatorul backup)"
        exit 0 ;;

    --skip)
        date +%F > "$SKIP"
        say "in seara asta ($(date +%F)) mini PC-ul NU se opreste"
        exit 0 ;;

    --unskip)
        rm -f "$SKIP"
        say "oprirea de diseara e din nou activa"
        exit 0 ;;

    --night)
        [ "$ENABLED" = 1 ] || exit 0
        if [ -f "$SKIP" ] && [ "$(cat "$SKIP")" = "$(date +%F)" ]; then
            rm -f "$SKIP"; say "oprire sarita (Nu opri in seara asta)"; exit 0
        fi
        now=$(date +%s)
        t=$(date -d "$(date +%Y-%m-%d) $ON" +%s)
        [ "$t" -gt $((now + 120)) ] || t=$(date -d "$(date -d @$((now + 86400)) +%Y-%m-%d) $ON" +%s)
        secs=$((t - now)) ;;

    --in)
        case "${2:-5}" in ''|*[!0-9]*) fail "minute invalide" ;; esac
        secs=$(( ${2:-5} * 60 )) ;;

    *)
        sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
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
    # config din versiunea anterioara (doar ON/OFF): programul era activ daca cron-ul il folosea
    if [ -f "$CONF" ] && ! grep -q '^ENABLED=' "$CONF"; then
        grep -q "$SELF --night" /etc/crontabs/root 2>/dev/null && en=1 || en=0
        printf 'BACKUP_DAY=1\nENABLED=%s\n' "$en" >> "$CONF"
    fi
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

# ============================================================================
# fereastra "Program mini PC" (Python + Tk) si scurtatura de pe desktop
# ============================================================================
write_gui() {
    user="${DOAS_USER:-${SUDO_USER:-}}"
    python3 -c 'import tkinter' 2>/dev/null || apk add python3-tkinter || \
        { warn "Nu am putut instala python3-tkinter - fereastra nu va merge."; return 0; }

    # fereastra poate schimba programul fara parola - DOAR prin minipc-power, care verifica tot
    mkdir -p /etc/doas.d
    echo "permit nopass :wheel as root cmd $SELF" > /etc/doas.d/zz-minipc-power.conf
    chmod 600 /etc/doas.d/zz-minipc-power.conf

    mkdir -p /usr/local/bin /usr/share/applications
    cat > "$GUI" <<'PYEOF'
#!/usr/bin/env python3
"""Program mini PC - oprire / pornire, backup-ul pe stick si stick-ul.
Generat de power.sh. Tot ce are nevoie de root trece prin: doas minipc-power ..."""
import datetime
import os
import re
import subprocess
import threading
import tkinter as tk
from tkinter import ttk

HELPER = os.environ.get("MINIPC_HELPER", "doas -n /usr/local/sbin/minipc-power").split()
POWER_LOG = "/var/log/minipc-power.log"
BACKUP_LOG = "/var/log/minipc-backup.log"
DAYS = ["duminică", "luni", "marți", "miercuri", "joi", "vineri", "sâmbătă"]   # ca in cron: 0 = duminica
WEEK = [1, 2, 3, 4, 5, 6, 0]                                                    # ordinea afisata: luni ... duminica
SHORT = {0: "Du", 1: "Lu", 2: "Ma", 3: "Mi", 4: "Jo", 5: "Vi", 6: "Sâ"}
BG, CARD, INK, MUTED, ACCENT = "#f4f6fa", "#ffffff", "#1f2430", "#5b6272", "#2f6fdb"
OK, WARN, ERR = "#1e7b45", "#9a5b00", "#b3261e"
STICK = {
    "detached": ("în port, deconectat (normal între backup-uri)", OK),
    "open": ("deschis, doar citire – apasă „Ascunde stick-ul” când termini", WARN),
    "connected": ("conectat", INK),
    "absent": ("nu e băgat în mini PC", ERR),
}


def helper(*args, timeout=30):
    try:
        r = subprocess.run(HELPER + list(args), capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 1, "comanda a durat prea mult"
    return r.returncode, (r.stdout + r.stderr).strip()


def keyvals(out):
    return dict(line.split("=", 1) for line in out.splitlines() if "=" in line)


def tail(path, n):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return [ln.rstrip() for ln in f.readlines()[-n:] if ln.strip()]
    except OSError:
        return []


def tomin(t):
    h, m = t.split(":")
    return int(h) * 60 + int(m)


def fmt(m):
    m %= 1440
    return f"{m // 60:02d}:{m % 60:02d}"


def day_list(days):
    return ", ".join(DAYS[d] for d in sorted(days, key=WEEK.index))


def next_runs(days, at_min, count=3):
    """urmatoarele backup-uri: zilele (cron) + ora (minute ale zilei)"""
    now = datetime.datetime.now()
    out = []
    for i in range(15):
        d = now.date() + datetime.timedelta(days=i)
        t = datetime.datetime.combine(d, datetime.time(at_min // 60, at_min % 60))
        if (d.weekday() + 1) % 7 in days and t > now:
            out.append(t)
        if len(out) == count:
            break
    return out


def next_monthly(mday, at_min):
    now = datetime.datetime.now()
    y, m = now.year, now.month
    for _ in range(3):
        t = datetime.datetime(y, m, mday, at_min // 60, at_min % 60)
        if t > now:
            return t
        y, m = (y + 1, 1) if m == 12 else (y, m + 1)


def when(t):
    today = datetime.date.today()
    name = "azi" if t.date() == today else "mâine" if t.date() == today + datetime.timedelta(days=1) \
        else DAYS[(t.weekday() + 1) % 7]
    return f"{name} {t:%d.%m} la {t:%H:%M}"


class App:
    def __init__(self, root):
        self.root = root
        self.st = {}
        self.busy = False
        root.title("Program mini PC")
        root.configure(bg=BG)
        root.minsize(780, 430)
        st = ttk.Style()
        st.theme_use("clam")
        st.configure(".", font=("DejaVu Sans", 10), background=BG, foreground=INK)
        st.configure("Card.TFrame", background=CARD)
        st.configure("Card.TLabel", background=CARD)
        st.configure("Muted.TLabel", background=CARD, foreground=MUTED, font=("DejaVu Sans", 9))
        st.configure("Title.TLabel", background=BG, font=("DejaVu Sans", 14, "bold"))
        st.configure("H.TLabel", background=CARD, font=("DejaVu Sans", 10, "bold"))
        st.configure("Card.TCheckbutton", background=CARD)
        st.configure("CardH.TCheckbutton", background=CARD, font=("DejaVu Sans", 10, "bold"))
        st.configure("Accent.TButton", background=ACCENT, foreground="white", font=("DejaVu Sans", 10, "bold"), padding=(12, 5))
        st.map("Accent.TButton", background=[("active", "#2559b3"), ("disabled", "#9db8e8")])
        st.configure("TButton", padding=(10, 5))
        st.configure("TNotebook", background=BG, borderwidth=0)
        st.configure("TNotebook.Tab", padding=(14, 5), font=("DejaVu Sans", 10))
        st.map("TNotebook.Tab", font=[("selected", ("DejaVu Sans", 10, "bold"))])

        wrap = ttk.Frame(root, padding=(14, 10, 14, 10))
        wrap.pack(fill="both", expand=True)
        head = ttk.Frame(wrap)
        head.pack(fill="x", pady=(0, 6))
        ttk.Label(head, text="Program mini PC", style="Title.TLabel").pack(side="left")
        ttk.Button(head, text="Reîmprospătează", command=self.load).pack(side="right")

        nb = ttk.Notebook(wrap)
        nb.pack(fill="both", expand=True)
        self.tab_power(self.page(nb, "Oprire / pornire"))
        self.tab_backup(self.page(nb, "Backup și întreținere"))
        self.tab_stick(self.page(nb, "Stick"))
        nb.bind("<<NotebookTabChanged>>", lambda e: self.say(""))

        self.msg = ttk.Label(wrap, text="", wraplength=740)
        self.msg.pack(anchor="w", pady=(6, 0))

        for v in (self.off_h, self.off_m, self.on_h, self.on_m, self.enabled, self.bk_on, *self.dvars.values(),
                  self.bk_h, self.bk_m, self.wk_h, self.wk_m, self.mo_h, self.mo_m, self.mo_day):
            v.trace_add("write", lambda *a: self.preview())
        self.load()

    # ------------------------------------------------------------------ bucati
    def page(self, nb, title):
        f = ttk.Frame(nb, padding=(0, 8, 0, 0))
        nb.add(f, text=title)
        f.columnconfigure(1, weight=1)
        f.rowconfigure(0, weight=1)
        return f

    def column(self, parent, col):
        f = ttk.Frame(parent)
        f.grid(row=0, column=col, sticky="nsew", padx=(0, 10) if col == 0 else 0)
        return f

    def card(self, parent, expand=False):
        f = ttk.Frame(parent, style="Card.TFrame", padding=(12, 9))
        f.pack(fill="both" if expand else "x", expand=expand, pady=(0, 8))
        return f

    def bar(self, parent):
        f = ttk.Frame(parent)
        f.grid(row=1, column=0, columnspan=2, sticky="ew")
        return f

    def time_box(self, parent):
        f = ttk.Frame(parent, style="Card.TFrame")
        h, m = tk.StringVar(), tk.StringVar()
        ttk.Spinbox(f, from_=0, to=23, wrap=True, width=4, format="%02.0f", textvariable=h, justify="center").pack(side="left")
        ttk.Label(f, text=":", style="Card.TLabel").pack(side="left", padx=3)
        ttk.Spinbox(f, from_=0, to=55, increment=5, wrap=True, width=4, format="%02.0f", textvariable=m,
                    justify="center").pack(side="left")
        return f, h, m

    def time_row(self, parent, row, label, col=0):
        ttk.Label(parent, text=label, style="Card.TLabel").grid(row=row, column=col, sticky="w", pady=2, padx=(0, 8))
        f, h, m = self.time_box(parent)
        f.grid(row=row, column=col + 1, sticky="w", pady=2)
        return h, m

    # ------------------------------------------------------------------ tab 1
    def tab_power(self, p):
        left, right = self.column(p, 0), self.column(p, 1)
        c1 = self.card(left)
        self.enabled = tk.BooleanVar()
        ttk.Checkbutton(c1, text="Oprește și pornește automat", variable=self.enabled,
                        style="CardH.TCheckbutton").grid(row=0, column=0, columnspan=2, sticky="w", pady=(0, 6))
        self.off_h, self.off_m = self.time_row(c1, 1, "Oprire la")
        self.on_h, self.on_m = self.time_row(c1, 2, "Pornire la")
        ttk.Label(c1, text="Actualizările se fac cu o oră înainte\nde oprire. Backup-ul și întreținerea\n"
                           "au orele lor, în tab-ul următor.",
                  style="Muted.TLabel", justify="left").grid(row=3, column=0, columnspan=2, sticky="w", pady=(6, 0))

        c2 = self.card(right)
        ttk.Label(c2, text="Programul", style="H.TLabel").pack(anchor="w")
        self.plan = ttk.Label(c2, text="", style="Card.TLabel", justify="left", font=("DejaVu Sans Mono", 9))
        self.plan.pack(anchor="w", pady=(4, 0))
        c3 = self.card(right, expand=True)
        ttk.Label(c3, text="Ultimele evenimente", style="H.TLabel").pack(anchor="w")
        self.events = ttk.Label(c3, text="", style="Muted.TLabel", justify="left", wraplength=430)
        self.events.pack(anchor="w", pady=(4, 0))
        c3.bind("<Configure>", lambda e: self.events.configure(wraplength=max(200, e.width - 24)))

        b = self.bar(p)
        ttk.Button(b, text="Salvează", style="Accent.TButton", command=self.save_power).pack(side="left")

    # ------------------------------------------------------------------ tab 2
    def tab_backup(self, p):
        left, right = self.column(p, 0), self.column(p, 1)
        c1 = self.card(left)
        self.bk_on = tk.BooleanVar()
        self.bk_check = ttk.Checkbutton(c1, text="Backup automat pe stick", variable=self.bk_on,
                                        style="CardH.TCheckbutton")
        self.bk_check.grid(row=0, column=0, columnspan=2, sticky="w")
        days = ttk.Frame(c1, style="Card.TFrame")
        days.grid(row=1, column=0, columnspan=2, sticky="w", pady=(6, 2))
        self.dvars = {}
        for d in WEEK:
            self.dvars[d] = tk.BooleanVar()
            ttk.Checkbutton(days, text=SHORT[d], variable=self.dvars[d], style="Card.TCheckbutton").pack(side="left", padx=(0, 4))
        self.bk_h, self.bk_m = self.time_row(c1, 2, "Ora")
        self.bk_note = ttk.Label(c1, text="", style="Muted.TLabel", justify="left")
        self.bk_note.grid(row=3, column=0, columnspan=2, sticky="w", pady=(4, 0))

        c2 = self.card(left)
        ttk.Label(c2, text="Întreținerea sistemului", style="H.TLabel").grid(row=0, column=0, columnspan=4, sticky="w")
        ttk.Label(c2, text="Săptămânală", style="Card.TLabel").grid(row=1, column=0, sticky="w", pady=(6, 2), padx=(0, 8))
        self.wk_day = ttk.Combobox(c2, values=[DAYS[d] for d in WEEK], state="readonly", width=9)
        self.wk_day.grid(row=1, column=1, sticky="w", pady=(6, 2))
        self.wk_day.bind("<<ComboboxSelected>>", lambda e: self.preview())
        f, self.wk_h, self.wk_m = self.time_box(c2)
        f.grid(row=1, column=2, sticky="w", padx=(8, 0), pady=(6, 2))
        ttk.Label(c2, text="Lunară, ziua", style="Card.TLabel").grid(row=2, column=0, sticky="w", pady=2, padx=(0, 8))
        self.mo_day = tk.StringVar()
        ttk.Spinbox(c2, from_=1, to=28, wrap=True, width=4, textvariable=self.mo_day, justify="center").grid(
            row=2, column=1, sticky="w", pady=2)
        f, self.mo_h, self.mo_m = self.time_box(c2)
        f.grid(row=2, column=2, sticky="w", padx=(8, 0), pady=2)

        c3 = self.card(right, expand=True)
        ttk.Label(c3, text="Urmează", style="H.TLabel").pack(anchor="w")
        self.bk_next = ttk.Label(c3, text="", style="Card.TLabel", justify="left")
        self.bk_next.pack(anchor="w", pady=(4, 0))
        self.bk_warn = ttk.Label(c3, text="", style="Card.TLabel", foreground=WARN, justify="left")
        self.bk_warn.pack(anchor="w", pady=(6, 0))
        ttk.Label(c3, text="Recomandat: backup 1–2 zile pe săptămână. Între backup-uri\n"
                           "stick-ul stă deconectat, deci nu se uzează. Alege ore la care\n"
                           "mini PC-ul e pornit – cât e oprit nu se face nimic.",
                  style="Muted.TLabel", justify="left").pack(anchor="w", pady=(8, 0))

        b = self.bar(p)
        ttk.Button(b, text="Salvează", style="Accent.TButton", command=self.save_backup).pack(side="left")

    # ------------------------------------------------------------------ tab 3
    def tab_stick(self, p):
        left, right = self.column(p, 0), self.column(p, 1)
        c1 = self.card(left)
        ttk.Label(c1, text="Ultimul backup", style="H.TLabel").grid(row=0, column=0, sticky="w")
        self.last = ttk.Label(c1, text="", style="Card.TLabel", justify="left")
        self.last.grid(row=1, column=0, sticky="w", pady=(2, 6))
        ttk.Label(c1, text="Stick-ul", style="H.TLabel").grid(row=2, column=0, sticky="w")
        self.stick = ttk.Label(c1, text="", style="Card.TLabel", justify="left", wraplength=290)
        self.stick.grid(row=3, column=0, sticky="w", pady=(2, 6))
        ttk.Label(c1, text="Următorul backup automat", style="H.TLabel").grid(row=4, column=0, sticky="w")
        self.next1 = ttk.Label(c1, text="", style="Card.TLabel")
        self.next1.grid(row=5, column=0, sticky="w", pady=(2, 0))

        c2 = self.card(right, expand=True)
        ttk.Label(c2, text="Rezultat", style="H.TLabel").pack(anchor="w")
        self.out = tk.Text(c2, height=9, width=46, font=("DejaVu Sans Mono", 9), relief="flat", bg="#f7f8fb",
                           fg=INK, wrap="word", highlightthickness=0, padx=6, pady=4)
        self.out.pack(fill="both", expand=True, pady=(4, 0))
        self.out.configure(state="disabled")

        b = self.bar(p)
        self.stick_btns = [
            ttk.Button(b, text="Fă backup acum", style="Accent.TButton", command=self.backup_now),
            ttk.Button(b, text="Arată backup-urile", command=self.stick_list),
            ttk.Button(b, text="Deschide stick-ul", command=self.stick_open),
            ttk.Button(b, text="Ascunde stick-ul", command=self.stick_close),
        ]
        for i, btn in enumerate(self.stick_btns):
            btn.pack(side="left", padx=(0 if i == 0 else 8, 0))

    # ------------------------------------------------------------------ date
    def say(self, text, color=INK):
        self.msg.configure(text=text, foreground=color)

    def read_time(self, h, m):
        hh, mm = int(h.get()), int(m.get())
        if not (0 <= hh <= 23 and 0 <= mm <= 59):
            raise ValueError
        return f"{hh:02d}:{mm:02d}"

    def days(self):
        return {d for d, v in self.dvars.items() if v.get()}

    def saved_days(self):
        return {int(x) for x in self.st.get("BACKUP_DAY", "1").split(",") if x.isdigit()}

    def load(self):
        code, out = helper("--status")
        if code != 0:
            self.say(f"Nu pot citi programul: {out}", ERR)
            return
        s = keyvals(out)
        s.update(keyvals(helper("--stick-info")[1]))
        self.st = s
        self.enabled.set(s.get("ENABLED") == "1")
        for (h, m), t in (((self.off_h, self.off_m), s.get("OFF", "23:00")), ((self.on_h, self.on_m), s.get("ON", "06:30"))):
            h.set(t[:2]); m.set(t[3:])
        self.bk_on.set(s.get("BACKUP_AUTO") == "1")
        for d, v in self.dvars.items():
            v.set(d in self.saved_days())
        for (h, m), key in (((self.bk_h, self.bk_m), "T_BACKUP"), ((self.wk_h, self.wk_m), "T_WEEKLY"),
                            ((self.mo_h, self.mo_m), "T_MONTHLY")):
            t = s.get(key, "22:30")
            h.set(t[:2]); m.set(t[3:])
        self.wk_day.current(WEEK.index(int(s.get("WEEKLY_DAY", "6"))))
        self.mo_day.set(s.get("MONTHLY_DAY", "1"))
        installed = s.get("BACKUP_INSTALLED") == "1"
        self.bk_check.state(["!disabled"] if installed else ["disabled"])
        self.bk_note.configure(
            text=f"Pe stick se păstrează ultimele {s.get('KEEP', '30')} backup-uri." if installed else
            "Backup-ul pe stick nu e instalat încă. O dată, prin SSH:\ndoas sh backup.sh --auto",
            foreground=MUTED if installed else ERR)
        text, color = STICK.get(s.get("STICK", ""), ("necunoscut", MUTED))
        self.stick.configure(text=text, foreground=color)
        self.last_backup()
        self.events.configure(text="\n".join(tail(POWER_LOG, 5)) or "încă nimic")
        if s.get("RTC_OK") != "1":
            self.say("Placa nu are ceas cu pornire programabilă: oprirea automată nu poate fi activată.", ERR)
        self.preview()

    def last_backup(self):
        lines = tail(BACKUP_LOG, 200)
        ok = [i for i, ln in enumerate(lines) if "Backup OK:" in ln]
        text, color = "niciun backup încă", MUTED
        if ok:
            ln = lines[ok[-1]]
            size = re.search(r"\(([^)]+)\), verificat", ln)
            text, color = f"{ln[:16]}  ✓ verificat{'  (' + size.group(1) + ')' if size else ''}", OK
        after = lines[ok[-1] + 1:] if ok else lines
        bad = [ln for ln in after if "EROARE" in ln or "niciun stick" in ln]
        if bad:
            text += f"\nultima încercare {bad[-1][:16]}: {bad[-1][20:].replace('EROARE: ', '')[:70]}"
            color = ERR if "EROARE" in bad[-1] else WARN
        self.last.configure(text=text, foreground=color)

    def off_at(self, t, off, on):
        """True daca la minutul t mini PC-ul e oprit (programul automat activ)"""
        return self.enabled.get() and (t - off) % 1440 < (on - off) % 1440

    def preview(self):
        try:
            off = tomin(self.read_time(self.off_h, self.off_m))
            on = tomin(self.read_time(self.on_h, self.on_m))
            bk = tomin(self.read_time(self.bk_h, self.bk_m))
            wk = tomin(self.read_time(self.wk_h, self.wk_m))
            mo = tomin(self.read_time(self.mo_h, self.mo_m))
            mday = int(self.mo_day.get())
            if not 1 <= mday <= 28:
                raise ValueError
        except (ValueError, tk.TclError):
            self.plan.configure(text="(o oră nu e completă)")
            return
        wday = WEEK[self.wk_day.current()] if self.wk_day.current() >= 0 else 6
        bk_ok = self.bk_on.get() and bool(self.days())
        warn = []

        def mark(t, what):
            if self.off_at(t, off, on):
                warn.append(f"⚠ {what} la {fmt(t)}: mini PC-ul e oprit atunci")
                return "  ⚠ oprit"
            return ""

        rows = [(fmt(off - 60) if self.enabled.get() else "02:00", "actualizări (zilnic)"),
                (fmt(bk), f"backup pe stick ({day_list(self.days())})" + mark(bk, "Backup-ul"))
                if bk_ok else ("", "backup automat pe stick: oprit"),
                (fmt(wk), f"întreținere săptămânală ({DAYS[wday]})" + mark(wk, "Întreținerea săptămânală")),
                (fmt(mo), f"întreținere lunară (pe {mday})" + mark(mo, "Întreținerea lunară"))]
        if self.enabled.get():
            rows += [(fmt(off), "OPRIRE"), (fmt(on), "pornire")]
        else:
            rows += [("", "mini PC-ul rămâne pornit mereu")]
        self.plan.configure(text="\n".join(f"{t:>5}  {x}" for t, x in rows))

        runs = next_runs(self.days(), bk) if bk_ok else []
        nxt = ["Backup pe stick:"] + (["   " + when(t) for t in runs] if runs else
                                      ["   oprit" if not self.bk_on.get() else "   bifează cel puțin o zi"])
        nxt += ["Întreținere săptămânală:", "   " + when(next_runs({wday}, wk, 1)[0]),
                "Întreținere lunară:", "   " + when(next_monthly(mday, mo))]
        self.bk_next.configure(text="\n".join(nxt))
        self.bk_warn.configure(text="\n".join(warn))

        saved = self.st.get("BACKUP_AUTO") == "1" and self.saved_days()
        nb = next_runs(self.saved_days(), tomin(self.st.get("T_BACKUP", "22:30")), 1) if saved else []
        self.next1.configure(text=when(nb[0]) if nb else "oprit", foreground=INK if nb else WARN)

    # ------------------------------------------------------------------ actiuni
    def result(self, code, out, ok_text=None):
        self.load()
        if code == 0:
            self.say(ok_text or (out.splitlines()[-1] if out else "Gata ✓"), OK)
        else:
            self.say(out.splitlines()[-1] if out else "Nu a mers.", ERR)

    def save_power(self):
        try:
            off = self.read_time(self.off_h, self.off_m)
            on = self.read_time(self.on_h, self.on_m)
        except (ValueError, tk.TclError):
            self.say("Ora nu e validă (ore 0–23, minute 0–59).", ERR)
            return
        code, out = helper("--set", off, on, "1" if self.enabled.get() else "0")
        self.result(code, out, "Salvat ✓  " + out)

    def save_backup(self):
        try:
            bk = self.read_time(self.bk_h, self.bk_m)
            wk = self.read_time(self.wk_h, self.wk_m)
            mo = self.read_time(self.mo_h, self.mo_m)
            mday = int(self.mo_day.get())
        except (ValueError, tk.TclError):
            self.say("O oră nu e validă (ore 0–23, minute 0–59).", ERR)
            return
        days = self.days()
        if self.bk_on.get() and not days:
            self.say("Bifează cel puțin o zi pentru backup.", ERR)
            return
        code, out = helper("--maint", str(WEEK[self.wk_day.current()]), wk, str(mday), mo)
        if code == 0 and self.st.get("BACKUP_INSTALLED") == "1":
            days = days or self.saved_days() or {1}
            code, out2 = helper("--backup", ",".join(str(d) for d in sorted(days)), bk, "1" if self.bk_on.get() else "0")
            out = out2 if code else out2 + "; " + out
        self.result(code, out, "Salvat ✓  " + out)

    def show(self, text):
        text = "\n".join(ln.strip().removeprefix("==> ") for ln in text.splitlines())
        self.out.configure(state="normal")
        self.out.delete("1.0", "end")
        self.out.insert("end", text)
        self.out.configure(state="disabled")

    def run(self, args, waiting, done, timeout=60):
        """comanda lunga (backup, stick): in fundal, ca fereastra sa nu se blocheze"""
        if self.busy:
            return
        self.busy = True
        for b in self.stick_btns:
            b.state(["disabled"])
        self.say(waiting, MUTED)
        self.show(waiting + "\n")
        res = {}
        threading.Thread(target=lambda: res.update(r=helper(*args, timeout=timeout)), daemon=True).start()

        def wait():
            if "r" not in res:
                self.root.after(300, wait)
                return
            self.busy = False
            for b in self.stick_btns:
                b.state(["!disabled"])
            done(*res["r"])
        wait()

    def backup_now(self):
        def done(code, out):
            self.show(out)
            self.result(code, out, "Backup făcut și verificat ✓" if code == 0 else None)
        self.run(["--backup-now"], "Se face backup-ul… (durează de obicei sub un minut)", done, timeout=900)

    def stick_list(self):
        def done(code, out):
            self.show("Backup-urile de pe stick (dată, mărime):\n\n" + out if code == 0 else out)
            self.result(code, out, "Lista e în „Rezultat” ✓")
        self.run(["--stick-list"], "Citesc stick-ul…", done)

    def stick_open(self):
        def done(code, out):
            d = keyvals(out).get("DIR")
            if code == 0 and d:
                for cmd in (["thunar", d], ["xdg-open", d]):
                    try:
                        subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                        break
                    except OSError:
                        continue
                self.show(f"Stick-ul e deschis doar pentru citire:\n{d}\n\n"
                          "Poți deschide și copia fișiere, dar nu poți strica backup-urile.\n"
                          "Când termini: închide fereastra stick-ului, apoi „Ascunde stick-ul”.")
                self.result(0, "", "Stick deschis ✓  (nu uita „Ascunde stick-ul” la final)")
            else:
                self.show(out)
                self.result(code or 1, out)
        self.run(["--stick-open"], "Conectez stick-ul…", done)

    def stick_close(self):
        def done(code, out):
            self.show(out)
            self.result(code, out, "Stick ascuns ✓  (deconectat până la următorul backup)")
        self.run(["--stick-close"], "Ascund stick-ul…", done)


if __name__ == "__main__":
    root = tk.Tk()
    App(root)
    root.mainloop()
PYEOF
    chmod 755 "$GUI"

    cat > /usr/share/applications/minipc-program.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Program mini PC
Comment=Oprire / pornire, backup-ul pe stick si stick-ul
Exec=$GUI
Icon=preferences-system-time
Terminal=false
Categories=Settings;System;
EOF
    if [ -n "$user" ] && [ "$user" != root ]; then
        home="$(getent passwd "$user" | cut -d: -f6)"
        mkdir -p "$home/Desktop"
        cp /usr/share/applications/minipc-program.desktop "$home/Desktop/"
        chmod 755 "$home/Desktop/minipc-program.desktop"
        chown "$user" "$home/Desktop" "$home/Desktop/minipc-program.desktop"
    fi
}

show() {
    eval "$("$SELF" --status)"
    echo
    echo "  Ceas placa (RTC):   $([ "$RTC_OK" = 1 ] && echo "da, se poate programa pornirea" || echo "NU are pornire programabila")"
    echo "  Ora acum:           $(date '+%F %H:%M')"
    if [ "$ENABLED" = 1 ]; then
        echo "  Program:            ACTIV - oprire $OFF, pornire $ON$([ "$SKIP_TONIGHT" = 1 ] && echo " (diseara NU se opreste)")"
        echo "  Actualizari:        $T_UPDATES (cu o ora inainte de oprire)"
    else
        echo "  Program:            inactiv (mini PC-ul ramane pornit)"
    fi
    dn() { echo duminica luni marti miercuri joi vineri sambata | cut -d' ' -f$(($1 + 1)); }
    days=; for d in $(echo "$BACKUP_DAY" | tr ',' ' '); do days="${days:+$days, }$(dn "$d")"; done
    echo "  Intretinere:        saptamanala $(dn "$WEEKLY_DAY") la $T_WEEKLY, lunara pe $MONTHLY_DAY la $T_MONTHLY"
    if [ "$BACKUP_AUTO" = 1 ]; then
        echo "  Backup pe stick:    $days la $T_BACKUP"
    elif [ "$BACKUP_INSTALLED" = 1 ]; then
        echo "  Backup pe stick:    oprit (se porneste din fereastra, tab-ul 'Backup si intretinere')"
    else
        echo "  Backup pe stick:    neinstalat (doas sh backup.sh --auto)"
    fi
    [ -x "$GUI" ] && echo "  Fereastra:          'Program mini PC' pe desktop (Remote Desktop)"
    [ -f "$LOG" ] && { echo "  Ultimele evenimente:"; tail -n 3 "$LOG" | sed 's/^/    /'; }
    echo
}

case "$MODE" in
    --check)
        write_helper
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
        write_helper
        write_boot
        # valorile existente raman, daca nu dai altele
        eval "$("$SELF" --status)"
        "$SELF" --set "${ENV_OFF:-$OFF}" "${ENV_ON:-$ON}" 1 || die "Nu am putut salva programul."
        [ -z "$ENV_DAY" ] || "$SELF" --backup "$ENV_DAY" "$T_BACKUP" "$BACKUP_AUTO" || die "Nu am putut salva zilele backup-ului."
        write_gui
        rc-update add crond default >/dev/null
        log "Program activ."
        show ;;

    --disable)
        write_helper
        eval "$("$SELF" --status)"
        "$SELF" --set "$OFF" "$ON" 0 >/dev/null
        [ -e "$RTC/wakealarm" ] && echo 0 > "$RTC/wakealarm" 2>/dev/null || true
        log "Program dezactivat: mini PC-ul ramane pornit."
        show ;;

    *)
        sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
        exit 1 ;;
esac
exit 0
