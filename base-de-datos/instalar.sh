#!/usr/bin/env bash
# base-de-datos/instalar.sh — instala Comercial Elite completo en un Oracle
# que corre en un contenedor (imagen gvenzl/oracle-free, PDB FREEPDB1):
#
#   1. Esquema y logica base (oracle/ComercialElite_Oracle_1..3)
#   2. Migraciones de la API de la tienda (api-tienda/db/01..18) y de la
#      administracion (api-administracion/db/11), en orden numerico.
#
# Uso (desde la raiz del repositorio):
#   CONTENEDOR=ce_oracle \
#   CLAVE_PRODUCCION=... CLAVE_ECOMMERCE=... CLAVE_APP_WEB=... CLAVE_APP_ADMIN=... \
#   ./base-de-datos/instalar.sh
#
# MOTOR=docker (por defecto) o podman. Las claves nunca se imprimen.
# Sirve para instalar y para ACTUALIZAR una base en uso:
#   - el esquema base solo se crea si PRODUCCION no existe;
#   - cada migracion se aplica UNA sola vez: la tabla produccion.migracion_aplicada
#     registra las ya aplicadas (como Flyway/Liquibase). Volver a correr una
#     migracion vieja contra un esquema que cambio despues falla (p. ej. la 08
#     usa una columna que la 09 reemplazo), por eso nunca se repiten.
set -euo pipefail

MOTOR="${MOTOR:-docker}"
CONTENEDOR="${CONTENEDOR:?Define CONTENEDOR (nombre del contenedor de Oracle)}"
PDB="${PDB:-FREEPDB1}"
for v in CLAVE_PRODUCCION CLAVE_ECOMMERCE CLAVE_APP_WEB CLAVE_APP_ADMIN; do
    [[ -n "${!v:-}" ]] || { echo "Falta la variable $v" >&2; exit 1; }
    [[ "${!v}" =~ ^[A-Za-z][A-Za-z0-9_]{7,29}$ ]] || { echo "$v: 8 a 30 caracteres, letra al inicio, solo letras, números y _" >&2; exit 1; }
done
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Nunca mostrar una clave: si sqlplus repite una sentencia que falla (p. ej.
# CREATE USER ... IDENTIFIED BY "..."), la clave se reemplaza por ***.
ocultar() {
    local texto
    texto="$(cat)"
    for v in CLAVE_PRODUCCION CLAVE_ECOMMERCE CLAVE_APP_WEB CLAVE_APP_ADMIN; do
        texto="${texto//${!v}/***}"
    done
    printf '%s\n' "$texto"
}

# Corre un script como SYSDBA dentro de la PDB. $2 = argumento posicional (&1).
correr() {
    local archivo="$1" argumento="${2:-}" nombre
    nombre="$(basename "$archivo")"
    echo "▶ $nombre"
    "$MOTOR" cp "$archivo" "$CONTENEDOR:/tmp/$nombre"
    # El envoltorio define las claves (no quedan en ningun archivo del repositorio)
    # y sale con error ante cualquier fallo de SQL o de sqlplus.
    "$MOTOR" exec -i "$CONTENEDOR" bash -c "cat > /tmp/correr.sql" <<SQL
WHENEVER OSERROR EXIT FAILURE
WHENEVER SQLERROR EXIT FAILURE
ALTER SESSION SET CONTAINER = $PDB;
SET DEFINE ON
SET VERIFY OFF
DEFINE clave_produccion = "$CLAVE_PRODUCCION"
DEFINE clave_ecommerce = "$CLAVE_ECOMMERCE"
@/tmp/$nombre $argumento
EXIT
SQL
    local salida
    if ! salida="$("$MOTOR" exec "$CONTENEDOR" bash -lc "sqlplus -s -L / as sysdba @/tmp/correr.sql" 2>&1)"; then
        echo "$salida" | tail -40 | ocultar
        echo "✖ Falló $nombre" >&2
        exit 1
    fi
    # Lo que no detiene sqlplus se busca en la salida: objetos PL/SQL que
    # compilan con errores, errores de sqlplus y pruebas fallidas de la suite
    # de la base ("FALLA" / "ERROR INESPERADO"). Los ORA- esperados de las
    # pruebas negativas ("OK 26. ... -> ORA-20003") no cuentan.
    local fallo="with compilation errors|^ERROR at line|^SP2-[0-9]+|^FALLA |ERROR INESPERADO"
    if grep -qE "$fallo" <<<"$salida"; then
        echo "$salida" | grep -nE -B3 -A3 "$fallo" | head -60 | ocultar
        echo "✖ $nombre terminó con errores" >&2
        exit 1
    fi
    "$MOTOR" exec "$CONTENEDOR" rm -f "/tmp/correr.sql"
}

# El esquema base no se puede correr dos veces (CREATE USER): si ya existe,
# solo se aplican las migraciones (asi el mismo script sirve para actualizar).
existe="$("$MOTOR" exec "$CONTENEDOR" bash -lc "printf 'SET HEADING OFF FEEDBACK OFF PAGESIZE 0\nALTER SESSION SET CONTAINER = $PDB;\nSELECT COUNT(*) FROM dba_users WHERE username = '\''PRODUCCION'\'';\nEXIT\n' | sqlplus -s -L / as sysdba" | tr -dc '0-9')"
if [[ "$existe" == "1" ]]; then
    echo "• El esquema PRODUCCION ya existe: se aplican solo las migraciones."
else
    correr "$RAIZ/base-de-datos/oracle/ComercialElite_Oracle_1_esquema.sql"
    correr "$RAIZ/base-de-datos/oracle/ComercialElite_Oracle_2_logica.sql"
    correr "$RAIZ/base-de-datos/oracle/ComercialElite_Oracle_3_prueba.sql"
fi

# Consulta de una linea como SYSDBA en la PDB (sin claves).
consultar() {
    local salida
    if ! salida="$("$MOTOR" exec -i "$CONTENEDOR" bash -lc "sqlplus -s -L / as sysdba" <<SQL
WHENEVER SQLERROR EXIT FAILURE
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 400 TRIMOUT ON
ALTER SESSION SET CONTAINER = $PDB;
$1
EXIT
SQL
)"; then
        echo "$salida" | tail -15 >&2
        echo "✖ Falló una consulta del registro de migraciones" >&2
        exit 1
    fi
    sed '/^[[:space:]]*$/d' <<<"$salida"
}

# Registro de migraciones aplicadas
consultar "DECLARE v_n NUMBER; BEGIN
  SELECT COUNT(*) INTO v_n FROM dba_tables WHERE owner = 'PRODUCCION' AND table_name = 'MIGRACION_APLICADA';
  IF v_n = 0 THEN
    EXECUTE IMMEDIATE 'CREATE TABLE produccion.migracion_aplicada (
        mig_nombre   VARCHAR2(100) NOT NULL,
        mig_sha256   VARCHAR2(64),
        mig_aplicada TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
        CONSTRAINT pk_migracion_aplicada PRIMARY KEY (mig_nombre))';
    EXECUTE IMMEDIATE 'COMMENT ON TABLE produccion.migracion_aplicada IS ''Migraciones ya aplicadas por base-de-datos/instalar.sh (cada una corre una sola vez)''';
  END IF;
END;
/" > /dev/null

# Migraciones en orden numerico, sin importar en que API viven
mapfile -t migraciones < <(
    { ls "$RAIZ"/api-tienda/db/[0-9][0-9]_*.sql; ls "$RAIZ"/api-administracion/db/[0-9][0-9]_*.sql; } |
        awk -F/ '{print $NF "\t" $0}' | sort | cut -f2
)

# Bases instaladas ANTES de existir el registro: se instalaron completas con las
# migraciones 01..18 (instalar.sh las corria todas). Se registran como aplicadas
# solo si la base tiene lo que crea la 18 (la outbox del catalogo); si no, se
# detiene en vez de adivinar.
registradas="$(consultar "SELECT COUNT(*) FROM produccion.migracion_aplicada;" | tr -dc '0-9')"
if [[ "$existe" == "1" && "$registradas" == "0" ]]; then
    outbox="$(consultar "SELECT COUNT(*) FROM dba_tables WHERE owner = 'PRODUCCION' AND table_name = 'CATALOGO_CAMBIO';" | tr -dc '0-9')"
    if [[ "$outbox" != "1" ]]; then
        echo "✖ La base existe pero no tiene registro de migraciones ni la outbox de la 18:" >&2
        echo "  no se puede saber cuales migraciones tiene. Revisarla a mano antes de continuar." >&2
        exit 1
    fi
    echo "• Base anterior al registro de migraciones: se registran 01..18 como ya aplicadas."
    for m in "${migraciones[@]}"; do
        nombre="$(basename "$m")"
        (( 10#${nombre:0:2} <= 18 )) || continue
        consultar "INSERT INTO produccion.migracion_aplicada (mig_nombre, mig_sha256) VALUES ('$nombre', '$(sha256sum "$m" | cut -c1-64)');
COMMIT;" > /dev/null
    done
fi

aplicadas=0
for m in "${migraciones[@]}"; do
    nombre="$(basename "$m")"
    huella="$(sha256sum "$m" | cut -c1-64)"
    registrada="$(consultar "SELECT NVL(MAX(mig_sha256), '-') FROM produccion.migracion_aplicada WHERE mig_nombre = '$nombre';" | tr -dc 'a-f0-9-')"
    if [[ -n "$registrada" && "$registrada" != "-" ]]; then
        [[ "$registrada" == "$huella" ]] || echo "⚠ $nombre cambio desde que se aplico: NO se vuelve a correr (un cambio de esquema va en una migracion nueva)."
        continue
    fi
    case "$nombre" in
        01_usuario_app.sql) correr "$m" "$CLAVE_APP_WEB" ;;
        11_administracion.sql) correr "$m" "$CLAVE_APP_ADMIN" ;;
        *) correr "$m" ;;
    esac
    consultar "INSERT INTO produccion.migracion_aplicada (mig_nombre, mig_sha256) VALUES ('$nombre', '$huella');
COMMIT;" > /dev/null
    aplicadas=$((aplicadas + 1))
done
echo "✔ Base lista: $aplicadas migraciones nuevas aplicadas (${#migraciones[@]} en total registradas)."
