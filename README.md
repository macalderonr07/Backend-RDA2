# Backend RDA2 — API de Productos

API REST en **Node.js 22 + Express 5 + PostgreSQL** con arquitectura por capas
(rutas → controladores → modelos → base de datos), validación con
`express-validator` y manejo centralizado de errores.

- Repositorio del frontend: <https://github.com/macalderonr07/frontend-RDA2>
- Despliegue del backend: **Render** (`render.yaml`, servicio `backend-rda2`)
- Verificación automática: GitHub Actions (`.github/workflows/ci.yml`)

## Endpoints

| Método | Ruta | Descripción |
| --- | --- | --- |
| GET | `/` | Salud del servicio |
| GET | `/api/v1/productos?page=1&q=texto` | Listado paginado (100 por página) |
| GET | `/api/v1/productos/:id` | Producto por id |
| POST | `/api/v1/productos` | Crear producto |
| PUT | `/api/v1/productos/:id` | Actualizar producto |
| DELETE | `/api/v1/productos/:id` | Eliminar producto |

Respuesta correcta: `{ "status": "success", "data": ..., "meta": ... }`.
Error: `{ "status": "error", "message": ..., "detalles": [...] }` con el código
HTTP correspondiente (400/404/422/500). Todas las respuestas traen
`x-correlation-id` para rastrear un pedido en los logs.

## Variables de entorno

Copiar `.env.example` a `.env`. Dos formas de configurar la base:

1. `DATABASE_URL` (una sola cadena; es lo que inyecta Render).
2. Variables `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE` (local).

`CLIENT_ORIGIN` define el/los orígenes permitidos por CORS, separados por coma.
`PGSSL=true` fuerza SSL cuando la base está fuera de la red interna del PaaS.

## Uso local

```bash
npm ci
npm run db:setup     # crea la tabla y siembra 1000 productos
npm run dev          # http://localhost:5050
npm run verificar    # sintaxis + humo HTTP, sin base de datos
```

## Verificación (CI)

`npm run verificar` revisa la sintaxis de todo `src/` y levanta la app real en
un puerto efímero para comprobar: salud, validación de entrada (422), 404,
CORS/preflight y `x-correlation-id`. En GitHub Actions además se corre
`npm audit --omit=dev --audit-level=high` y se reportan las versiones instaladas.

## Despliegue en Render

1. En Render: **New → Blueprint**, elegir este repositorio. Render lee
   `render.yaml`, crea la base `productos-db` y el servicio `backend-rda2`
   con `AUTO_SETUP=true`.
2. La siembra inicial (1000 productos) ocurre **sola al arrancar**: no hace
   falta la Shell, que en el plan free no existe. Es idempotente, así que los
   reinicios no duplican filas.
3. URL resultante: `https://backend-rda2.onrender.com`.
4. El frontend toma esa URL desde la variable `API_URL` del repositorio de
   GitHub Pages (`frontend-RDA2 → Settings → Variables`).

Alternativa sin `AUTO_SETUP`: sembrar desde tu máquina con la *External
Database URL* de Render:

```bash
export DATABASE_URL="postgres://...@dpg-xxxx.oregon-postgres.render.com/productos_db?sslmode=require"
npm run db:setup
```

Nota: el plan free de Render duerme el servicio tras un rato sin tráfico; la
primera petición después de dormir tarda unos segundos en responder.
