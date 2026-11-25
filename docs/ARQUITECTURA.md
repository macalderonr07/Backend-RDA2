# Arquitectura del backend — API de Productos

Este documento explica la arquitectura que usa (y debe terminar de formalizar) este
backend: estilos arquitectónicos, patrón arquitectónico, patrones de diseño,
estructura de carpetas y convenciones. Sirve como referencia para extender el
proyecto a nuevos modelos sin romper las decisiones ya tomadas.

> Estado: la mayor parte de esto ya está implementado en `src/`. Donde falta algo
> (PATCH, Factory, Singleton explícito) se marca con **[PENDIENTE]** y se explica
> qué cambiaría.

## 1. Estilos arquitectónicos

### 1.1 Cliente-servidor
El backend es un proceso independiente (Node + Express) que expone una API HTTP.
No conoce ni le importa quién lo consume (un frontend web, Thunder Client, otro
servicio): solo recibe requests y responde JSON. Esto desacopla el ciclo de vida
del cliente del ciclo de vida del servidor — se pueden versionar y desplegar por
separado.

### 1.2 N-capas (layered architecture)
El código se organiza en capas horizontales, cada una solo conoce la capa
inmediatamente debajo:

```
Cliente HTTP
    ↓
Rutas        (routes/)      — mapea verbo+URL a un controlador
    ↓
Middleware   (middlewares/) — validación, sanitización, CORS, errores
    ↓
Controlador  (controllers/) — orquesta la petición, no sabe de SQL
    ↓
Modelo       (models/)      — única capa que conoce SQL/PostgreSQL
    ↓
PostgreSQL
```

Regla dura: una capa nunca salta a otra que no sea la inmediata inferior. El
controlador nunca arma SQL (eso es fuga de la capa de datos hacia la capa de
negocio) y el modelo nunca construye una respuesta HTTP (fuga en sentido
contrario). Ejemplo real de esto ya aplicado:
[`productos.controller.js`](src/controllers/productos.controller.js) solo llama
a funciones de [`producto.model.js`](src/models/producto.model.js); el modelo es
el único archivo del proyecto con un `SELECT`/`INSERT`/`UPDATE`/`DELETE`.

### 1.3 REST
- Los recursos son sustantivos en plural (`/productos`), no verbos.
- El verbo HTTP expresa la acción: `GET` lee, `POST` crea, `PUT`/`PATCH`
  actualizan, `DELETE` elimina.
- Sin estado en el servidor entre requests (stateless): cada request trae todo lo
  necesario para procesarse (params, body, query), no hay sesión en memoria.
- Los códigos de estado HTTP son parte del contrato, no un detalle — ver sección 5.

## 2. Patrón arquitectónico: MVC (adaptado a API REST)

En una API sin vistas HTML, el rol de la "Vista" lo cumple la **serialización
JSON de la respuesta**, no una plantilla:

| MVC clásico | En este backend |
|---|---|
| Model | `models/*.model.js` — acceso a datos |
| View | el `res.status(...).json({ status, data, meta })` que arma el controlador |
| Controller | `controllers/*.controller.js` — orquesta Model → respuesta |

El controlador es el único lugar que decide el `status` HTTP y la forma del
JSON de salida. Mantener ese contrato de respuesta (`{ status, data, meta? }` en
éxito, `{ status: "error", message, detalles? }` en error) igual en todos los
modelos es lo que hace que el cliente pueda tratar cualquier endpoint de la API
de la misma forma.

## 3. Patrones de diseño

### 3.1 Repository (capa de modelo)
Cada archivo `models/<modelo>.model.js` es un **Repository**: expone funciones
con nombre de dominio (`listarProductos`, `buscarProductoPorId`,
`crearProducto`, `actualizarProducto`, `eliminarProducto`) que esconden el SQL
detrás de una interfaz estable. El controlador depende de esa interfaz, no de
cómo está escrita la query — se puede cambiar de `pg` a otro driver, o reescribir
una query, sin tocar un solo controlador.

Regla de seguridad que vive en este patrón: **todas las queries son
parametrizadas** (`$1, $2, ...`), nunca concatenación de strings con datos del
usuario → es la barrera principal contra inyección SQL (ver
[`producto.model.js`](src/models/producto.model.js)).

Nota de implementación actual: el Repository está escrito como **funciones
exportadas**, no como una clase `class ProductoRepository { ... }`. Es
Repository igual (la interfaz importa, no la sintaxis), pero si la cátedra pide
explícitamente la forma orientada a objetos, cada modelo pasaría a ser una clase
con esos mismos métodos.

### 3.2 Singleton (conexión a base de datos)
[`config/db.js`](src/config/db.js) crea **un único** `Pool` de `pg` a nivel de
módulo (`export const pool = new Pool({...})`) y cada modelo lo importa. Como
los módulos ES/CommonJS se cachean, `import { pool } from "../config/db.js"`
siempre devuelve la misma instancia — nunca se abre un pool nuevo por request.
Esto ya es un Singleton en la práctica: Node garantiza una sola evaluación del
módulo.

**[PENDIENTE opcional]** Si se quiere un Singleton explícito y defendible en la
sustentación (no solo "Node lo cachea"), envolver el pool en una clase con
instancia privada:

```js
// src/config/db.js
class ConexionDB {
    static #instancia;

    static obtenerInstancia() {
        if (!ConexionDB.#instancia) {
            ConexionDB.#instancia = new Pool({ host: process.env.PGHOST, /* ... */ });
        }
        return ConexionDB.#instancia;
    }
}

export const pool = ConexionDB.obtenerInstancia();
```
El resto del código (modelos) no cambia: siguen importando `pool` igual.

### 3.3 Factory (comunicación entre capas)
Usar un Factory para estandarizar **cómo se construyen las respuestas y los
errores** que viajan entre capas, en vez de que cada controlador arme el objeto
de respuesta a mano. Hoy cada controlador escribe
`res.status(200).json({ status: "success", data, meta })` de forma repetida;
un Factory centraliza esa construcción:

```js
// src/factories/respuesta.factory.js
export const RespuestaFactory = {
    exito(data, meta = null) {
        return { status: "success", data, ...(meta ? { meta } : {}) };
    },
    error(message, detalles = null) {
        return { status: "error", message, ...(detalles ? { detalles } : {}) };
    },
};
```

```js
// en el controlador
res.status(200).json(RespuestaFactory.exito(producto));
```

Esto es lo que en el enunciado se pide como "patrón de diseño Factory para la
comunicación entre capas": el controlador no construye el objeto de respuesta
inline, se lo pide a una fábrica que garantiza que todos los endpoints —
presentes y futuros, de cualquier modelo— devuelven la misma forma. **[PENDIENTE]**:
ya existe el mismo problema resuelto a medias con `AppError` (toda excepción
operacional se construye vía `new AppError(message, statusCode)` en
[`AppError.js`](src/utils/AppError.js) y el `errorHandler` central la serializa) —
ese `AppError` ya actúa como una mini-factory de errores; falta el equivalente
para las respuestas de éxito.

## 4. Estructura de carpetas

```
api-productos/
  .env                      # config real (nunca se commitea)
  .env.example              # plantilla de variables, sí se commitea
  package.json
  src/
    server.js               # arranca Express en el puerto (PORT, default 5050)
    app.js                  # ensambla middlewares globales + monta routers
    config/
      db.js                 # Pool de PostgreSQL (Singleton)
    routes/
      v1/
        productos.routes.js # un archivo de rutas POR MODELO
        <otromodelo>.routes.js
    middlewares/
      cors.js                # CORS configurable por env
      correlation.js         # id de correlación por request (trazabilidad)
      errorHandler.js        # 404 + error handler central
      validar<Modelo>.js      # validación + sanitización con express-validator
    controllers/
      productos.controller.js # un archivo de controlador POR MODELO
      <otromodelo>.controller.js
    models/
      producto.model.js       # un archivo de modelo/Repository POR MODELO
      <otromodelo>.model.js
    utils/
      AppError.js             # error operacional tipado
```

Convención al agregar un modelo nuevo: siempre se crean los 3 archivos en
paralelo — `routes/v1/<modelo>.routes.js`, `controllers/<modelo>.controller.js`,
`models/<modelo>.model.js` — y se monta el router en `app.js` con su propio
prefijo (`/api/v1/<modelo>`).

## 5. Middleware

Orden de montaje en [`app.js`](src/app.js) (el orden importa en Express):

1. **`express.json()`** — parsea el body como JSON; si el JSON está mal formado,
   Express lanza un error que cae directo al `errorHandler` (no hay que
   verificarlo a mano en cada controlador).
2. **CORS** (`middlewares/cors.js`) — origen permitido configurable por
   `CLIENT_ORIGIN` en `.env`, nunca `*` abierto por defecto en producción.
3. **Correlación** (`middlewares/correlation.js`) — id único por request para
   poder rastrear un error en los logs.
4. **Logging** (`morgan`) — método, URL, status, tiempo de respuesta.
5. **Routers versionados** (`/api/v1/...`) — ver "Versionamiento" abajo.
6. **`notFoundHandler`** — cualquier ruta no mapeada cae en 404 estandarizado.
7. **`errorHandler`** — único lugar que decide el status code final y serializa
   el error; distingue error operacional (`AppError`, status propio) de error no
   operacional (bug/fallo de infra → 500 genérico, no se filtra el detalle al
   cliente).

Dentro de cada ruta, middleware específico por modelo
(`middlewares/validar<Modelo>.js` con `express-validator`):

- **Validación**: tipos y presencia (`notEmpty`, `isInt`, `isFloat`, `isURL`,
  `isLength`).
- **Sanitización**: `trim()` + `escape()` en campos de texto libre (previene
  XSS si ese dato se vuelve a renderizar en un cliente). Excepción deliberada:
  campos URL no llevan `escape()` porque rompería la URL — en su lugar se
  restringen a `isURL({ protocols: ["http","https"], require_protocol: true })`
  para bloquear esquemas peligrosos (`javascript:`, `data:`).
- **`manejarValidacion`**: si `validationResult` encuentra errores, construye un
  `AppError(..., 422)` con el detalle de cada campo y lo pasa a `next(err)` —
  nunca responde el error inline en la ruta.

**Paginación**: los parámetros de paginación (`page`) se validan como
middleware (`reglasPaginacion` en `validarProducto.js`), pero el cálculo de
`offset`/`limit` y el armado de `meta` (`totalItems`, `totalPages`) vive hoy en
el controlador (`productos.controller.js`). **[PENDIENTE opcional]**: si se
quiere paginación 100% como middleware reutilizable entre modelos, extraer un
`middlewares/paginacion.js` que lea `req.query.page`/`limit` y deje
`req.paginacion = { limit, offset }` listo para que cualquier controlador lo
consuma, en vez de repetir `TAMANO_PAGINA`/el cálculo de `offset` en cada
controlador.

**Versionamiento**: se hace por URL (`/api/v1/productos`), montando cada router
versionado desde `routes/v1/...`. Agregar una v2 de un recurso significa crear
`routes/v2/<modelo>.routes.js` y montarla en paralelo en `app.js` sin tocar v1 —
los clientes viejos no se rompen.

## 6. Controladores

Un archivo de controlador por modelo, con como mínimo estas acciones y sus
códigos HTTP:

| Acción | Verbo | Éxito | Casos de error típicos |
|---|---|---|---|
| Listar | `GET /` | `200` + `{ data: [...], meta }` | — |
| Obtener por id | `GET /:id` | `200` + `{ data }` | `404` si no existe |
| Crear | `POST /` | `201` + `{ data }` (el recurso creado) | `422` validación |
| Reemplazar | `PUT /:id` | `200` + `{ data }` | `404` si no existe, `422` validación |
| Actualizar parcial | `PATCH /:id` | `200` + `{ data }` | `404` si no existe, `422` validación |
| Eliminar | `DELETE /:id` | `204` sin body | `404` si no existe |

**[PENDIENTE]**: el controlador actual de productos implementa `GET`, `POST`,
`PUT` y `DELETE`, pero no `PATCH`. La diferencia real con `PUT` (que ya hace
`UPDATE ... SET todas_las_columnas`): `PATCH` debe aceptar un body parcial y
armar el `UPDATE` solo con las columnas presentes, no pisar con `null` lo que no
vino en el body. Esto implica una query dinámica en el modelo (o un
`COALESCE($n, columna)` por campo) en vez del `UPDATE` fijo que usa `PUT` hoy —
se agrega cuando se necesite actualización parcial real, para no incorporar una
rama de código sin un caso de uso que la ejerza.

Regla de seguridad en todos los controladores: nunca devolver el error crudo al
cliente (`err.message` de un error no operacional puede filtrar detalles de
infraestructura) — siempre `next(err)` y dejar que `errorHandler` decida qué
exponer.

## 7. Variables de entorno (`.env`)

Toda configuración global vive en `.env` (nunca hardcodeada ni commiteada; ver
`.env.example` como plantilla):

```
PORT=5050
CLIENT_ORIGIN=http://localhost:5500   # nunca "*" en producción

PGHOST=localhost
PGPORT=5432
PGUSER=postgres
PGPASSWORD=
PGDATABASE=productos_db
```

Al agregar un modelo nuevo no se agregan variables de entorno nuevas salvo que
ese modelo necesite una integración externa propia (otra API, otro servicio) —
la conexión a PostgreSQL y el puerto son globales y ya están centralizados.

## 8. Buenas prácticas de seguridad aplicadas

- SQL parametrizado en el 100% de las queries (anti inyección SQL).
- Sanitización de texto libre con `escape()` (anti XSS reflejado).
- Validación estricta de tipos antes de llegar al modelo (`toInt`, `toFloat`).
- CORS con origen explícito por entorno, no abierto por defecto.
- Errores no operacionales nunca exponen detalle interno al cliente (solo se
  loguean server-side con el id de correlación).
- Separación error operacional (`AppError`, 4xx esperables) vs. error de
  infraestructura (500 genérico) para no filtrar stack traces ni mensajes de
  PostgreSQL al cliente.
