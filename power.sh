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
# Variabile (optionale, doar la --enable): OFF=23:00  ON=06:30  BACKUP_DAY=1 (0=duminica ... 6=sambata)
# Dupa instalare, orele se schimba cel mai usor din fereastra "Program mini PC" (Remote Desktop).
#
# Treburile de noapte ruleaza inainte de oprire, relativ la ora de oprire:
#   actualizari: -60 min, intretinere saptamanala: -50, lunara: -40, backup pe stick: -30.
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
#   minipc-power --set OFF ON ZI ACTIV    salveaza programul (ex: --set 23:00 06:30 1 1)
#   minipc-power --skip | --unskip        in seara asta nu se opreste / anuleaza
#   minipc-power --night                  (din cron) programeaza pornirea si opreste
#   minipc-power --in MINUTE              oprire acum, pornire peste MINUTE (test)
set -u
CONF=/etc/minipc-power.conf
CRON=/etc/crontabs/root
RTC="${RTC:-/sys/class/rtc/rtc0}"
LOG=/var/log/minipc-power.log
SKIP=/var/lib/minipc-power/skip
SELF=/usr/local/sbin/minipc-power
OFF=23:00; ON=06:30; BACKUP_DAY=1; ENABLED=0
[ -f "$CONF" ] && . "$CONF"

say() { echo "$(date '+%F %T') $*" >> "$LOG"; echo "$*"; }
fail() { echo "EROARE: $*" >&2; exit 1; }
valid_time() { case "$1" in [01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) return 0 ;; esac; return 1; }
tomin() { h=${1%:*}; m=${1#*:}; h=${h#0}; m=${m#0}; echo $(( h * 60 + m )); }
fmt() { printf '%02d:%02d' $(( $1 / 60 )) $(( $1 % 60 )); }
before() { echo $(( ($(tomin "$OFF") - $1 + 1440) % 1440 )); }   # minute ale zilei, cu $1 min inainte de oprire
dayname() { d=$1; set -- duminica luni marti miercuri joi vineri sambata; shift "$d"; echo "$1"; }

# muta ora unei linii din crontab: $1 text, $2 minute-ale-zilei, $3 ziua saptamanii (optional)
set_time() {
    grep -q "$1" "$CRON" 2>/dev/null || return 0
    awk -v pat="$1" -v m=$(( $2 % 60 )) -v h=$(( $2 / 60 )) -v d="${3:-}" \
        'index($0, pat) { $1 = m; $2 = h; if (d != "") $5 = d } { print }' "$CRON" > "$CRON.tmp"
    cat "$CRON.tmp" > "$CRON"; rm -f "$CRON.tmp"
}

case "${1:-}" in
    --status)
        echo "ENABLED=$ENABLED"; echo "OFF=$OFF"; echo "ON=$ON"; echo "BACKUP_DAY=$BACKUP_DAY"
        echo "T_UPDATES=$(fmt $(before 60))"; echo "T_WEEKLY=$(fmt $(before 50))"
        echo "T_MONTHLY=$(fmt $(before 40))"; echo "T_BACKUP=$(fmt $(before 30))"
        grep -q "minipc-backup --cron" "$CRON" 2>/dev/null && echo "BACKUP_AUTO=1" || echo "BACKUP_AUTO=0"
        [ -f "$SKIP" ] && [ "$(cat "$SKIP")" = "$(date +%F)" ] && echo "SKIP_TONIGHT=1" || echo "SKIP_TONIGHT=0"
        [ -e "$RTC/wakealarm" ] && echo "RTC_OK=1" || echo "RTC_OK=0"
        exit 0 ;;

    --set)
        [ $# -eq 5 ] || fail "utilizare: --set OFF ON ZI ACTIV"
        valid_time "$2" || fail "ora de oprire invalida: $2"
        valid_time "$3" || fail "ora de pornire invalida: $3"
        case "$4" in [0-6]) ;; *) fail "ziua backup-ului invalida: $4 (0-6)" ;; esac
        case "$5" in [01]) ;; *) fail "ACTIV trebuie sa fie 0 sau 1" ;; esac
        gap=$(( ($(tomin "$3") - $(tomin "$2") + 1440) % 1440 ))
        [ "$gap" -ge 15 ] || fail "pornirea trebuie sa fie la cel putin 15 minute dupa oprire"
        [ "$5" = 0 ] || [ -e "$RTC/wakealarm" ] || fail "placa nu are ceas cu pornire programabila"
        OFF=$2; ON=$3; BACKUP_DAY=$4; ENABLED=$5
        printf 'OFF=%s\nON=%s\nBACKUP_DAY=%s\nENABLED=%s\n' "$OFF" "$ON" "$BACKUP_DAY" "$ENABLED" > "$CONF.tmp"
        mv "$CONF.tmp" "$CONF"; chmod 644 "$CONF"
        mkdir -p /etc/crontabs; touch "$CRON"
        sed -i "\|$SELF --night|d" "$CRON"
        if [ "$ENABLED" = 1 ]; then
            o=$(tomin "$OFF")
            echo "$(( o % 60 )) $(( o / 60 )) * * * $SELF --night" >> "$CRON"
            set_time "run-parts /etc/periodic/daily"   "$(before 60)"
            set_time "run-parts /etc/periodic/weekly"  "$(before 50)"
            set_time "run-parts /etc/periodic/monthly" "$(before 40)"
        else
            set_time "run-parts /etc/periodic/daily"   120
            set_time "run-parts /etc/periodic/weekly"  180
            set_time "run-parts /etc/periodic/monthly" 300
        fi
        set_time "minipc-backup --cron" "$(before 30)" "$BACKUP_DAY"
        rc-service crond restart >/dev/null 2>&1 || true
        if [ "$ENABLED" = 1 ]; then
            say "program salvat: oprire $OFF, pornire $ON, backup pe stick $(dayname "$BACKUP_DAY") la $(fmt $(before 30))"
        else
            say "program oprit: mini PC-ul ramane pornit (backup pe stick $(dayname "$BACKUP_DAY") la $(fmt $(before 30)))"
        fi
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
"""Program mini PC - fereastra pentru ora de oprire / pornire si backup-ul pe stick.
Generat de power.sh. Schimbarile se fac prin: doas minipc-power --set ..."""
import os
import subprocess
import tkinter as tk
from tkinter import ttk

HELPER = os.environ.get("MINIPC_HELPER", "doas -n /usr/local/sbin/minipc-power").split()
LOGS = [("Program", "/var/log/minipc-power.log"), ("Backup", "/var/log/minipc-backup.log")]
DAYS = ["Duminică", "Luni", "Marți", "Miercuri", "Joi", "Vineri", "Sâmbătă"]
DAYS_SHORT = ["duminica", "luni", "marti", "miercuri", "joi", "vineri", "sambata"]
BG, CARD, INK, MUTED, ACCENT, OK, ERR = "#f4f6fa", "#ffffff", "#1f2430", "#5b6272", "#2f6fdb", "#1e7b45", "#b3261e"


def helper(*args):
    r = subprocess.run(HELPER + list(args), capture_output=True, text=True, timeout=30)
    return r.returncode, (r.stdout + r.stderr).strip()


def status():
    code, out = helper("--status")
    if code != 0:
        raise RuntimeError(out or "nu pot citi programul")
    return dict(line.split("=", 1) for line in out.splitlines() if "=" in line)


def tomin(t):
    h, m = t.split(":")
    return int(h) * 60 + int(m)


def fmt(m):
    m %= 1440
    return f"{m // 60:02d}:{m % 60:02d}"


class App:
    def __init__(self, root):
        self.root = root
        root.title("Program mini PC")
        root.configure(bg=BG)
        root.resizable(False, False)
        st = ttk.Style()
        st.theme_use("clam")
        base = ("DejaVu Sans", 11)
        st.configure(".", font=base, background=BG, foreground=INK)
        st.configure("Card.TFrame", background=CARD)
        st.configure("Card.TLabel", background=CARD)
        st.configure("Muted.TLabel", background=CARD, foreground=MUTED, font=("DejaVu Sans", 10))
        st.configure("Title.TLabel", background=BG, font=("DejaVu Sans", 17, "bold"))
        st.configure("H.TLabel", background=CARD, font=("DejaVu Sans", 12, "bold"))
        st.configure("Card.TCheckbutton", background=CARD, font=("DejaVu Sans", 11, "bold"))
        st.configure("Accent.TButton", background=ACCENT, foreground="white", font=("DejaVu Sans", 11, "bold"), padding=(14, 7))
        st.map("Accent.TButton", background=[("active", "#2559b3")])
        st.configure("TButton", padding=(12, 7))

        wrap = ttk.Frame(root, padding=18)
        wrap.pack(fill="both", expand=True)
        ttk.Label(wrap, text="Program mini PC", style="Title.TLabel").pack(anchor="w")
        ttk.Label(wrap, text="Oprire seara, pornire dimineața și backup-ul pe stick.",
                  foreground=MUTED).pack(anchor="w", pady=(0, 12))

        # --- oprire / pornire
        c1 = self.card(wrap)
        self.enabled = tk.BooleanVar()
        ttk.Checkbutton(c1, text="Oprește și pornește automat", variable=self.enabled, style="Card.TCheckbutton",
                        command=self.preview).grid(row=0, column=0, columnspan=4, sticky="w", pady=(0, 10))
        self.off_h, self.off_m = self.time_row(c1, 1, "Oprire la")
        self.on_h, self.on_m = self.time_row(c1, 2, "Pornire la")

        # --- backup
        c2 = self.card(wrap)
        ttk.Label(c2, text="Backup pe stick", style="H.TLabel").grid(row=0, column=0, columnspan=3, sticky="w")
        ttk.Label(c2, text="Ziua", style="Card.TLabel").grid(row=1, column=0, sticky="w", pady=(8, 0))
        self.day = ttk.Combobox(c2, values=DAYS, state="readonly", width=12)
        self.day.grid(row=1, column=1, sticky="w", padx=(10, 0), pady=(8, 0))
        self.day.bind("<<ComboboxSelected>>", lambda e: self.preview())
        self.backup_at = ttk.Label(c2, text="", style="Card.TLabel")
        self.backup_at.grid(row=1, column=2, sticky="w", padx=(12, 0), pady=(8, 0))
        ttk.Label(c2, text="Backup-ul se face mereu cu 30 de minute înainte de oprire.",
                  style="Muted.TLabel").grid(row=2, column=0, columnspan=3, sticky="w", pady=(6, 0))

        # --- programul serii
        c3 = self.card(wrap)
        ttk.Label(c3, text="Programul serii", style="H.TLabel").pack(anchor="w")
        self.plan = ttk.Label(c3, text="", style="Card.TLabel", justify="left", font=("DejaVu Sans Mono", 10))
        self.plan.pack(anchor="w", pady=(6, 0))

        # --- butoane
        bar = ttk.Frame(wrap)
        bar.pack(fill="x", pady=(4, 8))
        ttk.Button(bar, text="Salvează", style="Accent.TButton", command=self.save).pack(side="left")
        self.skip_btn = ttk.Button(bar, text="Nu opri în seara asta", command=self.toggle_skip)
        self.skip_btn.pack(side="left", padx=8)
        ttk.Button(bar, text="Reîmprospătează", command=self.load).pack(side="right")
        self.msg = ttk.Label(wrap, text="", wraplength=470)
        self.msg.pack(anchor="w", pady=(0, 8))

        # --- ultimele evenimente
        c4 = self.card(wrap)
        ttk.Label(c4, text="Ultimele evenimente", style="H.TLabel").pack(anchor="w")
        self.events = ttk.Label(c4, text="", style="Muted.TLabel", justify="left", wraplength=470)
        self.events.pack(anchor="w", pady=(6, 0))

        for v in (self.off_h, self.off_m, self.on_h, self.on_m):
            v.trace_add("write", lambda *a: self.preview())
        self.load()

    def card(self, parent):
        f = ttk.Frame(parent, style="Card.TFrame", padding=14)
        f.pack(fill="x", pady=(0, 10))
        return f

    def time_row(self, parent, row, label):
        ttk.Label(parent, text=label, style="Card.TLabel", width=11).grid(row=row, column=0, sticky="w", pady=3)
        h, m = tk.StringVar(), tk.StringVar()
        ttk.Spinbox(parent, from_=0, to=23, wrap=True, width=4, format="%02.0f", textvariable=h,
                    justify="center").grid(row=row, column=1, pady=3)
        ttk.Label(parent, text=":", style="Card.TLabel").grid(row=row, column=2, padx=3)
        ttk.Spinbox(parent, from_=0, to=55, increment=5, wrap=True, width=4, format="%02.0f", textvariable=m,
                    justify="center").grid(row=row, column=3, pady=3)
        return h, m

    def read_time(self, h, m):
        hh, mm = int(h.get()), int(m.get())
        if not (0 <= hh <= 23 and 0 <= mm <= 59):
            raise ValueError
        return f"{hh:02d}:{mm:02d}"

    def say(self, text, color=INK):
        self.msg.configure(text=text, foreground=color)

    def load(self):
        try:
            s = status()
        except Exception as e:  # noqa
            self.say(f"Nu pot citi programul: {e}", ERR)
            return
        self.st = s
        self.enabled.set(s.get("ENABLED") == "1")
        for (h, m), t in (((self.off_h, self.off_m), s.get("OFF", "23:00")), ((self.on_h, self.on_m), s.get("ON", "06:30"))):
            h.set(t[:2]); m.set(t[3:])
        self.day.current(int(s.get("BACKUP_DAY", "1")))
        self.skip_btn.configure(text="Anulează: oprește diseară" if s.get("SKIP_TONIGHT") == "1" else "Nu opri în seara asta")
        if s.get("RTC_OK") != "1":
            self.say("Placa nu are ceas cu pornire programabilă: programul automat nu poate fi activat.", ERR)
        self.preview()
        self.load_events()

    def load_events(self):
        lines = []
        for name, path in LOGS:
            try:
                with open(path, encoding="utf-8", errors="replace") as f:
                    lines += [f"{name}: {ln.strip()}" for ln in f.readlines()[-3:] if ln.strip()]
            except OSError:
                pass
        self.events.configure(text="\n".join(lines[-6:]) or "încă nimic")

    def preview(self):
        try:
            off = tomin(self.read_time(self.off_h, self.off_m))
            on = tomin(self.read_time(self.on_h, self.on_m))
        except (ValueError, tk.TclError):
            self.plan.configure(text="(ora nu e completă)")
            return
        d = self.day.current() if self.day.current() >= 0 else 1
        self.backup_at.configure(text=f"la {fmt(off - 30)}")
        rows = [(fmt(off - 60), "actualizări automate"),
                (fmt(off - 50), "întreținere săptămânală (sâmbătă)"),
                (fmt(off - 40), "întreținere lunară (pe 1)"),
                (fmt(off - 30), f"backup pe stick ({DAYS[d].lower()})")]
        if self.enabled.get():
            rows += [(fmt(off), "OPRIRE"), (fmt(on), "pornire (a doua zi)" if on <= off else "pornire")]
        else:
            rows = [(fmt(off - 30), f"backup pe stick ({DAYS[d].lower()})"), ("", "mini PC-ul rămâne pornit mereu")]
        if self.st.get("BACKUP_AUTO") == "0":
            rows.append(("", "backup-ul automat nu e activ (doas sh backup.sh --auto)"))
        self.plan.configure(text="\n".join(f"{t:>5}  {x}" for t, x in rows))

    def save(self):
        try:
            off = self.read_time(self.off_h, self.off_m)
            on = self.read_time(self.on_h, self.on_m)
        except (ValueError, tk.TclError):
            self.say("Ora nu e validă (ore 0–23, minute 0–59).", ERR)
            return
        code, out = helper("--set", off, on, str(self.day.current()), "1" if self.enabled.get() else "0")
        if code == 0:
            self.say("Salvat ✓  " + out, OK)
            self.load()
            self.say("Salvat ✓  " + out, OK)
        else:
            self.say(out or "Nu am putut salva.", ERR)

    def toggle_skip(self):
        arg = "--unskip" if self.st.get("SKIP_TONIGHT") == "1" else "--skip"
        code, out = helper(arg)
        self.load()
        self.say(out, OK if code == 0 else ERR)


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
Comment=Ora de oprire / pornire si backup-ul pe stick
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
        echo "  Inainte de oprire:  $T_UPDATES actualizari, $T_WEEKLY / $T_MONTHLY intretinere, $T_BACKUP backup pe stick"
    else
        echo "  Program:            inactiv (mini PC-ul ramane pornit)"
    fi
    days="duminica luni marti miercuri joi vineri sambata"
    echo "  Backup pe stick:    $(echo $days | cut -d' ' -f$((BACKUP_DAY + 1))) la $T_BACKUP$([ "$BACKUP_AUTO" = 0 ] && echo "  (INACTIV: doas sh backup.sh --auto)")"
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
        "$SELF" --set "${ENV_OFF:-$OFF}" "${ENV_ON:-$ON}" "${ENV_DAY:-$BACKUP_DAY}" 1 || die "Nu am putut salva programul."
        write_gui
        rc-update add crond default >/dev/null
        log "Program activ."
        show ;;

    --disable)
        write_helper
        eval "$("$SELF" --status)"
        "$SELF" --set "$OFF" "$ON" "$BACKUP_DAY" 0 >/dev/null
        [ -e "$RTC/wakealarm" ] && echo 0 > "$RTC/wakealarm" 2>/dev/null || true
        log "Program dezactivat: mini PC-ul ramane pornit."
        show ;;

    *)
        sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
        exit 1 ;;
esac
exit 0
