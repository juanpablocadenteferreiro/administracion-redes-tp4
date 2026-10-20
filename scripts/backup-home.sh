#!/usr/bin/env bash
# =============================================================================
# backup-home.sh - Backup periodico de /home/*  (se instala en /usr/local/sbin)
#
# Hace un snapshot incremental con rsync + hardlinks (--link-dest): cada corrida
# genera una carpeta fechada con la foto completa de /home, pero los archivos que
# no cambiaron ocupan 0 bytes extra (son hardlinks al snapshot anterior).
#
#   /var/backups/home/2026-10-29_140001/<usuario>/...
#   /var/backups/home/latest  -> ultimo snapshot completo y exitoso
#
# Lo ejecuta cron (ver /etc/cron.d/tp2). Tambien se puede correr a mano.
# =============================================================================
set -euo pipefail

[ -f /etc/tp2/tp2.env ] && . /etc/tp2/tp2.env
HOME_BASE="${HOME_BASE:-/home}"
BACKUP_DEST="${BACKUP_DEST:-/var/backups/home}"
KEEP_DAYS="${BACKUP_KEEP_DAYS:-14}"
LOCK_FILE="${LOCK_FILE:-/run/tp2-backup.lock}"

log() { echo "$(date '+%F %T') [backup] $*"; }

# Evita que dos backups corran a la vez
exec 9>"$LOCK_FILE"
flock -n 9 || { log "ya hay otro backup en ejecucion; salgo"; exit 0; }

command -v rsync >/dev/null || { log "ERROR: falta rsync (apt install rsync)"; exit 1; }
[ -d "$HOME_BASE" ] || { log "ERROR: no existe $HOME_BASE"; exit 1; }

mkdir -p "$BACKUP_DEST"
# Los snapshots conservan owner y permisos originales: cada usuario puede leer SUS archivos
# (y solo los suyos) para recuperarlos por su cuenta; el resto sigue protegido por los permisos.
chmod 755 "$BACKUP_DEST"

stamp="$(date +%Y-%m-%d_%H%M%S)"
tmp="$BACKUP_DEST/.inprogress"
final="$BACKUP_DEST/$stamp"

prev=""
if [ -L "$BACKUP_DEST/latest" ]; then
    prev="$(readlink -f "$BACKUP_DEST/latest" || true)"
fi

opts=(-aH --numeric-ids --delete --exclude='.cache/' --exclude='lost+found/')
if [ -n "$prev" ] && [ -d "$prev" ]; then
    opts+=("--link-dest=$prev")
fi

[ -e "$final" ] && { log "el snapshot $stamp ya existe; salgo"; exit 0; }

rm -rf "$tmp"
log "inicio: $HOME_BASE -> $final (base incremental: ${prev:-ninguna})"

rc=0
rsync "${opts[@]}" "$HOME_BASE"/ "$tmp"/ || rc=$?
# rc=24: algun archivo desaparecio durante la copia (normal en un /home en uso)
if [ "$rc" -ne 0 ] && [ "$rc" -ne 24 ]; then
    log "ERROR: rsync termino con codigo $rc; el snapshot se descarta"
    rm -rf "$tmp"
    exit "$rc"
fi

mv "$tmp" "$final"
ln -sfn "$final" "$BACKUP_DEST/latest.new"
mv -T "$BACKUP_DEST/latest.new" "$BACKUP_DEST/latest"
log "OK: snapshot $stamp creado"

# Retencion: se borran snapshots mas viejos que KEEP_DAYS (se compara por nombre, no por mtime,
# porque rsync -a copia el mtime del directorio origen) y nunca el que apunta "latest".
cutoff="$(date -d "-${KEEP_DAYS} days" +%Y-%m-%d_%H%M%S)"
current="$(readlink -f "$BACKUP_DEST/latest")"
for d in "$BACKUP_DEST"/20??-??-??_??????; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    if [[ "$name" < "$cutoff" && "$d" != "$current" ]]; then
        rm -rf "$d"
        log "retencion: eliminado snapshot $name"
    fi
done
