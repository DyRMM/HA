#!/bin/sh
set -eu

echo "[autorenovador] Iniciando…"

# Rutas
SRC="/opt/renew/renew-cert.sh"
DST="/config/scripts/renew-cert.sh"

# Asegura carpetas
mkdir -p /config/scripts /data || true

# Carga opciones
RENEW_IF_DAYS_LEFT="$(jq -r '.renew_if_days_left // 0' /data/options.json)"
OVERWRITE_ON_START="$(jq -r '.overwrite_on_start // false' /data/options.json)"

# Normaliza
[ "$RENEW_IF_DAYS_LEFT" -ge 0 ] && [ "$RENEW_IF_DAYS_LEFT" -le 365 ] || RENEW_IF_DAYS_LEFT=0

# Muestra si el token está disponible (sin revelar valor)
if [ -n "${SUPERVISOR_TOKEN:-}" ]; then
  echo "[autorenovador] Token Supervisor: PRESENTE"
else
  echo "[autorenovador] Token Supervisor: AUSENTE (añade hassio_api/hassio_role y RECONSTRUYE el add-on)"
fi
echo "[autorenovador] renew_if_days_left=$RENEW_IF_DAYS_LEFT overwrite_on_start=$OVERWRITE_ON_START"

# Verifica script empaquetado
if [ ! -f "$SRC" ]; then
  echo "[autorenovador] ERROR: Falta $SRC dentro de la imagen"
  sleep 600
  exit 1
fi

# Copia inicial / sobrescritura opcional
if [ ! -f "$DST" ]; then
  echo "[autorenovador] Copiando script inicial -> $DST"
  cp -f "$SRC" "$DST"
  chmod +x "$DST" || true
elif [ "$OVERWRITE_ON_START" = "true" ]; then
  echo "[autorenovador] overwrite_on_start=true -> sobrescribiendo $DST"
  cp -f "$SRC" "$DST"
  chmod +x "$DST" || true
else
  echo "[autorenovador] Script ya existe en $DST (no se sobrescribe)"
  chmod +x "$DST" || true
fi

# ⬇️ Guarda el token (y PATH por si acaso) en /data/env.sh con permisos 600
ENV_FILE="/data/env.sh"
{
  echo "# generado por Autorenovador"
  echo "export SUPERVISOR_TOKEN='${SUPERVISOR_TOKEN:-}'"
  echo "export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'"
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"

# Cron fijo: 03:30 diario, cargando /data/env.sh antes de ejecutar
CRON_EXPR="30 3 * * *"
echo "[autorenovador] Instalando cron: $CRON_EXPR (by_days_left)"
crontab -l 2>/dev/null | grep -v "/config/scripts/renew-cert.sh" 2>/dev/null > /tmp/old_cron || true
# Carga el token/entorno y pasa el umbral
echo "$CRON_EXPR . $ENV_FILE; RENEW_IF_DAYS_LEFT=$RENEW_IF_DAYS_LEFT /bin/bash /config/scripts/renew-cert.sh" >> /tmp/old_cron
crontab /tmp/old_cron
rm -f /tmp/old_cron

echo "[autorenovador] Crontab actual:"
crontab -l || true

# 👉 One-shot al iniciar (cargando /data/env.sh)
echo "[autorenovador] Ejecutando comprobación inmediata (one-shot)…"
. "$ENV_FILE"
RENEW_IF_DAYS_LEFT="$RENEW_IF_DAYS_LEFT" /bin/bash "$DST" >/dev/null 2>&1 || true
echo "[autorenovador] One-shot lanzado. Revisa /config/scripts/renew-cert.log"

# Lanza crond en primer plano con logs
exec crond -f -l 8