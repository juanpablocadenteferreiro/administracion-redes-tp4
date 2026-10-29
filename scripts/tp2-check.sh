#!/usr/bin/env bash
# =============================================================================
# tp2-check.sh - Verifica en el propio servidor que se cumplen los requisitos del TP.
# Uso:  sudo tp2-check.sh
# Util para correr antes de la demo y despues de reiniciar el servidor.
# =============================================================================
set -uo pipefail

[ -f /etc/tp2/tp2.env ] && . /etc/tp2/tp2.env
VPN_IP="${VPN_IP:-10.8.0.1}"
BACKUP_DEST="${BACKUP_DEST:-/var/backups/home}"
FAILS=0

ok()    { printf '  \033[32m[ OK  ]\033[0m %s\n' "$*"; }
bad()   { printf '  \033[31m[FALLA]\033[0m %s\n' "$*"; FAILS=$((FAILS + 1)); }
info()  { printf '  \033[36m[ i   ]\033[0m %s\n' "$*"; }
title() { printf '\n== %s ==\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "Ejecutar con sudo (hace falta para leer nftables y sshd)"; exit 1; }

ssh_svc=ssh
systemctl cat ssh >/dev/null 2>&1 || ssh_svc=sshd

title "1. Arranque automatico"
for svc in wg-quick@wg0 docker nftables cron "$ssh_svc" tp2-stack; do
    # Ubuntu 24.04 arranca sshd por socket activation (ssh.socket): se acepta service o socket
    units=("$svc")
    [ "$svc" = "$ssh_svc" ] && units+=("${ssh_svc}.socket")
    en=1; ac=1
    for u in "${units[@]}"; do
        systemctl is-enabled --quiet "$u" 2>/dev/null && en=0
        systemctl is-active  --quiet "$u" 2>/dev/null && ac=0
    done
    if [ "$en" -eq 0 ]; then ok "$svc habilitado en el arranque"; else bad "$svc NO esta habilitado en el arranque"; fi
    if [ "$ac" -eq 0 ]; then ok "$svc activo";                    else bad "$svc NO esta activo"; fi
done
for c in tp2-web tp2-netdata; do
    [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = "true" ] && ok "contenedor $c en ejecucion" || bad "contenedor $c no esta corriendo"
    [ "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$c" 2>/dev/null)" = "unless-stopped" ] && ok "$c: restart policy = unless-stopped" || bad "$c: sin restart policy unless-stopped"
done

title "2. VPN (WireGuard)"
if ip -4 addr show wg0 2>/dev/null | grep -q "inet ${VPN_IP}/"; then ok "wg0 levantada con ${VPN_IP}"; else bad "wg0 no tiene la IP ${VPN_IP}"; fi
peers="$(wg show wg0 peers 2>/dev/null | wc -l)"
info "peers configurados: ${peers}"
if wg show wg0 latest-handshakes 2>/dev/null | awk '$2 > 0 {f=1} END {exit !f}'; then ok "hay al menos un cliente que hizo handshake"; else info "ningun cliente conectado todavia"; fi

title "3. Firewall e aislamiento de red"
nft list table inet tp2 >/dev/null 2>&1 && ok "tabla nftables 'inet tp2' cargada" || bad "no esta cargada la tabla 'inet tp2'"
# Se guarda la salida en una variable: con "nft ... | grep -q" y pipefail, grep corta antes y nft
# termina con SIGPIPE (141), lo que daria una falla falsa.
chain_in="$(nft list chain inet tp2 input 2>/dev/null)"
chain_fw="$(nft list chain inet tp2 forward 2>/dev/null)"
grep -q 'policy drop' <<<"$chain_in" && ok "INPUT con politica drop"   || bad "INPUT sin politica drop"
grep -q 'policy drop' <<<"$chain_fw" && ok "FORWARD con politica drop" || bad "FORWARD sin politica drop"
web_bind="$(docker port tp2-web 8080/tcp 2>/dev/null | head -n1)"
if [ "$web_bind" = "${VPN_IP}:80" ]; then ok "web publicada solo en ${VPN_IP}:80"; else bad "web publicada en '${web_bind:-nada}' (esperado ${VPN_IP}:80)"; fi
listen="$(ss -H -tln 2>/dev/null | awk '{print $4}')"
if grep -qx "${VPN_IP}:19999" <<<"$listen"; then ok "netdata escucha solo en ${VPN_IP}:19999"; else bad "netdata no escucha en ${VPN_IP}:19999"; fi
for p in 80 19999; do
    if grep -qE "^(0\.0\.0\.0|\*|\[::\]):${p}\$" <<<"$listen"; then bad "el puerto $p escucha en TODAS las interfaces"; else ok "el puerto $p no escucha en interfaces publicas"; fi
done
info "sockets TCP/UDP en escucha:"; ss -H -tulnp 2>/dev/null | awk '{printf "        %-5s %-26s %s\n", $1, $5, $7}'

title "4. SSH"
sshd_t="$(sshd -T 2>/dev/null)"
grep -qx 'passwordauthentication no' <<<"$sshd_t" && ok "PasswordAuthentication no (solo claves)" || bad "PasswordAuthentication sigue habilitado (agregar una clave publica y volver a correr setup.sh)"
grep -qx 'permitrootlogin no'        <<<"$sshd_t" && ok "PermitRootLogin no"                      || bad "PermitRootLogin habilitado"
grep -qx 'pubkeyauthentication yes'  <<<"$sshd_t" && ok "PubkeyAuthentication yes"                || bad "PubkeyAuthentication deshabilitado"

title "5. Servicios web (desde el propio servidor, por la IP de la VPN)"
code() { curl -s -o /dev/null -m 5 -w '%{http_code}' "$1" 2>/dev/null || echo 000; }
c="$(code "http://${VPN_IP}/")";                         [ "$c" = "200" ] && ok "GET /  -> 200"                       || bad "GET / -> $c"
first_user="$(for d in /home/*/public_html; do [ -d "$d" ] && basename "$(dirname "$d")" && break; done)"
if [ -n "${first_user:-}" ]; then
    c="$(code "http://${VPN_IP}/~${first_user}/")";      [ "$c" = "200" ] && ok "GET /~${first_user}/ -> 200"           || bad "GET /~${first_user}/ -> $c"
    c="$(code "http://${VPN_IP}/~${first_user}/privado/")"; [ "$c" = "401" ] && ok "GET /~${first_user}/privado/ sin credenciales -> 401 (auth basica)" || info "GET /~${first_user}/privado/ -> $c (existe la carpeta privado?)"
else
    info "no hay usuarios con public_html para probar /~usuario/"
fi
c="$(code "http://${VPN_IP}:19999/")";                   [[ "$c" =~ ^(200|301|302)$ ]] && ok "Netdata :19999 -> $c" || bad "Netdata :19999 -> $c"

title "6. Backup"
if [ -L "${BACKUP_DEST}/latest" ] && [ -d "$(readlink -f "${BACKUP_DEST}/latest")" ]; then
    ok "existe el backup mas reciente: $(basename "$(readlink -f "${BACKUP_DEST}/latest")")"
else
    bad "todavia no hay backup (correr: sudo backup-home.sh)"
fi
grep -q 'backup-home.sh' /etc/cron.d/tp2 2>/dev/null && ok "tarea cron del backup instalada (/etc/cron.d/tp2)" || bad "falta la tarea cron del backup"

echo
if [ "$FAILS" -eq 0 ]; then
    printf '\033[32mTODO OK\033[0m - el servidor cumple los chequeos.\n'
else
    printf '\033[31m%d chequeo(s) con falla.\033[0m\n' "$FAILS"
    exit 1
fi
