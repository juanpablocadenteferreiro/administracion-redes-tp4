# TP2 — Servidor Linux detrás de VPN (WireGuard + Docker)

**Administración de Sistemas y Redes · Segundo cuatrimestre · Entrega: 29/10/2026**

**Integrantes:** _<Nombre Apellido>_ · _<Nombre Apellido>_

Servidor Linux cuyos servicios (web, métricas y SSH de uso diario) son accesibles **únicamente a
través de una VPN WireGuard**. La interfaz pública solo expone WireGuard y un SSH de emergencia con
clave. Todo corre en contenedores Docker, se levanta solo al arrancar, tiene backups periódicos y
monitoreo en tiempo real.

```
  Internet / LAN
        │
        ▼
  ┌── interfaz pública ───────────────────────────────────────────────┐
  │   nftables, política DROP: solo entran                            │
  │     · UDP 51820  WireGuard                                        │
  │     · TCP 22     SSH de emergencia (solo clave, con límite)       │
  │   80 / 443 / 19999 bloqueados explícitamente                      │
  └───────────────────────────────────────────────────────────────────┘
        │  túnel WireGuard  (clientes 10.8.0.2, 10.8.0.3, …)
        ▼
  ┌── wg0  10.8.0.1/24 ───────────────────────────────────────────────┐
  │   :80     nginx    (contenedor)  /~usuario/ → /home/usuario/public_html
  │   :19999  Netdata  (contenedor)  CPU · RAM · disco · tráfico de wg0
  │   :22     SSH
  └───────────────────────────────────────────────────────────────────┘
  cron: backup de /home/* (rsync + hardlinks) cada hora · índice web cada 5 min
```

## Instalación rápida

En un Ubuntu Server 24.04 / Debian 12 recién instalado, con un usuario con `sudo` y **su clave SSH ya
cargada**:

```bash
git clone <URL-DEL-REPO> tp2 && cd tp2
cp setup.env.example setup.env        # opcional: editar usuarios, endpoint, etc.
sudo ./setup.sh
```

`setup.sh` es **idempotente**: se puede volver a correr y solo aplica lo que falta. Al terminar corre
`tp2-check.sh`, que verifica todos los requisitos.

> Define `WG_ENDPOINT` en `setup.env` con la IP/DNS por la que los clientes alcanzan al servidor. Si
> queda vacío se autodetecta la IP del servidor, que puede no servir detrás de NAT.

La guía manual, paso a paso y con la explicación de cada decisión, está en
**[`docs/INSTALACION.md`](docs/INSTALACION.md)**. El guion de la demo en vivo, en
**[`docs/DEMO.md`](docs/DEMO.md)**.

## Estructura del repositorio

```
.
├── setup.sh                      Aprovisionamiento automático e idempotente (bonus)
├── setup.env.example             Variables configurables
├── config/
│   ├── docker-compose.yml        nginx + netdata
│   ├── docker-daemon.json        logs de Docker acotados
│   ├── nginx/default.conf        /~usuario/, zona privada con auth básica
│   ├── netdata/netdata.conf.template
│   ├── nftables.conf.template    firewall
│   ├── ssh/00-tp2-hardening.conf
│   ├── sysctl/99-tp2.conf
│   ├── systemd/                  tp2-stack.service + drop-in de docker.service
│   ├── wireguard/wg0.conf.template
│   └── cron/tp2.template
├── scripts/
│   ├── backup-home.sh            backup incremental de /home/*
│   ├── restore-home.sh           restauración de archivos/carpetas
│   ├── genindex.sh               página principal con enlaces a los usuarios
│   ├── add-vpn-client.sh         alta de clientes WireGuard
│   └── tp2-check.sh              verificación de todos los requisitos
├── keys/                         claves públicas SSH de los usuarios (<usuario>.pub)
└── docs/                         INSTALACION.md · DEMO.md
```

## Cumplimiento de requisitos

| # | Requisito | Cómo se cumple | Dónde |
|---|---|---|---|
| 1 | Arranque y persistencia | `wg-quick@wg0`, `docker`, `nftables`, `cron` y `ssh` habilitados en systemd. Contenedores con `restart: unless-stopped` **y** unidad `tp2-stack.service`. Docker arranca después de `wg0` (drop-in). | `config/systemd/`, `docker-compose.yml` |
| 2 | Aislamiento y hardening | nftables con política `drop` en `input` y `forward`. Solo UDP 51820 y TCP 22 (limitado, con clave) por la interfaz pública; el resto solo por `wg0`. Bloqueo explícito de 80/443/19999 con contadores. | `config/nftables.conf.template`, `config/ssh/` |
| 3 | Contenerización | nginx y Netdata con Docker Compose. nginx publicado **solo** en la IP de la VPN (`10.8.0.1:80`); contenedor *read-only*, sin capacidades, usuario no-root. | `config/docker-compose.yml` |
| 4 | Autenticación | VPN y SSH con **pares de claves** (no hay contraseñas de SSH). Zona web privada con usuario/contraseña. | `wg0.conf`, `00-tp2-hardening.conf`, `htpasswd` |
| 5 | `public_html` | `/home` montado `:ro` en el contenedor; nginx mapea `/~usuario/` → `/home/usuario/public_html/`. Permisos del SO respetados. Raíz `/` con enlaces generados por `genindex.sh`. | `config/nginx/default.conf`, `scripts/genindex.sh` |
| 6 | Monitoreo | Netdata (CPU, memoria, disco, tráfico por interfaz incl. `wg0`), enlazado a `10.8.0.1:19999`. | `docker-compose.yml`, `netdata.conf.template` |
| 7 | Backup | cron cada hora → snapshots incrementales con rsync/hardlinks, retención de 14 días, `latest` siempre apunta al último. Restauración con `restore-home.sh` o copiando desde el snapshot. | `scripts/backup-home.sh`, `restore-home.sh` |
| ★ | Aprovisionamiento | `setup.sh` idempotente | `setup.sh` |
| ★ | Control de acceso web | HTTP basic auth sobre `/~usuario/privado/` (`.htpasswd`) | `default.conf` |

## Decisiones de diseño

- **Los puertos se publican en la IP de `wg0`, no en `0.0.0.0`.** Es la barrera principal: el servicio ni
  siquiera existe en la interfaz pública. El firewall es la segunda barrera (defensa en profundidad).
- **Docker y el firewall.** El tráfico hacia un puerto publicado no pasa por la cadena `input`: Docker
  hace DNAT y entra por `forward`. Por eso el firewall también filtra `forward` y solo deja que `wg0`
  inicie conexiones hacia los contenedores. Además la tabla `inet tp2` es propia y **no usa
  `flush ruleset`**, para no borrar las reglas que crea Docker.
- **Docker espera a la VPN.** Un drop-in de systemd hace que `docker.service` arranque *después* de
  `wg-quick@wg0`; si no, el *bind* a `10.8.0.1` falla en el arranque.
- **Netdata usa la red del host** (`network_mode: host`) para ver las interfaces reales, incluida
  `wg0`; se enlaza a la IP de la VPN desde su configuración y además lo bloquea el firewall. A
  propósito **no** se monta `docker.sock` (equivaldría a darle root del host).
- **Permisos de `public_html`.** El proceso nginx del contenedor (uid 101) es "otros" para el host. Con
  `chmod 711 ~` y `755 public_html` llega a lo público y a nada más; `~/.ssh` y los archivos `600`
  siguen privados. El nombre de usuario de la URL se valida con una regex estricta (sin `.` ni `/`),
  así que no se puede escapar de `public_html`.
- **SSH.** Solo claves, sin root, con límite de reintentos y de conexiones nuevas. El archivo de
  configuración se llama `00-…` porque sshd usa el *primer* valor leído y en Ubuntu
  `50-cloud-init.conf` habilita contraseñas. `setup.sh` **no** deshabilita las contraseñas si no hay
  ninguna clave instalada, para no dejar al administrador afuera.
- **Backups con `--link-dest`.** Cada corrida es una foto completa y navegable, pero lo que no cambió no
  ocupa espacio. Los snapshots conservan dueño y permisos, así que un usuario puede recuperar *sus*
  archivos sin pedir ayuda al administrador.

## Operación

```bash
sudo add-vpn-client.sh <nombre>                 # nuevo cliente VPN (genera <nombre>.conf + QR)
sudo ./setup.sh                                 # nuevo usuario: agregarlo a USERS en setup.env y correrlo
sudo restore-home.sh <usuario> <ruta> [snap]    # restaurar un archivo
sudo backup-home.sh                             # backup inmediato
sudo tp2-check.sh                               # verificar todo
sudo nft list table inet tp2                    # ver el firewall (con contadores)
cd /opt/tp2 && docker compose logs -f web       # logs del servidor web
```

Agregar otra credencial para la zona privada web:

```bash
printf 'maria:%s\n' "$(openssl passwd -apr1)" | sudo tee -a /opt/tp2/nginx/htpasswd
```

## Limitaciones conocidas

- El backup se guarda en el **mismo disco** que `/home`: protege contra borrados accidentales (el caso
  del enunciado), no contra la falla del disco. Para eso, apuntar `BACKUP_DEST` a un disco o montaje
  externo, o replicar `/var/backups/home` con `rsync` a otra máquina.
- El firewall restringe SSH por IPv4; el SSH público por IPv6 queda cerrado (política `drop`).
- Las imágenes usan los tags `stable`; para una instalación reproducible a largo plazo conviene fijar
  versiones exactas en `docker-compose.yml`.
- `htpasswd` usa el formato `apr1` (MD5 salteado) que soporta nginx de forma nativa; alcanza para este
  TP, pero en producción convendría `bcrypt` (`htpasswd -B`).

## Secretos

Nada sensible se sube al repositorio (ver `.gitignore`): las claves de WireGuard se generan **en el
servidor**, las contraseñas se generan al azar y quedan en `/root/tp2-credenciales.txt` (modo 600), y
de `keys/` solo se versionan claves **públicas**.
