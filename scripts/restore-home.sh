#!/usr/bin/env bash
# =============================================================================
# restore-home.sh - Restaura un archivo o carpeta de un usuario desde el backup
#
# Uso:
#   restore-home.sh -l                              lista los snapshots disponibles
#   restore-home.sh <usuario> <ruta> [snapshot]     restaura <ruta> (relativa al home)
#
# Ejemplos:
#   sudo restore-home.sh kakashi public_html/naruto-run.jpg          # desde el ultimo backup
#   sudo restore-home.sh kakashi Documentos 2026-10-29_140001        # una carpeta, de un snapshot puntual
#
# Si el archivo existe y es distinto, el actual se conserva como <nombre>.antes-de-restaurar
# Alternativa sin admin: cada usuario puede copiar sus propios archivos a mano desde
#   /var/backups/home/latest/<usuario>/...
# =============================================================================
set -euo pipefail

[ -f /etc/tp2/tp2.env ] && . /etc/tp2/tp2.env
HOME_BASE="${HOME_BASE:-/home}"
BACKUP_DEST="${BACKUP_DEST:-/var/backups/home}"

die() { echo "ERROR: $*" >&2; exit 1; }
usage() { sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

[ "$#" -ge 1 ] || usage

if [ "$1" = "-l" ]; then
    echo "Snapshots en $BACKUP_DEST:"
    ls -1d "$BACKUP_DEST"/20??-??-??_?????? 2>/dev/null | sed 's|.*/|  |' || true
    [ -L "$BACKUP_DEST/latest" ] && echo "latest -> $(basename "$(readlink -f "$BACKUP_DEST/latest")")"
    exit 0
fi

[ "$#" -ge 2 ] || usage
[ "$(id -u)" -eq 0 ] || die "ejecutar como root (sudo)"

user="$1"
rel="${2#/}"; rel="${rel%/}"
snap="${3:-latest}"

[[ "$user" =~ ^[a-z_][a-z0-9_-]*$ ]]                || die "nombre de usuario invalido"
[[ "$snap" =~ ^(latest|20[0-9]{2}-[0-9]{2}-[0-9]{2}_[0-9]{6})$ ]] || die "snapshot invalido (use -l para listar)"
[ -n "$rel" ]                                       || die "indicar la ruta a restaurar"
case "/$rel/" in */../*) die "la ruta no puede contener .." ;; esac

uid="$(id -u "$user" 2>/dev/null)" || die "el usuario $user no existe"
gid="$(id -g "$user")"

snapdir="$BACKUP_DEST/$snap"
[ -d "$snapdir" ] || die "no existe el snapshot $snap en $BACKUP_DEST"
src="$snapdir/$user/$rel"
dst="$HOME_BASE/$user/$rel"
[ -e "$src" ] || die "'$rel' no existe en el snapshot $(basename "$(readlink -f "$snapdir")") de $user"

# Recrea los directorios intermedios (por si se borro toda una carpeta) con el dueno correcto
mk_parents() {
    local path="$1" cur="$HOME_BASE/$user" relcur="" part
    [ "$path" = "." ] && return 0
    IFS='/' read -ra parts <<< "$path"
    for part in "${parts[@]}"; do
        cur="$cur/$part"; relcur="${relcur:+$relcur/}$part"
        if [ ! -d "$cur" ]; then
            mkdir "$cur"
            chown "$uid:$gid" "$cur"
            chmod --reference="$snapdir/$user/$relcur" "$cur" 2>/dev/null || true
        fi
    done
}

rs=(rsync -aH --numeric-ids --backup --suffix=.antes-de-restaurar)

if [ -d "$src" ] && [ ! -L "$src" ]; then
    mk_parents "$rel"
    "${rs[@]}" "$src/" "$dst/"
else
    mk_parents "$(dirname "$rel")"
    "${rs[@]}" "$src" "$dst"
fi

echo "Restaurado: $dst  (desde snapshot $(basename "$(readlink -f "$snapdir")"))"
