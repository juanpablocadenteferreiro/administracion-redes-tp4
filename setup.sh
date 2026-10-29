#!/usr/bin/env bash
# =============================================================================
# TP2 - Administracion de Sistemas y Redes
# setup.sh - Aprovisionamiento automatico e IDEMPOTENTE del servidor (bonus)
#
# Deja el servidor completo: WireGuard, Docker (nginx + netdata), firewall nftables,
# SSH endurecido, usuarios con public_html, autenticacion basica, backups con cron y
# arranque automatico. Se puede correr varias veces: solo cambia lo que falta.
#
# Uso (Ubuntu Server 24.04 / Debian 12, desde un usuario con sudo):
#     cp setup.env.example setup.env      # opcional: ajustar variables
#     sudo ./setup.sh
# =============================================================================
set -euo pipefail
trap 'echo "ERROR: fallo en la linea $LINENO (comando: $BASH_COMMAND)" >&2' ERR

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$REPO_DIR/setup.env" ]; then
    # shellcheck disable=SC1091
    . "$REPO_DIR/setup.env"
fi

# ------------------------------ configuracion --------------------------------
VPN_PREFIX="${VPN_PREFIX:-10.8.0}"
VPN_IP="${VPN_PREFIX}.1"
WG_PORT="${WG_PORT:-51820}"
WG_ENDPOINT="${WG_ENDPOINT:-}"
VPN_CLIENTS="${VPN_CLIENTS:-cliente1}"
SSH_PORT=22
SSH_ALLOW_FROM="${SSH_ALLOW_FROM:-0.0.0.0/0}"
USERS="${USERS:-kakashi sakura}"
WEB_AUTH_USER="${WEB_AUTH_USER:-admin}"
WEB_AUTH_PASS="${WEB_AUTH_PASS:-}"
BACKUP_DEST="${BACKUP_DEST:-/var/backups/home}"
BACKUP_CRON="${BACKUP_CRON:-0 * * * *}"
BACKUP_KEEP_DAYS="${BACKUP_KEEP_DAYS:-14}"

STACK_DIR=/opt/tp2
WWW_DIR=/srv/tp2/www
CRED_FILE=/root/tp2-credenciales.txt
CHANGED=0

# ------------------------------- utilidades -----------------------------------
log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mAVISO:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# put <origen> <destino> [modo]: instala el archivo solo si cambio (deja CHANGED=1/0)
put() {
    local src="$1" dst="$2" mode="${3:-644}"
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        chmod "$mode" "$dst"
        CHANGED=0
    else
        install -D -m "$mode" "$src" "$dst"
        CHANGED=1
        echo "    actualizado: $dst"
    fi
}

# render_to <plantilla> <salida>: reemplaza los @PLACEHOLDERS@
render_to() {
    sed -e "s|@VPN_IP@|${VPN_IP}|g" \
        -e "s|@VPN_PREFIX@|${VPN_PREFIX}|g" \
        -e "s|@VPN_SUBNET@|${VPN_PREFIX}.0/24|g" \
        -e "s|@WG_PORT@|${WG_PORT}|g" \
        -e "s|@SSH_PORT@|${SSH_PORT}|g" \
        -e "s|@SSH_ALLOW_FROM@|${SSH_ALLOW_FROM}|g" \
        -e "s|@BACKUP_CRON@|${BACKUP_CRON}|g" \
        -e "s|@SERVER_PRIVATE_KEY@|${SERVER_PRIVATE_KEY:-}|g" \
        "$1" > "$2"
}

# render <plantilla> <destino> [modo]
render() {
    local tmp
    tmp="$(mktemp)"
    render_to "$1" "$tmp"
    put "$tmp" "$2" "${3:-644}"
    rm -f "$tmp"
}

ssh_service() {
    if systemctl cat ssh >/dev/null 2>&1; then echo ssh; else echo sshd; fi
}

# -------------------------------- pasos ---------------------------------------
preflight() {
    [ "$(id -u)" -eq 0 ] || die "ejecutar como root: sudo ./setup.sh"
    command -v apt-get >/dev/null || die "este script soporta Debian/Ubuntu (apt)"
    command -v systemctl >/dev/null || die "se necesita systemd"
    local u
    for u in $USERS; do
        [[ "$u" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "nombre de usuario invalido en USERS: '$u'"
    done
    [[ "$WG_PORT" =~ ^[0-9]+$ ]] || die "WG_PORT invalido"
    touch "$CRED_FILE"; chmod 600 "$CRED_FILE"
}

step_packages() {
    log "1/12 Paquetes base"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
        wireguard wireguard-tools nftables rsync cron openssl qrencode \
        curl ca-certificates gnupg iproute2 openssh-server >/dev/null
}

step_sysctl() {
    log "2/12 Parametros de kernel (sysctl)"
    put "$REPO_DIR/config/sysctl/99-tp2.conf" /etc/sysctl.d/99-tp2.conf 644
    sysctl --system >/dev/null
}

step_docker_install() {
    log "3/12 Docker + Compose"
    if docker compose version >/dev/null 2>&1; then
        echo "    Docker y Compose ya estan instalados"
        return
    fi
    export DEBIAN_FRONTEND=noninteractive
    # shellcheck disable=SC1091
    . /etc/os-release
    local codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    install -m 0755 -d /etc/apt/keyrings
    if [[ "${ID:-}" =~ ^(ubuntu|debian)$ && -n "$codename" ]] \
       && curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc; then
        chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${codename} stable" \
            > /etc/apt/sources.list.d/docker.list
        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
    else
        warn "no pude usar el repositorio oficial de Docker; instalo los paquetes de la distribucion"
        apt-get install -y -qq docker.io docker-compose-v2 >/dev/null || die "no se pudo instalar Docker"
    fi
}

step_env_and_scripts() {
    log "4/12 Configuracion compartida y scripts de administracion"
    local tmp
    tmp="$(mktemp)"
    # El formato ": ${VAR:=valor}" permite que una variable de entorno del llamador tenga prioridad
    {
        echo "# Generado por setup.sh - configuracion compartida por los scripts de TP2"
        echo ": \"\${VPN_IP:=${VPN_IP}}\""
        echo ": \"\${VPN_PREFIX:=${VPN_PREFIX}}\""
        echo ": \"\${WG_PORT:=${WG_PORT}}\""
        [ -n "$WG_ENDPOINT" ] && echo ": \"\${WG_ENDPOINT:=${WG_ENDPOINT}}\""
        echo ": \"\${SSH_PORT:=${SSH_PORT}}\""
        echo ": \"\${BACKUP_DEST:=${BACKUP_DEST}}\""
        echo ": \"\${BACKUP_KEEP_DAYS:=${BACKUP_KEEP_DAYS}}\""
    } > "$tmp"
    put "$tmp" /etc/tp2/tp2.env 644
    rm -f "$tmp"

    local s
    for s in backup-home.sh restore-home.sh genindex.sh add-vpn-client.sh tp2-check.sh; do
        put "$REPO_DIR/scripts/$s" "/usr/local/sbin/$s" 755
    done
}

ensure_user() {
    local u="$1" pw home grp
    if ! id "$u" >/dev/null 2>&1; then
        pw="$(openssl rand -base64 12)"
        useradd -m -s /bin/bash "$u"
        echo "$u:$pw" | chpasswd
        echo "usuario del sistema: $u   contrasena: $pw" >> "$CRED_FILE"
        echo "    usuario creado: $u"
    fi
    home="$(getent passwd "$u" | cut -d: -f6)"
    grp="$(id -gn "$u")"

    # Home 711: otros pueden "atravesarlo" (x) pero no listarlo; public_html 755 es lo unico visible.
    # Asi el proceso nginx del contenedor (uid 101) llega a public_html y a nada mas.
    chmod 711 "$home"
    install -d -m 755 -o "$u" -g "$grp" "$home/public_html" "$home/public_html/privado"

    if [ ! -e "$home/public_html/index.html" ]; then
        cat > "$home/public_html/index.html" <<HTML
<!doctype html><html lang="es"><meta charset="utf-8"><title>~$u</title>
<body style="font-family:system-ui;max-width:640px;margin:48px auto;padding:0 16px">
<h1>Pagina de $u</h1><p>Servida desde <code>/home/$u/public_html</code> dentro de un contenedor nginx.</p>
<ul><li><a href="bienvenida.txt">bienvenida.txt</a></li><li><a href="privado/">Zona privada</a> (pide usuario y contrasena)</li></ul>
</body></html>
HTML
        echo "Hola, soy $u. Este archivo esta en /home/$u/public_html/." > "$home/public_html/bienvenida.txt"
        echo "<!doctype html><meta charset=utf-8><h1>Zona privada de $u</h1><p>Si ves esto, la autenticacion HTTP basica funciona.</p>" > "$home/public_html/privado/index.html"
        chown "$u:$grp" "$home/public_html/index.html" "$home/public_html/bienvenida.txt" "$home/public_html/privado/index.html"
        chmod 644 "$home/public_html/index.html" "$home/public_html/bienvenida.txt" "$home/public_html/privado/index.html"
    fi

    # Clave publica SSH (keys/<usuario>.pub), si existe en el repo
    if [ -s "$REPO_DIR/keys/$u.pub" ]; then
        install -d -m 700 -o "$u" -g "$grp" "$home/.ssh"
        touch "$home/.ssh/authorized_keys"
        if ! grep -qxF "$(head -n1 "$REPO_DIR/keys/$u.pub")" "$home/.ssh/authorized_keys"; then
            cat "$REPO_DIR/keys/$u.pub" >> "$home/.ssh/authorized_keys"
            echo "    clave SSH instalada para $u"
        fi
        chown "$u:$grp" "$home/.ssh/authorized_keys"
        chmod 600 "$home/.ssh/authorized_keys"
    else
        warn "no hay keys/$u.pub: $u no podra entrar por SSH hasta que se agregue una clave publica"
    fi
}

step_users() {
    log "5/12 Usuarios y directorios public_html"
    local u
    for u in $USERS; do ensure_user "$u"; done
}

step_wireguard() {
    log "6/12 WireGuard (servidor y clientes)"
    install -d -m 700 /etc/wireguard /etc/wireguard/clients
    if [ ! -f /etc/wireguard/server_private.key ]; then
        ( umask 077; wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key )
        echo "    claves del servidor generadas"
    fi
    if [ ! -f /etc/wireguard/wg0.conf ]; then
        SERVER_PRIVATE_KEY="$(cat /etc/wireguard/server_private.key)"
        render "$REPO_DIR/config/wireguard/wg0.conf.template" /etc/wireguard/wg0.conf 600
        unset SERVER_PRIVATE_KEY
    else
        echo "    /etc/wireguard/wg0.conf ya existe (se conserva, tiene los peers)"
    fi
    systemctl enable --now wg-quick@wg0 >/dev/null 2>&1 || systemctl enable --now wg-quick@wg0
    ip link show wg0 >/dev/null 2>&1 || die "wg0 no levanto (revisar: journalctl -u wg-quick@wg0)"

    local c
    for c in $VPN_CLIENTS; do
        QR=0 /usr/local/sbin/add-vpn-client.sh "$c"
    done
}

step_docker_config() {
    log "7/12 Docker: log local y arranque despues de la VPN"
    local restart=0
    [ -f /etc/docker/daemon.json ] && [ ! -f /etc/docker/daemon.json.orig-tp2 ] && cp /etc/docker/daemon.json /etc/docker/daemon.json.orig-tp2
    put "$REPO_DIR/config/docker-daemon.json" /etc/docker/daemon.json 644
    [ "$CHANGED" -eq 1 ] && restart=1
    put "$REPO_DIR/config/systemd/docker-wg0.conf" /etc/systemd/system/docker.service.d/10-tp2-wg0.conf 644
    [ "$CHANGED" -eq 1 ] && restart=1
    systemctl daemon-reload
    systemctl enable docker >/dev/null 2>&1
    if [ "$restart" -eq 1 ] || ! systemctl is-active --quiet docker; then
        systemctl restart docker
    fi
}

step_stack_files() {
    log "8/12 Archivos del stack web + monitoreo (/opt/tp2)"
    install -d -m 755 "$STACK_DIR" "$STACK_DIR/nginx" "$STACK_DIR/netdata" "$WWW_DIR"
    put "$REPO_DIR/config/docker-compose.yml" "$STACK_DIR/docker-compose.yml" 644
    local tmp
    tmp="$(mktemp)"; echo "VPN_IP=${VPN_IP}" > "$tmp"; put "$tmp" "$STACK_DIR/.env" 644; rm -f "$tmp"
    put "$REPO_DIR/config/nginx/default.conf" "$STACK_DIR/nginx/default.conf" 644
    NGINX_CHANGED=$CHANGED
    render "$REPO_DIR/config/netdata/netdata.conf.template" "$STACK_DIR/netdata/netdata.conf" 644
    NETDATA_CHANGED=$CHANGED

    # Bonus: htpasswd (HTTP basic auth). Solo se crea si no existe, para no cambiar claves en cada corrida.
    if [ ! -f "$STACK_DIR/nginx/htpasswd" ]; then
        local pass="$WEB_AUTH_PASS"
        [ -n "$pass" ] || pass="$(openssl rand -base64 12)"
        printf '%s:%s\n' "$WEB_AUTH_USER" "$(printf '%s' "$pass" | openssl passwd -apr1 -stdin)" > "$STACK_DIR/nginx/htpasswd"
        chmod 644 "$STACK_DIR/nginx/htpasswd"
        echo "zona privada web (/~usuario/privado/):  usuario: $WEB_AUTH_USER   contrasena: $pass" >> "$CRED_FILE"
        echo "    htpasswd creado (usuario $WEB_AUTH_USER)"
    else
        echo "    htpasswd ya existe (se conserva)"
    fi
}

step_stack_up() {
    log "9/12 Levantando contenedores y habilitando arranque automatico"
    put "$REPO_DIR/config/systemd/tp2-stack.service" /etc/systemd/system/tp2-stack.service 644
    systemctl daemon-reload
    systemctl enable tp2-stack.service >/dev/null 2>&1
    ( cd "$STACK_DIR" && docker compose pull --quiet )
    systemctl start tp2-stack.service
    ( cd "$STACK_DIR" && docker compose up -d --remove-orphans )
    if [ "${NGINX_CHANGED:-0}" -eq 1 ]; then
        ( cd "$STACK_DIR" && docker compose exec -T web nginx -s reload ) || true
    fi
    if [ "${NETDATA_CHANGED:-0}" -eq 1 ]; then
        ( cd "$STACK_DIR" && docker compose restart netdata ) || true
    fi
}

step_firewall() {
    log "10/12 Firewall nftables"
    local tmp
    tmp="$(mktemp)"
    render_to "$REPO_DIR/config/nftables.conf.template" "$tmp"
    nft -c -f "$tmp" || die "la configuracion de nftables no es valida"
    if [ -f /etc/nftables.conf ] && [ ! -f /etc/nftables.conf.orig-tp2 ]; then
        cp /etc/nftables.conf /etc/nftables.conf.orig-tp2
    fi
    put "$tmp" /etc/nftables.conf 644
    rm -f "$tmp"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
        warn "ufw estaba activo: lo desactivo para que no pise las reglas de nftables"
        ufw --force disable >/dev/null
    fi
    # restart (y no "nft -f") para que la unidad quede "active": el servicio carga /etc/nftables.conf
    systemctl enable nftables >/dev/null 2>&1
    systemctl restart nftables
}

step_ssh() {
    log "11/12 SSH endurecido"
    local keys=0 f tmp svc
    for f in /home/*/.ssh/authorized_keys; do
        if [ -s "$f" ]; then keys=$((keys + 1)); fi
    done
    tmp="$(mktemp)"
    cp "$REPO_DIR/config/ssh/00-tp2-hardening.conf" "$tmp"
    if [ "$keys" -eq 0 ]; then
        warn "ningun usuario tiene clave SSH instalada: dejo PasswordAuthentication=yes para no dejarte afuera."
        warn "Agrega keys/<usuario>.pub (o ~/.ssh/authorized_keys) y volve a correr ./setup.sh."
        sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' "$tmp"
    fi
    install -d -m 755 /etc/ssh/sshd_config.d
    if ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
        cp -n /etc/ssh/sshd_config /etc/ssh/sshd_config.orig-tp2
        sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
    fi
    put "$tmp" /etc/ssh/sshd_config.d/00-tp2-hardening.conf 644
    rm -f "$tmp"
    mkdir -p /run/sshd
    if ! sshd -t; then
        rm -f /etc/ssh/sshd_config.d/00-tp2-hardening.conf
        die "sshd_config invalido; se revirtio el hardening"
    fi
    svc="$(ssh_service)"
    systemctl enable "$svc" >/dev/null 2>&1 || true
    systemctl reload-or-restart "$svc"
}

step_cron() {
    log "12/12 Tareas programadas (backup + indice web)"
    render "$REPO_DIR/config/cron/tp2.template" /etc/cron.d/tp2 644
    local lr
    lr="$(mktemp)"
    cat > "$lr" <<'EOF'
/var/log/tp2-backup.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
EOF
    put "$lr" /etc/logrotate.d/tp2 644
    rm -f "$lr"
    systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now crond >/dev/null 2>&1 || true
}

first_run() {
    log "Primera ejecucion de genindex y backup"
    /usr/local/sbin/genindex.sh
    /usr/local/sbin/backup-home.sh
}

summary() {
    local first_client endpoint
    first_client="$(echo "$VPN_CLIENTS" | awk '{print $1}')"
    endpoint="${WG_ENDPOINT:-<IP-publica-o-LAN-del-servidor>}"
    cat <<EOF

=============================================================================
 Listo. Servidor TP2 aprovisionado.
=============================================================================
 VPN        : wg0 = ${VPN_IP}/24   (UDP ${WG_PORT}, endpoint ${endpoint})
 Web        : http://${VPN_IP}/            (solo por VPN)
 Usuarios   : http://${VPN_IP}/~<usuario>/
 Metricas   : http://${VPN_IP}:19999/      (Netdata, solo por VPN)
 SSH        : ssh <usuario>@${VPN_IP}      (por VPN)  |  puerto 22 publico con clave

 Configuracion de los clientes VPN (importar en la app/cliente WireGuard):
$(for c in $VPN_CLIENTS; do echo "     sudo cat /etc/wireguard/clients/${c}.conf"; done)
   o con QR para el celular:  sudo qrencode -t ansiutf8 < /etc/wireguard/clients/${first_client}.conf

 Contrasenas generadas (usuarios del sistema y zona privada web):
     sudo cat ${CRED_FILE}

 Verificacion completa:   sudo tp2-check.sh
=============================================================================
EOF
}

# --------------------------------- main ---------------------------------------
preflight
step_packages
step_sysctl
step_docker_install
step_env_and_scripts
step_users
step_wireguard
step_docker_config
step_stack_files
step_stack_up
step_firewall
step_ssh
step_cron
first_run
summary
/usr/local/sbin/tp2-check.sh || warn "tp2-check.sh reporto fallas (revisar la salida de arriba)"
