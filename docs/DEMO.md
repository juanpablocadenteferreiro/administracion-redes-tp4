# Guion de la demostración

Sigue la lista de la consigna de entrega, en el mismo orden. Duración: 10–12 minutos.

Entorno (ver [`ENTORNO-VIRTUALBOX.md`](ENTORNO-VIRTUALBOX.md)):

| Máquina | Rol | Direcciones |
|---|---|---|
| VM `tp2-servidor` (VirtualBox, Ubuntu 24.04) | Servidor | `192.168.56.10` ("red pública") · `10.8.0.1` (VPN) |
| PC con Windows | Cliente / "otra computadora de la red" | `192.168.56.1` · `10.8.0.2` (VPN) |

Los comandos marcados **[Windows]** van en PowerShell en la PC. Los marcados **[servidor]** van en
una sesión SSH al servidor (`ssh juan@10.8.0.1`). En PowerShell usar `curl.exe` (no `curl`, que es
otro comando).

## Antes de empezar

- [ ] Prender la VM: en VirtualBox, `tp2-servidor` → **Start** (o
      `& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" startvm tp2-servidor --type headless`).
      Esperar ~1 minuto.
- [ ] En la app **WireGuard** de Windows, el túnel `pc-windows` aparece **Active**.
- [ ] **[Windows]** `ssh -t juan@10.8.0.1 sudo tp2-check.sh` → termina en `TODO OK`.
- [ ] Tener a mano las contraseñas (`C:\Users\juanp\VMs\tp2-credenciales.txt`, fuera del repo).

## 1. VPN levantada y un cliente conectado

**[servidor]**

```bash
ip -br addr show wg0          # wg0 con 10.8.0.1/24
sudo wg show                  # peer con allowed ips 10.8.0.2/32 y "latest handshake" reciente
sudo grep -A3 cliente /etc/wireguard/wg0.conf   # "# cliente: pc-windows" -> su clave publica
systemctl is-enabled wg-quick@wg0
```

En Windows, mostrar la app WireGuard: túnel `pc-windows` **Active**, con datos enviados/recibidos.
Explicar: cada cliente tiene su par de claves (la privada solo en el cliente, la pública en el
servidor). Altas con `sudo add-vpn-client.sh <nombre>`.

## 2. Servidor web en Docker

**[servidor]**

```bash
cat /opt/tp2/docker-compose.yml     # nginx + netdata, puerto publicado en ${VPN_IP}:80
cat /opt/tp2/.env                   # VPN_IP=10.8.0.1
sudo docker ps                      # tp2-web y tp2-netdata "Up (healthy)"
sudo docker port tp2-web            # 8080/tcp -> 10.8.0.1:80   (NO 0.0.0.0)
```

(Docker se usa con `sudo` a propósito: agregar al admin al grupo `docker` equivale a darle root
sin contraseña.)

Puntos a explicar:

- El puerto se publica **solo en la IP de la VPN**, no en `0.0.0.0`.
- `/home` se monta **de solo lectura** en el contenedor y nginx mapea `/~usuario/` →
  `/home/usuario/public_html/`.
- nginx corre como usuario no-root, con el sistema de archivos de solo lectura.
- `restart: unless-stopped` + el servicio `tp2-stack` levantan todo al arrancar.

## 3. La web solo funciona con la VPN levantada

En la app WireGuard: **Deactivate**. Después:

**[Windows]**

```powershell
curl.exe -m 5 http://10.8.0.1/                       # falla: sin VPN no hay ruta
Test-NetConnection 192.168.56.10 -Port 80            # TcpTestSucceeded : False  (bloqueado)
Test-NetConnection 192.168.56.10 -Port 19999         # False (métricas bloqueadas)
Test-NetConnection 192.168.56.10 -Port 22            # True: SSH de emergencia para el admin
```

Mostrar el firewall **[servidor]** (se puede entrar igual con `ssh juan@192.168.56.10`, el SSH de
emergencia):

```bash
sudo nft list table inet tp2        # policy drop; solo UDP 51820 y TCP 22 desde afuera
                                    # contadores de "web/metricas: solo por VPN" subiendo
```

Volver a **Activate** en WireGuard:

```powershell
curl.exe -I http://10.8.0.1/                         # HTTP/1.1 200 OK
```

Y en el navegador: `http://10.8.0.1/` (página principal con los usuarios) y
`http://10.8.0.1:19999/` (Netdata: CPU, RAM, disco y, en *Network*, el tráfico de `wg0`).

## 4. `public_html`: crear un archivo nuevo y que aparezca

**[servidor]**

```bash
sudo -u kakashi bash -c 'echo "Hola profe, archivo creado en vivo" > ~/public_html/en-vivo.txt'
ls -l /home/kakashi/public_html/
```

En el navegador: `http://10.8.0.1/~kakashi/` → aparece `en-vivo.txt` → abrirlo.

Permisos del sistema operativo:

```bash
sudo chmod 600 /home/kakashi/public_html/en-vivo.txt   # recargar el navegador -> 403 Forbidden
sudo chmod 644 /home/kakashi/public_html/en-vivo.txt   # recargar -> se ve de nuevo
```

**Bonus (auth básica):** `http://10.8.0.1/~kakashi/privado/` pide usuario y contraseña
(`admin` / la de `tp2-credenciales.txt`). Con una clave incorrecta da 401.

## 5. Acceso SSH del administrador con claves

**[Windows]**

```powershell
ssh juan@10.8.0.1                                        # entra con la clave, sin contraseña
ssh -o PubkeyAuthentication=no juan@10.8.0.1             # Permission denied (publickey)
```

**[servidor]**

```bash
sudo sshd -T | grep -E 'passwordauthentication|permitrootlogin|pubkeyauthentication'
cat ~/.ssh/authorized_keys          # clave pública de la PC; la privada está solo en Windows
```

## 6. Backup: script + crontab

**[servidor]**

```bash
cat /etc/cron.d/tp2                 # backup-home.sh cada 15 min, índice web cada 5 min
less /usr/local/sbin/backup-home.sh # rsync con --link-dest (snapshots incrementales)
ls -l /var/backups/home/            # snapshots fechados + "latest"
tail /var/log/tp2-backup.log        # corridas automáticas de cron (aparece tras la primera)
```

Restaurar un archivo borrado por accidente:

```bash
sudo backup-home.sh                                         # backup ahora (si no esperar al cron)
sudo rm /home/kakashi/public_html/en-vivo.txt               # "accidente" -> en el navegador: 404
sudo restore-home.sh kakashi public_html/en-vivo.txt        # recargar -> 200 de nuevo
```

## 7. Reinicio sin intervención manual

**[servidor]**

```bash
sudo reboot
```

Esperar ~1 minuto, **sin tocar nada** (WireGuard en Windows se reconecta solo). Después:

**[Windows]**

```powershell
ssh -t juan@10.8.0.1 sudo tp2-check.sh                    # todo [ OK ] -> "TODO OK"
```

Y recargar `http://10.8.0.1/` y Netdata en el navegador.

---

## Problemas frecuentes

| Síntoma | Causa probable | Solución |
|---|---|---|
| El túnel no conecta (sin *handshake*) | La VM está apagada o cambió su IP | Prender la VM; `ping 192.168.56.10` desde Windows |
| Los contenedores no levantan: `cannot assign requested address` | `wg0` no estaba arriba cuando arrancó Docker | `systemctl status wg-quick@wg0`; `sudo systemctl restart tp2-stack` |
| `403 Forbidden` en `/~usuario/` | Home o `public_html` sin permisos de paso | `chmod 711 /home/usuario && chmod 755 /home/usuario/public_html` |
| `404` en `/~usuario/` | Falta `public_html` o el usuario no existe | `ls -ld /home/usuario/public_html` |
| No entra por SSH | Falta la clave o se usa otro usuario | Usar `ssh juan@...`; la clave está en `%USERPROFILE%\.ssh\id_ed25519` |
| Cambié `default.conf` y no se refleja | nginx no recargó | `cd /opt/tp2 && docker compose exec web nginx -s reload` |
| Un usuario nuevo no aparece en el índice | El índice se regenera cada 5 min | `sudo genindex.sh` |
