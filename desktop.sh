#!/bin/sh
# Interfata grafica (XFCE) pe mini PC + acces din Windows cu Remote Desktop (RDP).
#
# Utilizare (logat prin SSH cu utilizatorul tau):
#   doas sh desktop.sh
#
# Variabile (optionale):
#   DESKTOP_USER  utilizatorul care se conecteaza (implicit cel care a rulat doas)
#   RDP           1 = acces Remote Desktop pe portul 3389, doar din reteaua de acasa (implicit 1)
#   APPS          1 = Firefox, editor de text, arhivator, fonturi (implicit 1)
set -eu

DESKTOP_USER="${DESKTOP_USER:-${DOAS_USER:-${SUDO_USER:-}}}"
RDP="${RDP:-1}"
APPS="${APPS:-1}"

log() { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mEROARE:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Ruleaza cu doas: doas sh desktop.sh"
[ -f /etc/alpine-release ] || die "Scriptul este doar pentru Alpine Linux."
[ -n "$DESKTOP_USER" ] && [ "$DESKTOP_USER" != root ] || \
    die "Ruleaza cu doas din contul tau (nu ca root), sau seteaza DESKTOP_USER=..."
id "$DESKTOP_USER" >/dev/null 2>&1 || die "Utilizatorul $DESKTOP_USER nu exista."
USER_HOME="$(getent passwd "$DESKTOP_USER" | cut -d: -f6)"

log "Actualizez lista de pachete"
apk update

# --- XFCE ---------------------------------------------------------------------
log "Instalez interfata grafica XFCE (dureaza cateva minute)"
command -v setup-desktop >/dev/null || apk add alpine-conf
setup-desktop xfce

PKGS="dbus dbus-x11 xfce4-terminal"
[ "$RDP" = 1 ] && PKGS="$PKGS xrdp xorgxrdp"
log "Instalez: $PKGS"
# shellcheck disable=SC2086
apk add $PKGS

if [ "$APPS" = 1 ]; then
    log "Instalez aplicatii: browser, editor, imagini, arhive, fonturi"
    for p in firefox mousepad ristretto xarchiver thunar-archive-plugin \
             font-dejavu font-noto adwaita-icon-theme; do
        apk add -q "$p" || warn "Nu am putut instala $p - continui fara el."
    done
fi

rc-update add dbus default >/dev/null
rc-service dbus start >/dev/null 2>&1 || true

# grupurile necesare pentru sunet, video, USB-uri
for g in audio video input plugdev netdev; do
    getent group "$g" >/dev/null && addgroup "$DESKTOP_USER" "$g" 2>/dev/null || true
done

# --- Remote Desktop -----------------------------------------------------------
if [ "$RDP" = 1 ]; then
    log "Configurez Remote Desktop (xrdp)"

    # sesiunea pornita la conectare: XFCE
    [ -f /etc/xrdp/startwm.sh ] && [ ! -f /etc/xrdp/startwm.sh.orig ] && \
        cp /etc/xrdp/startwm.sh /etc/xrdp/startwm.sh.orig
    cat > /etc/xrdp/startwm.sh <<'EOF'
#!/bin/sh
# Generat de desktop.sh - porneste XFCE pentru sesiunile Remote Desktop
[ -r /etc/profile ] && . /etc/profile
[ -r "$HOME/.profile" ] && . "$HOME/.profile"
exec dbus-launch --exit-with-session startxfce4
EOF
    chmod 755 /etc/xrdp/startwm.sh

    # Xorg poate fi pornit si de xrdp, nu doar de pe consola
    mkdir -p /etc/X11
    echo "allowed_users=anybody" > /etc/X11/Xwrapper.config

    for s in xrdp-sesman xrdp; do
        if [ -x "/etc/init.d/$s" ]; then
            rc-update add "$s" default >/dev/null
            rc-service "$s" restart
        fi
    done

    if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow from 192.168.0.0/16 to any port 3389 proto tcp comment 'Remote Desktop (LAN)' >/dev/null
        log "Firewall: portul 3389 e deschis doar pentru reteaua de acasa."
    fi
fi

# --- Rezumat ------------------------------------------------------------------
IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1)}')"
log "GATA!"
echo
if [ "$RDP" = 1 ]; then
    echo "  Din Windows: Start -> 'Remote Desktop Connection' (mstsc)"
    echo "    Computer:  ${IP:-<ip-mini-pc>}"
    echo "    Utilizator: $DESKTOP_USER   Parola: parola ta (cea de la doas)"
    echo "    La ecranul xrdp alegi Session: Xorg"
fi
echo "  Pe monitorul mini PC-ului: dupa restart apare ecranul de login grafic."
echo
warn "Nu fi logat in acelasi timp cu $DESKTOP_USER si pe monitor si prin Remote Desktop."
warn "Reporneste o data acum: doas reboot"
exit 0
