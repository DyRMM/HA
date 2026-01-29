#!/bin/bash
# =========================================================
# renew-cert.sh
#   - Renueva certificados en /ssl usando una CA local.
#   - Renueva si días restantes <= RENEW_IF_DAYS_LEFT (incluida igualdad).
#   - Reinicia el add-on NGINX Home Assistant SSL proxy (core_nginx_proxy)
#     SOLO si el certificado/clave han cambiado (fullchain/privkey).
#   - Logs en /config/scripts/renew-cert.log y /config/scripts/renew-cert.debug
#   - Sin parsear fechas: usa openssl -checkend (búsqueda binaria) para estimar días.
# =========================================================

# --------- Arranque y debug mínimo ---------
mkdir -p /config/scripts || true
{
  echo "[ssl-renew] ===== ARRANQUE $(date) ====="
  echo "[ssl-renew] whoami=$(whoami)  pwd=$(pwd)"
  echo "[ssl-renew] SHELL=${SHELL:-}  PATH=${PATH:-}"
} >> /config/scripts/renew-cert.debug 2>&1

# --------- Logging principal ---------
LOG="/config/scripts/renew-cert.log"
LOGGER_OK=false
TEE_OK=false
if command -v logger >/dev/null 2>&1; then LOGGER_OK=true; fi
if command -v tee    >/dev/null 2>&1; then TEE_OK=true;    fi

if $LOGGER_OK && $TEE_OK; then
  # Duplicar a archivo y a syslog (visible en Registros del add-on)
  exec > >(tee -a "$LOG" | logger -t renew-cert) 2>&1
else
  # Solo archivo
  exec >>"$LOG" 2>&1
  echo "[ssl-renew] logger/tee no disponibles, se registra SOLO en $LOG"
fi

echo "[ssl-renew] ===== INICIO $(date) ====="
echo "[ssl-renew] PATH=$PATH"

# --------- Seguridad y manejo de errores ---------
set -euo pipefail
on_error() {
  local lineno=$1
  echo "[ssl-renew] ERROR en línea $lineno. Abortando."
}
trap 'on_error $LINENO' ERR

# --------- Configuración ---------
SSL_DIR="/ssl"
CONFIG="$SSL_DIR/openssl-san.cnf"

KEY="$SSL_DIR/ha.key"
CSR="$SSL_DIR/ha.csr"
CRT="$SSL_DIR/ha.crt"
CA_CRT="$SSL_DIR/ca.crt"
CA_KEY="$SSL_DIR/ca.key"
FULLCHAIN="$SSL_DIR/fullchain.pem"
PRIVKEY="$SSL_DIR/privkey.pem"

# authorized_keys (se sobreescribe cada ejecución)
AUTHORIZED_KEYS_SSL="$SSL_DIR/authorized_keys"
AUTHORIZED_KEYS_ADDON="/config/ssh/authorized_keys"

# Validez del nuevo cert
DAYS=365

# Umbral: renovar si días_restantes <= RENEW_IF_DAYS_LEFT
RENEW_IF_DAYS_LEFT="${RENEW_IF_DAYS_LEFT:-0}"

# Propietario/grupo (HA OS normalmente ejecuta como root)
DOCKER_USER="root"
DOCKER_GROUP="root"

# Slug del add-on NGINX que quieres reiniciar tras renovar
NGINX_ADDON_SLUG="core_nginx_proxy"

# --------- Utilidades ---------
OPENSSL_BIN="$(command -v openssl || true)"
SSH_KEYGEN_BIN="$(command -v ssh-keygen || true)"
echo "[ssl-renew] openssl=${OPENSSL_BIN:-no_encontrado}  ssh-keygen=${SSH_KEYGEN_BIN:-no_encontrado}"
if [ -z "${OPENSSL_BIN:-}" ]; then
  echo "[ssl-renew] ERROR: 'openssl' no está disponible en este entorno."
  exit 1
fi
if [ -z "${SSH_KEYGEN_BIN:-}" ]; then
  echo "[ssl-renew] ERROR: 'ssh-keygen' no está disponible en este entorno."
  exit 1
fi

# --------- Helpers ---------
log() { echo "[ssl-renew] $*"; }
ensure_dir_with_group_write() { local d="$1"; mkdir -p "$d"; chown "$DOCKER_USER:$DOCKER_GROUP" "$d"; chmod 2775 "$d"; }

# Estima los segundos restantes SIN usar 'date', solo con openssl -checkend.
# Devuelve aprox el mínimo N tal que expira en <= N (búsqueda binaria).
estimate_secs_left() {
  local low=-1
  local high=$((3 * 365 * 86400))  # rango 3 años
  local mid
  for _ in $(seq 1 32); do
    mid=$(((low + high) / 2))
    if "$OPENSSL_BIN" x509 -checkend "$mid" -noout -in "$CRT" >/dev/null 2>&1; then
      low=$mid       # sigue válido > mid
    else
      high=$mid      # expira <= mid
    fi
  done
  echo "$high"
}

# Reinicio vía Supervisor API usando SUPERVISOR_TOKEN
restart_via_supervisor_api() {
  local slug="$1"
  if [ -z "${SUPERVISOR_TOKEN:-}" ]; then
    log "SUPERVISOR_TOKEN no disponible; no puedo usar la Supervisor API."
    return 1
  fi
  local url="http://supervisor/addons/${slug}/restart"
  if command -v curl >/dev/null 2>&1; then
    curl -fsS -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
         -H "Content-Type: application/json" \
         -X POST "$url" -d '{}' >/dev/null
  else
    # BusyBox wget suele estar disponible
    wget -qO- --header="Authorization: Bearer ${SUPERVISOR_TOKEN}" \
              --header="Content-Type: application/json" \
              --post-data='{}' "$url" >/dev/null
  fi
}

umask 002  # ficheros nuevos base 664/660 tras chmod final

# --------- Validaciones previas ---------
for f in "$CONFIG" "$CA_CRT" "$CA_KEY"; do
  if [ ! -f "$f" ]; then log "ERROR: No existe $f"; exit 1; fi
done

ensure_dir_with_group_write "$SSL_DIR"
ensure_dir_with_group_write "/config/ssh"

# --------- Comprobación de días restantes (robusta) y decisión ---------
if ! [ "$RENEW_IF_DAYS_LEFT" -ge 0 ] 2>/dev/null; then RENEW_IF_DAYS_LEFT=0; fi
log "Política: renovar si días_restantes <= ${RENEW_IF_DAYS_LEFT}"

# Hashes previos para detectar cambios reales al final
OLD_FULLCHAIN_HASH="$(sha256sum "$FULLCHAIN" 2>/dev/null | awk '{print $1}' || true)"
OLD_PRIVKEY_HASH="$(sha256sum "$PRIVKEY"  2>/dev/null | awk '{print $1}' || true)"

if [ -f "$CRT" ] && [ "$RENEW_IF_DAYS_LEFT" -gt 0 ]; then
  SECS_LEFT_EXACT=$(estimate_secs_left)
  DAYS_LEFT=$(( (SECS_LEFT_EXACT + 86399) / 86400 ))  # ceil días
  log "Comprobación: segundos_restantes≈${SECS_LEFT_EXACT}, dias_restantes_est=${DAYS_LEFT}"

  SECS_LEFT_UMBRAL=$(( RENEW_IF_DAYS_LEFT * 86400 ))
  # Parche ≤ X: +1s para que igualdad cuente como renovar
  if "$OPENSSL_BIN" x509 -checkend "$((SECS_LEFT_UMBRAL + 1))" -noout -in "$CRT"; then
    log "DECISIÓN: NO renovar (hay > ${RENEW_IF_DAYS_LEFT} días restantes)."
    exit 0
  else
    log "DECISIÓN: RENOVAR (días restantes <= ${RENEW_IF_DAYS_LEFT})."
  fi
elif [ ! -f "$CRT" ]; then
  log "No existe $CRT. Se generará un nuevo certificado."
else
  log "Umbral configurado = 0 (siempre renovar). Procediendo…"
fi

# --------- 1. Generar clave privada y CSR ---------
log "Generando clave privada y CSR..."
"$OPENSSL_BIN" req -new -nodes \
  -out "$CSR" \
  -newkey rsa:2048 \
  -keyout "$KEY" \
  -config "$CONFIG"

# --------- 2. Firmar certificado con la CA ---------
log "Firmando certificado con la CA..."
"$OPENSSL_BIN" x509 -req \
  -in "$CSR" \
  -CA "$CA_CRT" \
  -CAkey "$CA_KEY" \
  -CAcreateserial \
  -out "$CRT" \
  -days "$DAYS" \
  -extensions req_ext \
  -extfile "$CONFIG"

# --------- 3. Crear fullchain.pem ---------
log "Creando fullchain.pem..."
cat "$CRT" "$CA_CRT" > "$FULLCHAIN"

# --------- 4. Crear privkey.pem ---------
log "Copiando clave privada a privkey.pem..."
cp -f "$KEY" "$PRIVKEY"

# --------- 5. Generar authorized_keys ---------
log "Extrayendo clave pública SSH del par generado..."
# Asegura permisos estrictos ANTES de usar ssh-keygen (OpenSSH exige 600)
chown "$DOCKER_USER:$DOCKER_GROUP" "$KEY"
chmod 600 "$KEY"
PUB_KEY="$("$SSH_KEYGEN_BIN" -y -f "$KEY")"

log "Escribiendo authorized_keys en $AUTHORIZED_KEYS_SSL y $AUTHORIZED_KEYS_ADDON..."
echo "$PUB_KEY" > "$AUTHORIZED_KEYS_SSL"
echo "$PUB_KEY" > "$AUTHORIZED_KEYS_ADDON"

# --------- 6. Permisos y propietarios ---------
log "Ajustando propietario y permisos finales..."
# Públicos/CSR/CA: lectura pública
chmod 644 "$CRT" "$FULLCHAIN" "$CSR" "$CA_CRT"
# Privadas: SOLO dueño
chmod 600 "$KEY" "$PRIVKEY"
# authorized_keys: lectura pública
chmod 644 "$AUTHORIZED_KEYS_SSL" "$AUTHORIZED_KEYS_ADDON"

# Propietario/grupo coherente
chown "$DOCKER_USER:$DOCKER_GROUP" \
  "$CRT" "$FULLCHAIN" "$KEY" "$PRIVKEY" "$CSR" "$CA_CRT" \
  "$AUTHORIZED_KEYS_SSL" "$AUTHORIZED_KEYS_ADDON"

# --------- 7. Detección de cambios y reinicio del add-on NGINX si procede ---------
NEW_FULLCHAIN_HASH="$(sha256sum "$FULLCHAIN" 2>/dev/null | awk '{print $1}' || true)"
NEW_PRIVKEY_HASH="$(sha256sum "$PRIVKEY"  2>/dev/null | awk '{print $1}' || true)"

CHANGED="no"
if [ "${OLD_FULLCHAIN_HASH:-}" != "${NEW_FULLCHAIN_HASH:-}" ] || [ "${OLD_PRIVKEY_HASH:-}" != "${NEW_PRIVKEY_HASH:-}" ]; then
  CHANGED="yes"
fi

if [ "$CHANGED" = "yes" ]; then
  log "Cambios detectados en fullchain/privkey. Intentando reiniciar add-on: ${NGINX_ADDON_SLUG}"
  if command -v ha >/dev/null 2>&1; then
    if ha addons restart "$NGINX_ADDON_SLUG"; then
      log "Add-on ${NGINX_ADDON_SLUG} reiniciado (CLI ha)."
    else
      log "CLI ha falló. Intentando Supervisor API…"
      if restart_via_supervisor_api "$NGINX_ADDON_SLUG"; then
        log "Add-on ${NGINX_ADDON_SLUG} reiniciado (Supervisor API)."
      else
        log "No se pudo reiniciar ${NGINX_ADDON_SLUG}. Revisa permisos y logs del Supervisor."
      fi
    fi
  else
    # Directamente Supervisor API
    if restart_via_supervisor_api "$NGINX_ADDON_SLUG"; then
      log "Add-on ${NGINX_ADDON_SLUG} reiniciado (Supervisor API)."
    else
      log "CLI 'ha' y Supervisor API no disponibles. No se reinicia automáticamente ${NGINX_ADDON_SLUG}."
    fi
  fi
else
  log "No hubo cambios en fullchain/privkey. No se reinicia ${NGINX_ADDON_SLUG}."
fi

# --------- 8. Resumen ---------
log "RESUMEN: Certificado: $CRT"
log "RESUMEN: Clave privada: $KEY"
log "RESUMEN: Fullchain:   $FULLCHAIN"
log "RESUMEN: Privkey:     $PRIVKEY"
log "RESUMEN: Authorized Keys (SSL):    $AUTHORIZED_KEYS_SSL"
log "RESUMEN: Authorized Keys (ADD-ON): $AUTHORIZED_KEYS_ADDON"
log "Completado."
exit 0