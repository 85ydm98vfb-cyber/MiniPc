#!/bin/sh
# Backup pe stick USB pentru datele aplicatiilor de pe mini PC (PS Games + Watch Time).
#
# Utilizare (logat prin SSH cu utilizatorul tau):
#   doas sh backup.sh               backup acum pe stick (il gaseste singur, apoi il poti scoate)
#   doas sh backup.sh --auto        + backup automat in fiecare luni la 22:30, daca stick-ul e bagat
#   doas sh backup.sh --list        arata backup-urile de pe stick
#   doas sh backup.sh --no-auto     opreste backup-ul automat
#
# Variabile (optionale):
#   KEEP        cate backup-uri se pastreaza pe stick (implicit 30 = ~7 luni; cele mai vechi se sterg)
#   DEV         partitia stick-ului, daca sunt mai multe (ex: DEV=/dev/sdb1)
#   DETACH      1 = dupa backup stick-ul e deconectat din sistem pana la urmatorul backup (implicit 1)
#
# Pe stick se creeaza folderul minipc-backup/ cu cate un subfolder pe data, ex:
#   minipc-backup/2026-09-28_03-30/ps-games/PlayStation_Games.json
#   minipc-backup/2026-09-28_03-30/watchtime/watchtime.db          (tot: conturi, parole, setari)
#   minipc-backup/2026-09-28_03-30/watchtime/conturi/alex.json     (un cont; Profil -> Importa date)
# Intre backup-urile de luni ai oricum copiile zilnice pe care PS Games le face singur
# in /opt/ps-games/data/backup; stick-ul e copia din afara mini PC-ului.
# Backup-ul automat scrie DOAR pe stick-uri care au deja folderul minipc-backup/
# (creat la primul backup manual), ca sa nu scrie pe alt disc USB bagat intamplator.
#
# Intre backup-uri stick-ul ramane in port, dar deconectat logic: sistemul nu-l vede, nimic nu
# poate scrie pe el si consuma aproape nimic. Scriptul il reconecteaza singur inainte de backup.
# (dupa un restart al mini PC-ului e deconectat din nou automat, daca backup-ul automat e activ)
set -eu

KEEP="${KEEP:-30}"
DEV="${DEV:-}"
DETACH="${DETACH:-1}"
MARK=minipc-backup
MNT=/mnt/minipc-backup
LOG=/var/log/minipc-backup.log
STATE=/var/lib/minipc-backup
SELF=/usr/local/sbin/minipc-backup
BOOT=/etc/local.d/minipc-backup.start
MODE="${1:-now}"

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; echo "$(date '+%F %T') $*" >> "$LOG"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; echo "$(date '+%F %T') ATENTIE: $*" >> "$LOG"; }
die() { printf '\033[1;31mEROARE:\033[0m %s\n' "$*" >&2; echo "$(date '+%F %T') EROARE: $*" >> "$LOG"; exit 1; }
quiet() { echo "$(date '+%F %T') $*" >> "$LOG"; }

[ "$(id -u)" -eq 0 ] || die "Ruleaza cu doas:  doas sh backup.sh"
case "$KEEP" in ''|*[!0-9]*|0) die "KEEP invalid: $KEEP" ;; esac
mkdir -p "$STATE"

# --- instalare / dezinstalare backup automat -------------------------------------
if [ "$MODE" = --auto ] || [ "$MODE" = --no-auto ]; then
    mkdir -p /etc/crontabs /usr/local/sbin /etc/local.d
    touch /etc/crontabs/root
    sed -i "\|$SELF|d" /etc/crontabs/root
    if [ "$MODE" = --auto ]; then
        [ "$(readlink -f "$0")" = "$SELF" ] || install -m 755 "$0" "$SELF"
        echo "30 22 * * 1 KEEP=$KEEP DETACH=$DETACH $SELF --cron" >> /etc/crontabs/root
        # la pornirea mini PC-ului stick-ul apare din nou -> il deconectam
        printf '#!/bin/sh\n# Generat de backup.sh: deconecteaza stick-ul de backup la pornire\nDETACH=%s %s --detach >/dev/null 2>&1 &\n' \
            "$DETACH" "$SELF" > "$BOOT"
        chmod 755 "$BOOT"
        rc-update add local default >/dev/null 2>&1 || true
        rc-update add crond default >/dev/null
        rc-service crond restart >/dev/null 2>&1 || true
        log "Backup automat activat: in fiecare luni la 22:30 (log: $LOG)."
        echo "   Acum fac si un backup, ca sa pregatesc stick-ul."
        MODE=now
    else
        rm -f "$BOOT"
        rc-service crond restart >/dev/null 2>&1 || true
        log "Backup automat oprit."
        exit 0
    fi
fi

# --- stick USB: gasire, montare, deconectare ---------------------------------------
# partitiile de pe discuri conectate prin USB
usb_parts() {
    for b in /sys/block/sd*; do
        [ -e "$b" ] || continue
        readlink -f "$b" | grep -q '/usb' || continue
        d="${b##*/}"; found=0
        for p in "$b/$d"*; do
            [ -e "$p" ] || continue
            found=1; echo "/dev/${p##*/}"
        done
        [ "$found" = 1 ] || echo "/dev/$d"
    done
}

# id-ul dispozitivului USB (ex: 2-1) pentru o partitie; gol daca nu e pe USB
usb_id_of() {
    readlink -f "/sys/class/block/${1##*/}" 2>/dev/null | tr '/' '\n' | grep -E '^[0-9]+-[0-9.]+$' | tail -n 1
}

# discul unei partitii (sdb1 -> sdb)
disk_of() { d="${1##*/}"; echo "${d%%[0-9]*}"; }

# reconecteaza stick-ul deconectat la backup-ul anterior
reattach() {
    [ -f "$STATE/usb-id" ] || return 0
    id="$(cat "$STATE/usb-id")"
    rm -f "$STATE/usb-id"
    [ -e "/sys/bus/usb/devices/$id" ] || return 0          # a fost scos fizic intre timp
    [ -e "/sys/bus/usb/devices/$id/driver" ] && return 0   # e deja conectat
    echo "$id" > /sys/bus/usb/drivers/usb/bind 2>/dev/null || return 0
    quiet "stick reconectat ($id)"
    i=0
    while [ "$i" -lt 15 ]; do                                # asteptam sa apara discul
        [ -n "$(usb_parts)" ] && { sleep 1; return 0; }
        i=$((i + 1)); sleep 1
    done
}

# deconecteaza logic stick-ul (ramane in port, dar sistemul nu-l mai vede)
detach() {
    [ "$DETACH" = 1 ] && [ -n "$DEV" ] || return 0
    id="$(usb_id_of "$DEV")"
    [ -n "$id" ] || return 0
    if grep -q "^/dev/$(disk_of "$DEV")" /proc/mounts; then
        warn "Stick-ul e deschis in alta parte (ex. pe desktop) - nu il deconectez."
        return 0
    fi
    sync
    if echo "$id" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null; then
        echo "$id" > "$STATE/usb-id"
        quiet "stick deconectat ($id) pana la urmatorul backup"
        DETACHED=1
    fi
}

mountpoint_of() { awk -v d="$1" '$1 == d {print $2; exit}' /proc/mounts | sed 's/\\040/ /g'; }

MOUNTED_BY_US=0
DETACHED=0
mount_dev() {    # $1 = partitia -> seteaza TARGET (folderul unde e montata)
    TARGET="$(mountpoint_of "$1")"
    [ -n "$TARGET" ] && return 0
    for m in vfat exfat ntfs3; do modprobe "$m" 2>/dev/null || true; done
    mkdir -p "$MNT"
    if mount "$1" "$MNT" 2>/dev/null || mount -t ntfs3 "$1" "$MNT" 2>/dev/null; then
        TARGET="$MNT"; MOUNTED_BY_US=1; return 0
    fi
    return 1
}

cleanup() {
    if [ "$MOUNTED_BY_US" = 1 ]; then
        sync
        umount "$MNT" 2>/dev/null || true
        MOUNTED_BY_US=0
    fi
    detach || true
}
trap cleanup EXIT

reattach

TARGET=
if [ -n "$DEV" ]; then
    [ -b "$DEV" ] || die "Nu exista partitia $DEV"
    mount_dev "$DEV" || die "Nu pot monta $DEV (stick formatat FAT32, exFAT sau NTFS?)"
else
    parts="$(usb_parts)"
    if [ -z "$parts" ]; then
        case "$MODE" in --cron|--detach) quiet "niciun stick USB bagat - nimic de facut"; exit 0 ;; esac
        die "Nu gasesc niciun stick USB. Baga stick-ul si mai incearca."
    fi
    # intai un stick deja folosit pentru backup (are folderul minipc-backup/)
    for p in $parts; do
        mount_dev "$p" || continue
        if [ -d "$TARGET/$MARK" ]; then DEV="$p"; break; fi
        if [ "$MOUNTED_BY_US" = 1 ]; then umount "$MNT" 2>/dev/null || true; MOUNTED_BY_US=0; fi
        TARGET=
    done
    if [ -z "$DEV" ]; then
        case "$MODE" in --cron|--detach) quiet "niciun stick pregatit (fara folderul $MARK/) - nimic de facut"; exit 0 ;; esac
        n="$(echo "$parts" | wc -l)"
        [ "$n" -eq 1 ] || die "Am gasit mai multe partitii USB: $(echo $parts). Alege una: doas env DEV=/dev/sdX1 sh backup.sh"
        DEV="$parts"
        mount_dev "$DEV" || die "Nu pot monta $DEV (stick formatat FAT32, exFAT sau NTFS?)"
    fi
fi

# --- doar deconectare (la pornirea mini PC-ului) ------------------------------------
[ "$MODE" = --detach ] && exit 0      # cleanup demonteaza si deconecteaza

log "Stick: $DEV, montat in $TARGET"

# --- lista ------------------------------------------------------------------------
if [ "$MODE" = --list ]; then
    if [ -d "$TARGET/$MARK" ]; then
        ls -1 "$TARGET/$MARK" | while read -r d; do
            printf '  %s  %s\n' "$d" "$(du -sh "$TARGET/$MARK/$d" 2>/dev/null | cut -f1)"
        done
    else
        echo "  Stick-ul nu are inca niciun backup."
    fi
    exit 0
fi

# --- backup -------------------------------------------------------------------------
STAMP="$(date '+%Y-%m-%d_%H-%M')"
DEST="$TARGET/$MARK/$STAMP"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; cleanup' EXIT
done_any=0

# PlayStation Games: fisierele JSON (datele + parola criptata), fara backup-urile zilnice interne
if [ -d /opt/ps-games/data ]; then
    mkdir -p "$TMP/ps-games"
    for f in /opt/ps-games/data/*.json; do
        [ -f "$f" ] && cp -p "$f" "$TMP/ps-games/"
    done
    done_any=1
fi

# Watch Time: copie consistenta a bazei SQLite (sigura si cand aplicatia scrie) + setarile
if [ -f /opt/watchtime/data/watchtime.db ]; then
    mkdir -p "$TMP/watchtime"
    python3 - /opt/watchtime/data/watchtime.db "$TMP/watchtime/watchtime.db" <<'PY' || die "Copierea bazei Watch Time a esuat."
import sqlite3, sys
src = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
dst = sqlite3.connect(sys.argv[2])
with dst:
    src.backup(dst)
ok = dst.execute("PRAGMA integrity_check").fetchone()[0]
dst.close(); src.close()
sys.exit(0 if ok == "ok" else 1)
PY
    [ -f /opt/watchtime/config.json ] && cp -p /opt/watchtime/config.json "$TMP/watchtime/"
    # cheia pentru notificari: fara ea, dupa o restaurare telefoanele trebuie abonate din nou
    [ -f /opt/watchtime/data/vapid.pem ] && cp -p /opt/watchtime/data/vapid.pem "$TMP/watchtime/"
    # + cate un JSON pe cont, in formatul aplicatiei (Profil -> Copie de siguranta),
    #   generat din copia de mai sus; se importa din Profil -> Importa date
    python3 - "$TMP/watchtime/watchtime.db" "$TMP/watchtime/conturi" <<'PY' || warn "Nu am putut genera JSON-urile pe conturi (baza .db e salvata)."
import datetime, json, os, sqlite3, sys
db = sqlite3.connect(sys.argv[1]); db.row_factory = sqlite3.Row
out = sys.argv[2]; os.makedirs(out, exist_ok=True)
now = datetime.datetime.now().isoformat(timespec="seconds")
for u in db.execute("SELECT id, username FROM users WHERE is_admin = 0"):
    doc = {"exported_at": now,
           "items": [dict(r) for r in db.execute("SELECT * FROM items WHERE user_id=?", (u["id"],))],
           "plays": [dict(r) for r in db.execute("SELECT * FROM plays WHERE user_id=?", (u["id"],))]}
    name = u["username"]
    if name.startswith("."):
        name = "_" + name
    with open(os.path.join(out, name + ".json"), "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False)
PY
    done_any=1
fi

[ "$done_any" = 1 ] || die "Nu am gasit datele aplicatiilor (/opt/ps-games, /opt/watchtime)."

# copiere pe stick + verificare (sume de control)
mkdir -p "$DEST" || die "Nu pot scrie pe stick (e protejat la scriere sau plin?)"
( cd "$TMP" && find . -type f | sort | xargs sha256sum ) > "$TMP.sums"
mv "$TMP.sums" "$TMP/SHA256SUMS"
cp -R "$TMP/." "$DEST/" || die "Copierea pe stick a esuat (stick plin?)"
sync
( cd "$DEST" && sha256sum -c -s SHA256SUMS ) || die "Verificarea copiei de pe stick a esuat - stick defect?"

# pastreaza doar ultimele KEEP backup-uri
n=0
for d in $(ls -1r "$TARGET/$MARK"); do
    n=$((n + 1))
    [ "$n" -gt "$KEEP" ] && rm -rf "${TARGET:?}/$MARK/$d"
done

size="$(du -sh "$DEST" | cut -f1)"
log "Backup OK: $MARK/$STAMP ($size), verificat. Pe stick sunt $(ls -1 "$TARGET/$MARK" | wc -l) backup-uri (maxim $KEEP)."
if [ "$DETACH" = 1 ] && [ -n "$(usb_id_of "$DEV")" ]; then
    echo "   Stick-ul se deconecteaza acum din sistem. Il poti lasa in port sau il poti scoate."
elif [ "$MOUNTED_BY_US" = 1 ]; then
    echo "   Stick-ul se demonteaza acum - il poti scoate dupa ce se termina comanda."
fi
exit 0
