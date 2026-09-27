#!/bin/sh
# Pasul 2 dupa setup-ssh.sh: configurare de baza + Docker + interfata web.
#
# Utilizare (ca root sau cu doas):
#   doas sh setup-server.sh
#
# Variabile (toate optionale):
#   TZ_NAME     fusul orar (implicit Europe/Bucharest)
#   DOCKER_USER utilizatorul adaugat in grupul docker (implicit cel care a rulat doas)
#   PORTAINER   1 = porneste interfata web Portainer pe https://IP:9443 (implicit 1)
#   DESKTOP     xfce / gnome / plasma / mate / sway = instaleaza si o interfata grafica
#               pe monitorul mini PC-ului (implicit: nimic)

set -eu

TZ_NAME="${TZ_NAME:-Europe/Bucharest}"
DOCKER_USER="${DOCKER_USER:-${DOAS_USER:-${SUDO_USER:-}}}"
PORTAINER="${PORTAINER:-1}"
DESKTOP="${DESKTOP:-}"

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mEROARE:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Ruleaza cu doas: doas sh setup-server.sh"
[ -f /etc/alpine-release ] || die "Scriptul este doar pentru Alpine Linux."
grep -Eq '^[^#].*/community/?$' /etc/apk/repositories || \
    die "Repository-ul community nu este activ - ruleaza intai setup-ssh.sh."

log "Actualizez pachetele"
apk update
apk upgrade

# --- Sistem de baza ---------------------------------------------------------
log "Instalez utilitare de baza"
apk add tzdata chrony bash curl nano htop ca-certificates

log "Fus orar: $TZ_NAME"
[ -f "/usr/share/zoneinfo/$TZ_NAME" ] || die "Fus orar necunoscut: $TZ_NAME"
cp "/usr/share/zoneinfo/$TZ_NAME" /etc/localtime
echo "$TZ_NAME" > /etc/timezone

log "Sincronizare ora (chrony)"
rc-update add chronyd default >/dev/null
rc-service chronyd restart

# --- Docker -----------------------------------------------------------------
log "Instalez Docker"
apk add docker docker-cli-compose
rc-update add docker default >/dev/null
rc-service docker start

i=0
until docker info >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -le 30 ] || die "Docker nu a pornit - vezi /var/log/docker.log"
    sleep 1
done

if [ -n "$DOCKER_USER" ] && [ "$DOCKER_USER" != root ]; then
    log "Adaug $DOCKER_USER in grupul docker"
    addgroup "$DOCKER_USER" docker
fi

# --- Portainer (interfata web) ----------------------------------------------
if [ "$PORTAINER" = 1 ]; then
    if docker ps -a --format '{{.Names}}' | grep -qx portainer; then
        log "Portainer exista deja - il actualizez"
        docker rm -f portainer >/dev/null
    else
        log "Instalez Portainer"
    fi
    docker pull portainer/portainer-ce:lts
    docker run -d \
        --name portainer \
        --restart=always \
        -p 9443:9443 \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v portainer_data:/data \
        portainer/portainer-ce:lts >/dev/null
    if command -v ufw >/dev/null; then
        ufw allow 9443/tcp comment 'Portainer' >/dev/null
    fi
fi

# --- Interfata grafica pe monitor (optional) --------------------------------
if [ -n "$DESKTOP" ]; then
    command -v setup-desktop >/dev/null || apk add alpine-conf
    log "Instalez interfata grafica: $DESKTOP"
    setup-desktop "$DESKTOP"
fi

IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1)}')"
log "Gata!"
echo
echo "  Ora:        $(date)"
echo "  Docker:     $(docker --version)"
if [ "$PORTAINER" = 1 ]; then
    echo "  Interfata:  https://${IP:-<ip-mini-pc>}:9443"
    echo
    warn "Deschide interfata in 5 minute si creeaza contul de admin."
    warn "Daca expira: doas docker restart portainer"
    warn "Browserul va avertiza de certificat (e auto-semnat) - alege 'Continua'."
fi
[ -n "$DOCKER_USER" ] && echo "  Delogheaza-te si logheaza-te din nou ca $DOCKER_USER sa poti folosi docker fara doas."
[ -n "$DESKTOP" ] && echo "  Reporneste (doas reboot) ca sa apara interfata grafica pe monitor."
exit 0
