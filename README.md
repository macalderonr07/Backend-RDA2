# Comercial Elite: backend

Backend del e-commerce de insumos para calzado y marroquinería **Comercial
Elite** (Quito). Las reglas de negocio viven en la base Oracle (funciones y
disparadores). Encima hay dos APIs REST en Express:

| Carpeta | Qué es | Puerto |
|---|---|---|
| [`api-tienda/`](api-tienda/) | API pública de la tienda: catálogo con **Redis como principal y Oracle de respaldo** (outbox + sincronizador), carrito, pedidos y clientes web. Usuario de base `app_web` (rol `ELITE_ECOMMERCE`) | 5050 |
| [`api-administracion/`](api-administracion/) | API del sistema de administración: productos, inventario, compras, ventas, cobros, usuarios, roles y reportes. Express + **Sequelize**, JWT y permisos por rol, que la base vuelve a exigir. Usuario de base `app_admin` (rol `ELITE_PRODUCCION`) | 5070 |
| [`base-de-datos/`](base-de-datos/) | Scripts de la base: Oracle (esquema, lógica y su suite de pruebas), la versión PostgreSQL del modelo y `instalar.sh` | — |

Las migraciones de cada API están en su carpeta `db/` (`01`–`18`; la `11` es
de la administración). `instalar.sh` las corre en orden numérico.

## Requisitos

- Node.js 20 o 22.
- Oracle 23 Free. En desarrollo se usa el contenedor `gvenzl/oracle-free`, con la PDB `FREEPDB1`.
- Redis 7. Es opcional: sin Redis, la tienda lee todo de Oracle.

## Instalar la base desde cero

```bash
docker run -d --name ce_oracle -p 1521:1521 -e ORACLE_RANDOM_PASSWORD=true gvenzl/oracle-free:slim-faststart
docker run -d --name ce_redis  -p 6379:6379 redis:7.4-alpine

# Claves de 8 a 30 caracteres (letra al inicio; letras, números y _). No se guardan en ningún archivo.
CONTENEDOR=ce_oracle CLAVE_PRODUCCION=... CLAVE_ECOMMERCE=... CLAVE_APP_WEB=... CLAVE_APP_ADMIN=... \
  ./base-de-datos/instalar.sh
```

El script corre, como SYSDBA dentro de la PDB:

1. El esquema.
2. La lógica.
3. La suite de pruebas de la base, que se deshace al terminar.
4. Las 18 migraciones.

Se detiene ante cualquier error de SQL, objeto que no compile o prueba
fallida, y nunca muestra las claves. Con Podman: `MOTOR=podman`.

## Levantar las APIs

Cada API tiene su `.env.example`. Se copia a `.env` (nunca se versiona) y se
completa:

```bash
cd api-tienda && npm ci && npm start                  # http://localhost:5050/api/v1
cd api-administracion && npm ci && npm run semilla && npm start   # http://localhost:5070/api/v1
```

`npm run semilla` crea el primer administrador con `ADMIN_CORREO` y `ADMIN_CLAVE`.

## Pruebas

| Comando | Qué prueba |
|---|---|
| `api-tienda`: `npm run humo` | 37 pruebas contra la API: catálogo, caché, carrito por pieza, pedidos |
| `api-tienda`: `npm run comparar-cache` | Que la caché (memoria + Redis) responda **idéntico** a Oracle |
| `api-tienda`: `npm run medir-cache` | Rendimiento con 32 clientes simultáneos |
| `api-administracion`: `npm run humo` | 83 pruebas: autenticación, permisos, productos, inventario por producto, compras en unidad del proveedor, ventas, cobros, reportes |

## Integración continua (GitHub Actions)

[`ci.yml`](.github/workflows/ci.yml) tiene tres jobs:

- **calidad:** se ejecuta por API y en Node 20 y 22. Revisa:
  - el lockfile exacto (`npm ci`);
  - el árbol de dependencias;
  - que la versión de Node cumpla `engines`;
  - la sintaxis de todo el código;
  - que Express y `oracledb` carguen.
- **seguridad:** `npm audit` de las dependencias de producción (severidad
  alta o más) y gitleaks sobre todo el historial.
- **integración:** Oracle y Redis corren como servicios. Instala la base
  desde cero con `instalar.sh`, siembra el administrador, levanta las dos APIs
  y corre los dos humos y la comparación de caché. Las claves se generan al azar
  en cada corrida y se enmascaran en el log.

[`codeql.yml`](.github/workflows/codeql.yml) hace el análisis estático de
seguridad del JavaScript. Dependabot propone las actualizaciones cada semana.

> `npm audit` informa una alerta **moderada** de `uuid`, que llega por Sequelize
> (GHSA-w5hq-g745-h8pq). Solo afecta a uuid v3/v5/v6 cuando se le pasa un buffer.
> Sequelize usa v4 sin buffer, y el único arreglo que ofrece npm es bajar a
> Sequelize 3, que rompe la API. Se revisa cuando Sequelize actualice su
> dependencia.

## Frontends

- Administración: <https://github.com/macalderonr07/frontend-RDA2>
- Tienda: <https://github.com/macalderonr07/frontend-e-commerce-RDA2>

Para que un front publicado use la API, la API necesita su dominio en
`CLIENT_ORIGIN` (CORS) y el front necesita la URL de la API. En la tienda es la
variable `CE_API_URL` del repositorio; en la administración, `ADMIN_API_URL`.
