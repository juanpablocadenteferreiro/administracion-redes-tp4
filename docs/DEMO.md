# Guion de demostración en vivo

Duración estimada: 10–12 minutos. Se necesitan **dos máquinas**: el servidor y otra computadora
(la "cliente") en la misma red, con la app WireGuard y un navegador.

## Antes de empezar (5 minutos antes)

- [ ] En el servidor: `sudo tp2-check.sh` → todo en verde.
- [ ] En el cliente: el archivo `cliente1.conf` importado en WireGuard (túnel **desactivado**).
- [ ] Clave SSH del cliente instalada en el servidor (`keys/<usuario>.pub` + `setup.sh`).
- [ ] Un par de archivos de ejemplo en `~/public_html` de un usuario (una imagen, por ejemplo).
- [ ] Terminal abierta en el servidor: `sudo watch -n1 'nft list chain inet tp2 input | grep counter'`
      (para ver subir los contadores del firewall durante el punto 2).

## 1. Arranque automático (requisito 1)

En el servidor:

```bash
systemctl is-enabled wg-quick@wg0 docker nftables cron tp2-stack
docker inspect -f '{{.Name}} -> {{.HostConfig.RestartPolicy.Name}}' tp2-web tp2-netdata
```

Y la prueba definitiva, que se deja corriendo mientras se explica lo demás:

```bash
sudo reboot
```

## 2. Aislamiento y firewall (requisito 2) — *sin VPN*

Con el túnel **desactivado** en el cliente, desde el cliente:

```bash
nmap -Pn -p 22,80,443,19999 <IP-DEL-SERVIDOR>        # 22 open · 80/443/19999 filtered
nmap -Pn -sU -p 51820 <IP-DEL-SERVIDOR>              # open|filtered (WireGuard no responde sin clave)
curl -m 5 http://<IP-DEL-SERVIDOR>/                  # timeout
curl -m 5 http://<IP-DEL-SERVIDOR>:19999/            # timeout
```

En el servidor se ve cómo suben los contadores de las reglas `web/metricas: solo por VPN`.
Mostrar el conjunto de reglas: `sudo nft list table inet tp2`.

Mostrar que los puertos están enlazados solo a la VPN:

```bash
docker port tp2-web 8080/tcp          # 10.8.0.1:80
sudo ss -tlnp | grep -E ':(80|19999)\b'
```

## 3. Conexión VPN (requisito 4)

Activar el túnel en el cliente y verificar:

```bash
ping 10.8.0.1
```

En el servidor: `sudo wg show` → aparece el peer con *latest handshake* reciente.

## 4. Servicios web por la VPN (requisitos 3 y 5)

En el navegador del cliente:

1. `http://10.8.0.1/` → página principal con enlaces a cada usuario.
2. Click en `/~kakashi/` → su página. Abrir un archivo, por ejemplo `http://10.8.0.1/~kakashi/naruto-run.jpg`.
3. Mostrar de dónde sale: en el servidor, `ls -l /home/kakashi/public_html/` y
   `docker inspect tp2-web | grep -A3 /home` (volumen `/home:/home:ro`).
4. **Permisos del SO**: `sudo chmod 600 /home/kakashi/public_html/<archivo>` → recargar → `403`;
   volver a `644`.
5. **Bonus**: `http://10.8.0.1/~kakashi/privado/` → pide usuario y contraseña (`admin` / la de
   `/root/tp2-credenciales.txt`). Probar una clave incorrecta (401) y la correcta (200).

## 5. Monitoreo (requisito 6)

`http://10.8.0.1:19999/` → Netdata. Mostrar:

- **CPU**, **RAM** y **Disk** en el panel principal.
- Sección **Network Interfaces → wg0**: generar tráfico (recargar páginas, descargar un archivo
  grande) y mostrar el gráfico de `wg0` subiendo.

## 6. SSH (requisitos 2 y 4)

Desde el cliente, con la VPN activa:

```bash
ssh kakashi@10.8.0.1                 # entra con clave, sin contraseña
```

Mostrar que las contraseñas están deshabilitadas:

```bash
ssh -o PubkeyAuthentication=no kakashi@10.8.0.1       # Permission denied (publickey)
```

Y en el servidor: `sudo sshd -T | grep -E 'passwordauth|permitroot'`.

## 7. Backup y restauración (requisito 7)

En el servidor (o por SSH como `kakashi`):

```bash
sudo backup-home.sh                                   # fuerza un backup ahora
ls -l /var/backups/home/                              # snapshots + latest

sudo rm ~kakashi/public_html/naruto-run.jpg           # "accidente" (sin sudo si se esta logueado como kakashi)
curl -I http://10.8.0.1/~kakashi/naruto-run.jpg       # 404

sudo restore-home.sh kakashi public_html/naruto-run.jpg
curl -I http://10.8.0.1/~kakashi/naruto-run.jpg       # 200 otra vez
```

Mostrar la tarea programada: `cat /etc/cron.d/tp2`.

## 8. Después del reinicio (cierre del punto 1)

Cuando el servidor termine de arrancar, **sin haber tocado nada**:

```bash
sudo tp2-check.sh                     # todo OK
```

Reconectar el túnel en el cliente y recargar `http://10.8.0.1/` y el panel de Netdata.

---

## Problemas frecuentes

| Síntoma | Causa probable | Solución |
|---|---|---|
| Los contenedores no levantan: `cannot assign requested address` | `wg0` no estaba arriba cuando arrancó Docker | `systemctl status wg-quick@wg0`; revisar el drop-in `docker.service.d/10-tp2-wg0.conf` y `systemctl restart tp2-stack` |
| El cliente no conecta (sin *handshake*) | Endpoint incorrecto o UDP 51820 bloqueado/no redirigido | Revisar `Endpoint` en `cliente1.conf`; si hay NAT/router, abrir UDP 51820 hacia el servidor |
| `403 Forbidden` en `/~usuario/` | Home o `public_html` sin permisos de paso | `chmod 711 /home/usuario && chmod 755 /home/usuario/public_html` |
| `404` en `/~usuario/` | Falta `public_html` o el usuario no existe | Revisar `ls -ld /home/usuario/public_html` |
| Quedé afuera por SSH | Se deshabilitó la contraseña sin tener clave instalada | Entrar por la consola de la VM, instalar la clave en `~/.ssh/authorized_keys` |
| Cambié `default.conf` y no se refleja | nginx no recargó | `cd /opt/tp2 && docker compose exec web nginx -s reload` |
| Un usuario nuevo no aparece en el índice | El índice se regenera cada 5 min | `sudo genindex.sh` |
