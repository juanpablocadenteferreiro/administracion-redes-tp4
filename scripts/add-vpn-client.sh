#!/usr/bin/env bash
# =============================================================================
# add-vpn-client.sh - Da de alta un cliente WireGuard
#
# Uso:  sudo add-vpn-client.sh <nombre>
#
#  - genera el par de claves del cliente (+ clave precompartida) y le asigna la
#    siguiente IP libre de la VPN (10.8.0.2, 10.8.0.3, ...)
#  - agrega el [Peer] a /etc/wireguard/wg0.conf y lo aplica sin cortar el tunel
#  - deja el archivo listo para importar en /etc/wireguard/clients/<nombre>.conf
#    (y muestra un QR para celulares si esta instalado qrencode)
#
# Es idempotente: si el cliente ya existe, no lo vuelve a crear.
# Variables opcionales: WG_ENDPOINT (IP o DNS publico del servidor), QR=0 (sin QR)
# =============================================================================
set -euo pipefail

[ -f /etc/tp2/tp2.env ] && . /etc/tp2/tp2.env
WG_DIR="${WG_DIR:-/etc/wireguard}"
VPN_PREFIX="${VPN_PREFIX:-10.8.0}"
WG_PORT="${WG_PORT:-51820}"

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "ejecutar como root (sudo)"
name="${1:-}"
[[ "$name" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || die "uso: $0 <nombre>   (letras, numeros, - y _)"
command -v wg >/dev/null || die "falta wireguard-tools"

conf="$WG_DIR/wg0.conf"
client_conf="$WG_DIR/clients/$name.conf"
[ -f "$conf" ] || die "no existe $conf (primero hay que configurar el servidor)"
[ -f "$WG_DIR/server_private.key" ] || die "falta $WG_DIR/server_private.key"

show_result() {
    echo "Cliente '$name' listo: $client_conf"
    if [ "${QR:-1}" != "0" ] && [ -t 1 ] && command -v qrencode >/dev/null; then
        echo "QR para la app de WireGuard (celular):"
        qrencode -t ansiutf8 < "$client_conf"
    fi
}

if [ -f "$client_conf" ]; then
    echo "El cliente '$name' ya existe; no se modifica."
    show_result
    exit 0
fi

# Siguiente IP libre
used="$(grep -oP 'AllowedIPs\s*=\s*\K[0-9.]+(?=/32)' "$conf" || true)"
ip=""
for n in $(seq 2 254); do
    if ! grep -qx "${VPN_PREFIX}.${n}" <<<"$used"; then ip="${VPN_PREFIX}.${n}"; break; fi
done
[ -n "$ip" ] || die "no quedan IPs libres en ${VPN_PREFIX}.0/24"

# Endpoint publico del servidor: variable, o la IP con la que sale a Internet
endpoint="${WG_ENDPOINT:-}"
if [ -z "$endpoint" ]; then
    endpoint="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)"
    echo "AVISO: WG_ENDPOINT no definido; uso la IP detectada ($endpoint). Si el servidor esta detras de NAT, definir WG_ENDPOINT en /etc/tp2/tp2.env" >&2
fi
[ -n "$endpoint" ] || die "no pude determinar el endpoint; definir WG_ENDPOINT"

umask 077
install -d -m 700 "$WG_DIR/clients"
priv="$(wg genkey)"
pub="$(printf '%s' "$priv" | wg pubkey)"
psk="$(wg genpsk)"
server_pub="$(wg pubkey < "$WG_DIR/server_private.key")"

# Peer en el servidor
cat >> "$conf" <<EOF

# cliente: $name
[Peer]
PublicKey = $pub
PresharedKey = $psk
AllowedIPs = $ip/32
EOF

# Archivo del cliente (split tunnel: solo el trafico hacia la red de la VPN pasa por el tunel)
cat > "$client_conf" <<EOF
[Interface]
PrivateKey = $priv
Address = $ip/32

[Peer]
PublicKey = $server_pub
PresharedKey = $psk
Endpoint = $endpoint:$WG_PORT
AllowedIPs = ${VPN_PREFIX}.0/24
PersistentKeepalive = 25
EOF
chmod 600 "$client_conf"

# Aplica el cambio en caliente si el tunel esta levantado
if ip link show wg0 >/dev/null 2>&1; then
    wg syncconf wg0 <(wg-quick strip wg0)
fi

echo "Asignada la IP $ip al cliente '$name'"
show_result
