# Instalación y configuración paso a paso

Guía manual y reproducible. Cada paso explica **qué** se hace y **por qué**, y termina con un
comando de verificación. El resultado es idéntico al que produce `sudo ./setup.sh` (que automatiza
exactamente estos pasos).

> Probado en Ubuntu Server 24.04 LTS. En Debian 12 funciona igual.

## 0. Preparación

**Requisitos**

- Una máquina (física o virtual) con Ubuntu Server 24.04, red con salida a Internet y un usuario
  con `sudo`.
- Una clave SSH ya instalada para ese usuario (el paso 10 deshabilita las contraseñas de SSH).
- Si es una VM, conviene red en modo *bridge*, así la PC cliente de la demo llega a la IP del servidor.

**Clonar el repositorio y definir variables** (todo desde una shell de root: `sudo -i`)

```bash
git clone https://github.com/juanpablocadenteferreiro/administracion-redes-tp4.git tp2 && cd tp2

export VPN_PREFIX=10.8.0            # red de la VPN: 10.8.0.0/24
export VPN_IP=${VPN_PREFIX}.1       # IP del servidor dentro de la VPN
export WG_PORT=51820                # puerto UDP de WireGuard
export WG_ENDPOINT=192.168.1.50     # IP/DNS por la que los clientes ven al servidor (¡poné la tuya!)
export BACKUP_DEST=/var/backups/home

# Helper: reemplaza los @PLACEHOLDERS@ de las plantillas
render() { sed -e "s|@VPN_IP@|$VPN_IP|g" -e "s|@VPN_PREFIX@|$VPN_PREFIX|g" \
               -e "s|@VPN_SUBNET@|$VPN_PREFIX.0/24|g" -e "s|@WG_PORT@|$WG_PORT|g" \
               -e "s|@SSH_PORT@|22|g" -e "s|@SSH_ALLOW_FROM@|0.0.0.0/0|g" \
               -e "s|@BACKUP_CRON@|0 * * * *|g" "$1"; }
```

## 1. Paquetes base

```bash
apt-get update
apt-get install -y --no-install-recommends wireguard wireguard-tools nftables rsync cron \
    openssl qrencode curl ca-certificates gnupg iproute2 openssh-server
```

## 2. Parámetros de kernel

Activa filtrado de ruta inversa, ignora redirecciones ICMP y usa SYN cookies.

```bash
install -m 644 config/sysctl/99-tp2.conf /etc/sysctl.d/99-tp2.conf
sysctl --system
```

## 3. Docker y Compose

```bash
. /etc/os-release                          # ID=ubuntu o debian, VERSION_CODENAME=noble, bookworm, ...
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/$ID/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/$ID $VERSION_CODENAME stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Verificación: `docker compose version`

## 4. Configuración compartida y scripts de administración

```bash
install -d /etc/tp2
cat > /etc/tp2/tp2.env <<EOF
: "\${VPN_IP:=$VPN_IP}"
: "\${VPN_PREFIX:=$VPN_PREFIX}"
: "\${WG_PORT:=$WG_PORT}"
: "\${WG_ENDPOINT:=$WG_ENDPOINT}"
: "\${SSH_PORT:=22}"
: "\${BACKUP_DEST:=$BACKUP_DEST}"
: "\${BACKUP_KEEP_DAYS:=14}"
EOF

install -m 755 scripts/*.sh /usr/local/sbin/
```

## 5. Usuarios y `public_html` (requisito 5)

Para cada usuario (ejemplo con `kakashi`):

```bash
useradd -m -s /bin/bash kakashi
passwd kakashi                         # contraseña de consola/su

chmod 711 /home/kakashi                # otros pueden "atravesar" el home, no listarlo
install -d -m 755 -o kakashi -g kakashi /home/kakashi/public_html /home/kakashi/public_html/privado
echo "Hola desde kakashi" > /home/kakashi/public_html/bienvenida.txt
echo "<h1>Zona privada</h1>" > /home/kakashi/public_html/privado/index.html
chown -R kakashi:kakashi /home/kakashi/public_html
```

> **Por qué 711 / 755.** El nginx del contenedor corre como el usuario `uid 101`, que para el host es
> "otros". Con el home en `711` puede *atravesarlo* pero no listarlo, y solo llega a lo que esté
> dentro de `public_html` (`755`). `~/.ssh` (700) y cualquier archivo `600` siguen siendo privados.
> Ubuntu crea los homes en `750`, y sin este `chmod` nginx devolvería `403`.

Clave pública SSH del usuario (generada en **su** computadora con `ssh-keygen -t ed25519`):

```bash
install -d -m 700 -o kakashi -g kakashi /home/kakashi/.ssh
cat keys/kakashi.pub >> /home/kakashi/.ssh/authorized_keys
chown kakashi:kakashi /home/kakashi/.ssh/authorized_keys && chmod 600 /home/kakashi/.ssh/authorized_keys
```

## 6. WireGuard (requisitos 2 y 4)

```bash
install -d -m 700 /etc/wireguard /etc/wireguard/clients
( umask 077; wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key )

SERVER_PRIVATE_KEY=$(cat /etc/wireguard/server_private.key)
render config/wireguard/wg0.conf.template | sed "s|@SERVER_PRIVATE_KEY@|$SERVER_PRIVATE_KEY|" \
    > /etc/wireguard/wg0.conf
chmod 600 /etc/wireguard/wg0.conf

systemctl enable --now wg-quick@wg0        # levanta wg0 ahora y en cada arranque
```

Alta de clientes (un par de claves por cliente; la privada queda solo en el archivo del cliente):

```bash
add-vpn-client.sh cliente1
add-vpn-client.sh cliente2
```

Verificación: `ip -4 addr show wg0` (debe mostrar `10.8.0.1/24`) y `wg show`.

## 7. Docker: guardar logs y esperar a la VPN (requisito 1)

Los contenedores publican sus puertos en la IP de `wg0`. Si Docker arrancara antes que el túnel, el
*bind* fallaría. El *drop-in* hace que Docker espere a `wg-quick@wg0`.

```bash
install -m 644 config/docker-daemon.json /etc/docker/daemon.json
install -D -m 644 config/systemd/docker-wg0.conf /etc/systemd/system/docker.service.d/10-tp2-wg0.conf
systemctl daemon-reload
systemctl enable docker
systemctl restart docker
```

## 8. Stack de contenedores (requisitos 3, 5, 6 y bonus)

```bash
install -d /opt/tp2/nginx /opt/tp2/netdata /srv/tp2/www
install -m 644 config/docker-compose.yml /opt/tp2/docker-compose.yml
echo "VPN_IP=$VPN_IP" > /opt/tp2/.env
install -m 644 config/nginx/default.conf /opt/tp2/nginx/default.conf
render config/netdata/netdata.conf.template > /opt/tp2/netdata/netdata.conf

# Bonus: usuario/contraseña para /~usuario/privado/
printf 'admin:%s\n' "$(openssl passwd -apr1)" > /opt/tp2/nginx/htpasswd   # pide la contraseña dos veces
chmod 644 /opt/tp2/nginx/htpasswd

# Página principal con enlaces a los usuarios
genindex.sh
```

Servicio de systemd que levanta el stack en cada arranque (además de `restart: unless-stopped`):

```bash
install -m 644 config/systemd/tp2-stack.service /etc/systemd/system/tp2-stack.service
systemctl daemon-reload
( cd /opt/tp2 && docker compose pull )
systemctl enable --now tp2-stack.service
```

Verificación:

```bash
docker ps                                   # tp2-web y tp2-netdata "Up"
docker port tp2-web 8080/tcp                # -> 10.8.0.1:80   (NO 0.0.0.0)
ss -tln | grep -E ':(80|19999)\b'           # solo 10.8.0.1, jamás 0.0.0.0 ni *
curl -I http://$VPN_IP/                     # 200
```

## 9. Firewall nftables (requisito 2)

```bash
cp /etc/nftables.conf /etc/nftables.conf.orig 2>/dev/null || true
render config/nftables.conf.template > /etc/nftables.conf
nft -c -f /etc/nftables.conf               # valida la sintaxis sin aplicar
ufw status 2>/dev/null | grep -q active && ufw disable    # que no pise a nftables
systemctl enable nftables                  # la carga en cada arranque
systemctl restart nftables                 # la aplica ahora (y la unidad queda "active")
```

Qué hace (detalle en el archivo, comentado línea por línea):

- `input` y `forward` con **política `drop`**.
- Por la interfaz pública solo entran **UDP 51820** (WireGuard) y **TCP 22** (SSH, limitado a 10
  conexiones nuevas por minuto). Opcionalmente se restringe el origen con `SSH_ALLOW_FROM`.
- Todo lo que llega por **`wg0`** está permitido.
- Reglas **explícitas con contador** que bloquean 80, 443 y 19999 fuera de la VPN.
- `forward`: solo `wg0` puede iniciar conexiones hacia los contenedores (Docker hace DNAT y el
  tráfico pasa por `forward`, no por `input`).
- No usa `flush ruleset`: vive en su propia tabla `inet tp2` para no borrar las reglas de Docker.

Verificación: `nft list table inet tp2`

## 10. SSH endurecido (requisitos 2 y 4)

> ⚠️ **Antes de seguir**, abrí **otra** sesión SSH con tu clave y comprobá que entrás. Si no tenés
> clave instalada, no hagas este paso: te quedarías afuera.

```bash
install -m 644 config/ssh/00-tp2-hardening.conf /etc/ssh/sshd_config.d/00-tp2-hardening.conf
grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config \
    || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
sshd -t && systemctl reload-or-restart ssh
```

El archivo se llama `00-…` a propósito: sshd toma el **primer** valor que lee, y en Ubuntu
`50-cloud-init.conf` trae `PasswordAuthentication yes`.

Verificación: `sshd -T | grep -E 'passwordauthentication|permitrootlogin|pubkeyauthentication'`

## 11. Backups periódicos (requisito 7)

```bash
render config/cron/tp2.template > /etc/cron.d/tp2        # backup cada hora + índice web cada 5 min
systemctl enable --now cron
backup-home.sh                                           # primer backup, para tener un "latest"
```

`backup-home.sh` genera snapshots incrementales con `rsync --link-dest` en
`/var/backups/home/AAAA-MM-DD_HHMMSS/` y mantiene el enlace `latest`. Los archivos sin cambios son
*hardlinks* (no ocupan espacio extra) y se conservan 14 días.

**Restaurar un archivo borrado** (como admin):

```bash
restore-home.sh -l                                       # lista los snapshots
restore-home.sh kakashi public_html/bienvenida.txt       # desde el último backup
restore-home.sh kakashi Documentos 2026-10-29_140001     # una carpeta, de un snapshot puntual
```

O el propio usuario, sin admin (los snapshots conservan dueño y permisos):

```bash
cp /var/backups/home/latest/$USER/public_html/bienvenida.txt ~/public_html/
```

## 12. Verificación final y prueba de reinicio (requisito 1)

```bash
tp2-check.sh        # chequea arranque, VPN, firewall, puertos, SSH, web y backup
reboot
```

Al volver (sin tocar nada) hay que reconectar la VPN desde el cliente y correr de nuevo
`sudo tp2-check.sh`. Todo debe seguir en verde.

## 13. Configurar un cliente VPN

En el servidor, obtener el archivo del cliente (contiene su clave privada: tratarlo como secreto):

```bash
sudo cat /etc/wireguard/clients/cliente1.conf
sudo qrencode -t ansiutf8 < /etc/wireguard/clients/cliente1.conf     # QR para celular
```

| Cliente | Cómo importar |
|---|---|
| Windows / macOS | App *WireGuard* → *Import tunnel(s) from file* → **Activate** |
| Linux | `sudo apt install wireguard` y `sudo wg-quick up ./cliente1.conf` |
| Android / iOS | App *WireGuard* → **+** → *Scan from QR code* |

Con el túnel activo: `ping 10.8.0.1` y abrir `http://10.8.0.1/`.
