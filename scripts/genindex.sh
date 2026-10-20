#!/usr/bin/env bash
# =============================================================================
# genindex.sh - Genera la pagina principal (http://<IP_VPN>/) con los enlaces a los
# directorios publicos (/~usuario/) de cada usuario que tenga ~/public_html.
# Corre desde cron cada 5 minutos, asi un usuario nuevo aparece solo.
# =============================================================================
set -euo pipefail

[ -f /etc/tp2/tp2.env ] && . /etc/tp2/tp2.env
HOME_BASE="${HOME_BASE:-/home}"
WWW_DIR="${WWW_DIR:-/srv/tp2/www}"
VPN_IP="${VPN_IP:-10.8.0.1}"

mkdir -p "$WWW_DIR"
chmod 755 "$WWW_DIR"
tmp="$(mktemp "$WWW_DIR/.index.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

rows=""
count=0
for d in "$HOME_BASE"/*/; do
    [ -d "${d}public_html" ] || continue
    u="$(basename "$d")"
    # misma regex que valida nginx: evita nombres raros dentro del HTML
    [[ "$u" =~ ^[a-z_][a-z0-9_-]*$ ]] || continue
    extra=""
    [ -d "${d}public_html/privado" ] && extra=" &middot; <a href=\"/~${u}/privado/\">zona privada &#128274;</a>"
    rows="${rows}<li><a href=\"/~${u}/\">/~${u}/</a>${extra}</li>
"
    count=$((count + 1))
done
[ "$count" -gt 0 ] || rows="<li class=\"empty\">Todavia no hay usuarios con public_html.</li>"

cat > "$tmp" <<HTML
<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Servidor TP2 - Administracion de Sistemas y Redes</title>
<style>
  :root { --bg:#0f1720; --card:#17212c; --txt:#e6edf3; --mut:#8b9bab; --acc:#4cc2ff; }
  * { box-sizing:border-box; }
  body { margin:0; font:16px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif; background:var(--bg); color:var(--txt); }
  main { max-width:720px; margin:0 auto; padding:48px 20px; }
  h1 { font-size:1.6rem; margin:0 0 4px; }
  p.sub { color:var(--mut); margin:0 0 32px; }
  section { background:var(--card); border-radius:12px; padding:20px 24px; margin-bottom:20px; }
  h2 { font-size:1rem; text-transform:uppercase; letter-spacing:.06em; color:var(--mut); margin:0 0 12px; }
  ul { list-style:none; margin:0; padding:0; }
  li { padding:8px 0; border-top:1px solid #243140; }
  li:first-child { border-top:0; }
  li.empty { color:var(--mut); }
  a { color:var(--acc); text-decoration:none; }
  a:hover { text-decoration:underline; }
  footer { color:var(--mut); font-size:.85rem; margin-top:28px; }
</style>
</head>
<body>
<main>
  <h1>Servidor TP2</h1>
  <p class="sub">Acceso exclusivo a traves de la VPN (WireGuard) &middot; ${VPN_IP}</p>

  <section>
    <h2>Directorios de usuarios</h2>
    <ul>
${rows}    </ul>
  </section>

  <section>
    <h2>Monitoreo</h2>
    <ul>
      <li><a href="http://${VPN_IP}:19999/">Panel de metricas (Netdata)</a> &middot; CPU, memoria, disco y trafico de wg0</li>
    </ul>
  </section>

  <footer>Pagina generada el $(date '+%d/%m/%Y %H:%M:%S') &middot; ${count} usuario(s)</footer>
</main>
</body>
</html>
HTML

chmod 644 "$tmp"
mv -f "$tmp" "$WWW_DIR/index.html"
trap - EXIT
