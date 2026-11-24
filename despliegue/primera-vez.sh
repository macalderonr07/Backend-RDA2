#!/usr/bin/env bash
# despliegue/primera-vez.sh — pone en marcha el backend completo en el servidor.
#   1. Levanta Oracle y Redis y espera a que Oracle esté sano (la primera vez
#      crea la base en el volumen: puede tardar varios minutos).
#   2. Instala la base (esquema, lógica y migraciones) con base-de-datos/instalar.sh.
#      Si la base ya existe, solo aplica las migraciones nuevas.
#   3. Construye y levanta las dos APIs y Caddy (HTTPS).
#   4. Crea o actualiza el primer administrador (ADMIN_CORREO / ADMIN_CLAVE).
# Se puede volver a correr para actualizar después de un git pull.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
COMPOSE="${COMPOSE:-docker compose}"
MOTOR="${MOTOR:-docker}"

[[ -f .env ]] || { echo "Falta despliegue/.env: copia .env.example y complétalo." >&2; exit 1; }
set -a; . ./.env; set +a
for v in DOMINIO ORACLE_SYS_PASSWORD CLAVE_PRODUCCION CLAVE_ECOMMERCE CLAVE_APP_WEB CLAVE_APP_ADMIN JWT_SECRETO ADMIN_CORREO ADMIN_CLAVE; do
    [[ -n "${!v:-}" ]] || { echo "Falta $v en despliegue/.env" >&2; exit 1; }
done
[[ ${#JWT_SECRETO} -ge 32 ]] || { echo "JWT_SECRETO: al menos 32 caracteres (openssl rand -hex 32)" >&2; exit 1; }

echo "▶ Oracle y Redis"
$COMPOSE up -d oracle redis
# id del contenedor por las etiquetas estandar de Compose (Docker y Podman las ponen igual)
id="$("$MOTOR" ps -q --filter label=com.docker.compose.project=comercial-elite --filter label=com.docker.compose.service=oracle | head -n1)"
[[ -n "$id" ]] || { echo "No se encontró el contenedor de Oracle" >&2; exit 1; }
printf "  esperando a Oracle"
for _ in $(seq 1 120); do
    estado="$("$MOTOR" inspect --format '{{.State.Health.Status}}' "$id" 2>/dev/null || true)"
    [[ "$estado" == "healthy" ]] && break
    printf "."; sleep 10
done
echo
[[ "$estado" == "healthy" ]] || { echo "Oracle no quedó sano: $COMPOSE logs oracle" >&2; exit 1; }

echo "▶ Base de datos"
MOTOR="$MOTOR" CONTENEDOR="$id" ../base-de-datos/instalar.sh

echo "▶ APIs y proxy HTTPS"
$COMPOSE up -d --build api-tienda api-administracion caddy

echo "▶ Primer administrador"
$COMPOSE run --rm --no-deps api-administracion node scripts/semilla-admin.mjs

cat <<FIN

✔ Backend en marcha:
   Tienda:          https://$DOMINIO/tienda/api/v1/productos
   Administración:  https://$DOMINIO/admin/api/v1   (401 sin token = correcto)
   Logs:            $COMPOSE logs -f api-tienda api-administracion
FIN
