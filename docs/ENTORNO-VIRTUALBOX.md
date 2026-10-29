# Entorno de la demo: VirtualBox en Windows

Cómo se armó el laboratorio usado en la demostración. El servidor es una VM de VirtualBox y la
"otra computadora de la red" es la propia PC con Windows, que se conecta a la VM por la VPN.

```
  PC Windows (cliente)                         VM tp2-servidor (Ubuntu Server 24.04)
  ┌───────────────────────────┐                ┌──────────────────────────────────────┐
  │ WireGuard  10.8.0.2       │── túnel UDP ──▶│ enp0s8 192.168.56.10  ("red pública")│
  │ navegador / ssh / curl    │   51820        │   solo UDP 51820 + TCP 22            │
  │ host-only 192.168.56.1    │                │ wg0    10.8.0.1  web :80, netdata,   │
  └───────────────────────────┘                │                  ssh                 │
                                               │ enp0s3 NAT (salida a Internet)       │
                                               └──────────────────────────────────────┘
```

## Red

| Placa de la VM | Tipo VirtualBox | Uso |
|---|---|---|
| `enp0s3` | NAT | Salida a Internet (apt, imágenes de Docker). Desde afuera no se puede iniciar ninguna conexión hacia la VM por esta placa. |
| `enp0s8` | Host-only (`192.168.56.0/24`) | Hace de **red pública**: es por donde la PC llega al servidor. IP fija `192.168.56.10`. |

La IP fija de `enp0s8` se configura con netplan (`/etc/netplan/60-tp2-hostonly.yaml`):

```yaml
network:
  version: 2
  ethernets:
    enp0s8:
      dhcp4: false
      addresses: [192.168.56.10/24]
```

```bash
sudo chmod 600 /etc/netplan/60-tp2-hostonly.yaml && sudo netplan apply
```

## Crear la VM (PowerShell en Windows)

Requisitos: VirtualBox 7.x (`winget install Oracle.VirtualBox`) y la ISO
`ubuntu-24.04.5-live-server-amd64.iso` de <https://releases.ubuntu.com/24.04/>.

```powershell
$vbm = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
& $vbm createvm --name tp2-servidor --ostype Ubuntu24_LTS_64 --register
& $vbm modifyvm tp2-servidor --memory 4096 --cpus 2 --graphicscontroller vmsvga --rtcuseutc on `
    --nic1 nat --nic2 hostonly --host-only-adapter2 "VirtualBox Host-Only Ethernet Adapter"
$disk = "$env:USERPROFILE\VirtualBox VMs\tp2-servidor\tp2-servidor.vdi"
& $vbm createmedium disk --filename $disk --size 25600
& $vbm storagectl tp2-servidor --name SATA --add sata
& $vbm storageattach tp2-servidor --storagectl SATA --port 0 --device 0 --type hdd --medium $disk
& $vbm storagectl tp2-servidor --name IDE --add ide

# Instalacion desatendida de Ubuntu (crea el usuario administrador)
& $vbm unattended install tp2-servidor --iso=C:\ruta\ubuntu-24.04.5-live-server-amd64.iso `
    --user=juan --password=<contraseña> --hostname=tp2-servidor.local `
    --time-zone=America/Argentina/Buenos_Aires --start-vm=gui
```

Después de instalar: `sudo apt install openssh-server` y copiar la clave pública de la PC a
`~/.ssh/authorized_keys` del administrador (`ssh-keygen -t ed25519` en Windows genera el par en
`%USERPROFILE%\.ssh\`).

## Aprovisionar el servidor

Dentro de la VM, como el administrador:

```bash
git clone https://github.com/juanpablocadenteferreiro/administracion-redes-tp4.git tp2 && cd tp2
cp setup.env.example setup.env
# en setup.env: WG_ENDPOINT=192.168.56.10  y  VPN_CLIENTS="pc-windows celular"
sudo ./setup.sh
```

## Cliente VPN en Windows

1. Instalar WireGuard: `winget install WireGuard.WireGuard`.
2. Copiar el archivo del cliente desde el servidor:
   `ssh juan@192.168.56.10 "sudo cat /etc/wireguard/clients/pc-windows.conf" > pc-windows.conf`
3. En la app WireGuard: **Import tunnel(s) from file** → `pc-windows.conf` → **Activate**.
4. Probar: `ping 10.8.0.1` y abrir `http://10.8.0.1/` en el navegador.

El cliente usa *split tunnel* (`AllowedIPs = 10.8.0.0/24`): solo el tráfico hacia la VPN pasa por
el túnel; Internet sigue saliendo normal.
