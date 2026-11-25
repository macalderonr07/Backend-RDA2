# API de administración de Comercial Elite (Express + Sequelize sobre Oracle)

Backend del sistema de administración: catálogo de productos, inventario,
compras, ventas en tienda, talento humano, usuarios y reportes. Sigue la
arquitectura de [`docs/ARQUITECTURA.md`](../docs/ARQUITECTURA.md):
cliente-servidor, N-capas, REST versionado (`/api/v1`), MVC adaptado a API,
**Repository**, **Singleton** y **Factory**, con **Sequelize** como capa ORM.

## Lugar en la base de datos

La base Comercial Elite tiene dos nodos. La tienda en línea es la aplicación
del nodo **e-commerce** (`app_web`, rol `ELITE_ECOMMERCE`); esta API es la del
nodo **producción**:

- Se conecta como **`app_admin`**, que no es dueño de nada: solo recibe el rol
  `ELITE_PRODUCCION` (`db/11_administracion.sql`).
- Las reglas de negocio **viven en la base**: stock, precios vigentes,
  reservas de bandas, descuentos por volumen, comprobantes y permisos por
  usuario. Todo lo que mueve stock o dinero pasa por sus funciones
  (`fn_crear_pedido`, `fn_recepcionar_compra`, `fn_registrar_ajuste`,
  `fn_facturar_pedido`, `fn_registrar_precio`...). El ORM se usa para los
  maestros y las lecturas; no reimplementa reglas.
- **Doble barrera de permisos**: la API exige el permiso del rol del usuario
  (`exigirPermiso`) y la base lo vuelve a exigir en cada función
  (`fn_exigir_permiso`).
- **Auditoría**: cada escritura es una transacción que primero fija el usuario
  de la sesión en la base (`fn_usuario_sesion`). Los disparadores de auditoría
  registran quién hizo qué. Como las conexiones del pool se reutilizan entre
  peticiones, el usuario se fija siempre, nunca se asume.

## Instalación

Requisitos: Node 20+ y la base Comercial Elite instalada en el contenedor
`bd2_oracle`, con las migraciones 06–10 de `proyecto/servidor/db`.

```bash
podman start bd2_oracle

# 1. Usuario de la base, permisos y datos esenciales (provincias y ciudades
#    del Ecuador, unidades, empresa, puntos de emisión, transportistas, proveedores)
sqlplus system@//localhost:1521/FREEPDB1 @db/11_administracion.sql "<clave de app_admin>"

# 2. Configuración
cp .env.example .env     # ORACLE_PASSWORD (la del paso 1), JWT_SECRETO (32+ caracteres),
                         # ADMIN_CORREO y ADMIN_CLAVE del primer administrador
npm install

# 3. Primer administrador (rol ADMIN + ficha de empleado; la clave solo se guarda como hash)
npm run semilla

# 4. API
npm start                # http://localhost:5070

# 5. Prueba de humo (con la API corriendo): 55 pruebas de punta a punta
npm run humo
```

> **Puerto**: 5070, no 5060. El 5060 (SIP) está en la lista de puertos
> prohibidos del estándar fetch: ni Node ni los navegadores se conectan a él.

Si cambia el esquema de la base: `npm run modelos` regenera los modelos.

## Modelos generados del diccionario de datos

`src/models/tablas.generado.js` lo produce `scripts/generar-modelos.mjs`
leyendo `all_tab_columns` y `all_constraints` de Oracle. Son 61 modelos con
tipos, longitudes, nulos, claves e identidad exactos de la base. Las columnas
con `DEFAULT` las completa la base, y los `NUMBER(p,s)` se devuelven como
número. Los atributos usan el nombre de la columna sin el prefijo de tabla, en
camelCase: `PRD_NOMBRE` pasa a `nombre`, `ID_CATEGORIA` a `idCategoria`.

Las **asociaciones**, que dan significado al modelo, se escriben a mano en
`src/models/index.js`.

## CRUD genérico por registro de recursos

Las tablas de catálogo y maestros (provincias, ciudades, unidades, marcas,
categorías, atributos, proveedores, clientes, datos de facturación,
empleados, puntos de emisión, descuentos por volumen...) se describen **una
vez** en `src/recursos/registro.js`: campos, tipo, regla, relación y permiso.
De esa descripción salen:

- la **validación** del servidor (`middlewares/validarRecurso.js`), que rechaza
  los campos que el recurso no expone;
- el **Repository** genérico (`repositories/recurso.repository.js`), con
  búsqueda sin distinguir mayúsculas y sin comodines, más paginación y
  filtros;
- las **rutas REST** (`GET / · GET /opciones · GET /:id · POST · PUT · PATCH · DELETE`);
- `GET /api/v1/meta`, que publica todo eso y las expresiones regulares
  (`utils/patrones.js`). Con eso el frontend arma formularios que validan
  **exactamente** lo mismo que el servidor.

La identificación se valida según su tipo SRI: la cédula, con su dígito
verificador.

## Endpoints

Todos bajo `/api/v1`, con `Authorization: Bearer <token>` salvo `auth/ingresar`
y `salud`. Respuesta: `{ status, data, meta? }` o `{ status: "error", message, detalles? }`.

| Módulo | Endpoints | Permiso de escritura |
|---|---|---|
| Autenticación | `POST /auth/ingresar` · `GET /auth/yo` · `PUT /auth/clave` | — |
| Catálogos (genérico) | `/<recurso>` y `/<recurso>/opciones` (ver `GET /meta`) | el del recurso |
| Productos | `GET/POST /catalogo/productos` · `GET/PATCH /catalogo/productos/:id` · `POST …/variantes` · `PATCH /catalogo/variantes/:id` · `POST/PATCH …/formas-de-venta` · `GET/POST …/precios` | CATALOGO_GESTIONAR, PRECIO_GESTIONAR |
| Ofertas y combos | `GET/POST /catalogo/ofertas` · `PATCH /catalogo/ofertas/:id` · `GET/POST/PUT/DELETE /catalogo/combos` | PRECIO_GESTIONAR, CATALOGO_GESTIONAR |
| Inventario | `GET /inventario/stock` · `GET /inventario/variantes/:id/lotes` · `GET …/kardex` · `POST /inventario/ajustes` · `POST /inventario/lotes/:id/fraccionar` · `POST /inventario/lotes/:id/devolver` | INV_AJUSTAR, INV_FRACCIONAR, COMPRA_GESTIONAR |
| Compras | `GET/POST /compras/ordenes` · `GET /compras/ordenes/:id` · `POST …/estado` · `POST …/recepciones` · `GET/POST /compras/comprobantes` · `GET /compras/por-facturar` | COMPRA_GESTIONAR, INV_RECEPCIONAR |
| Ventas | `GET/POST /ventas/pedidos` · `GET /ventas/pedidos/:id` · `POST …/pagos` · `POST …/factura` · `POST …/estado` · `GET /ventas/presentaciones` · `GET /ventas/cuentas-por-cobrar` · `POST /ventas/abonos` | VENTA_REGISTRAR, PAGO_REGISTRAR, VENTA_FACTURAR, PEDIDO_DESPACHAR |
| Seguridad | `GET/POST /seguridad/usuarios` · `GET/PATCH /seguridad/usuarios/:id` · `PUT …/clave` · `GET /seguridad/roles` | USUARIO_GESTIONAR |
| Reportes | `GET /reportes/resumen` · `GET /reportes` · `GET /reportes/:nombre` (solo nombres registrados) | — |

Decisiones de negocio que conviene conocer:

- **Usuarios**: no se borran, se desactivan, porque la auditoría los
  referencia. Al desactivar a alguien, pierde el acceso **de inmediato**: el
  perfil se recarga de la base en cada petición. Nadie puede desactivarse ni
  quitarse el rol de administrador a sí mismo.
- **Vendedores**: para registrar ventas, el usuario necesita su ficha de
  **empleado**. La base guarda al vendedor como empleado del pedido.
- **Productos**: el alta crea en una transacción las variantes (una por
  combinación de valores de atributo, por ejemplo color × talla), las formas
  de venta (factor en unidad base, mínimo e incremento) y sus precios. Un
  precio nuevo nunca pisa el anterior: va al historial.
- **Precios con IVA**: la API recibe y muestra el precio **con IVA**
  (`precioConIva`), que es lo que paga el cliente. La base guarda la base sin
  IVA en centavos, porque la factura desglosa el IVA. La conversión la hace
  `fn_base_desde_final`, la misma función del mostrador. Los **costos de
  compra** siguen sin IVA, porque el IVA de compras es crédito tributario.
- **Códigos automáticos**: no se escriben ni se editan (`src/utils/codigos.js`).
  - Una subcategoría toma el código del padre y el número siguiente (`suelas-3`).
  - Una línea toma la primera palabra del nombre (`pega`).
  - Un producto toma `CE-` y el siguiente número del bloque de mil de su línea
    (por ejemplo `CE-3007` en suelas).
  - Un combo toma `CMB-0001`, `CMB-0002`…
- **Atributos por categoría**: el asistente ofrece los atributos de la
  categoría y de su línea. Si se usa otro atributo, se agrega a la categoría
  en la misma transacción. La base exige que el atributo esté definido.
- **Cambio de clave**:
  - Pide la clave actual.
  - Tras 5 intentos fallidos en 15 minutos responde 429.
  - Rechaza una clave igual a la actual o que contenga el correo.
  - El token lleva una huella de la clave: al cambiarla, todas las sesiones
    abiertas quedan inválidas (401).
- **Recepción por piezas**: en productos por pieza (bandas de cuero, planchas
  de fibra) se envía una línea por pieza con su medida, y cada una entra como
  su propio lote.
- **Ventas de mostrador**: sin envío, un pedido facturado pasa a entregado,
  no por despachado. Es una regla de la base.

## Reportes y tableros (contrato para dashboards)

Los reportes viven en `src/repositories/reporte.repository.js`. Cada uno
declara la pregunta que responde, su categoría, sus parámetros, sus columnas
con tipo (`texto`, `fecha`, `dinero`, `numero`, `porcentaje`; `sumar: true` si
lleva total) y un visual sugerido (`barras`, `linea` o `tabla`, con sus ejes
`x` e `y`).

| Ruta | Respuesta |
|---|---|
| `GET /reportes` | Catálogo: `[{ id, titulo, pregunta, categoria, parametros, visual, columnas }]` y `meta.categorias`. |
| `GET /reportes/:id?desde&hasta&agrupar` | `data`: filas. `meta`: `{ reporte, parametros, totales, totalItems, generado }`. |
| `GET /reportes/indicadores?desde&hasta` | KPI: `[{ clave, titulo, valor, tipo, anterior, variacion, mejorSi, ayuda, enlace }]`, comparados con el período anterior de igual largo. |
| `GET /reportes/tableros` | Tableros: `[{ id, titulo, widgets: [{ tipo: "indicadores" \| "reporte", reporte, ancho, limite }] }]`. |

- **Período**: por defecto son los últimos 30 días; el máximo, 3 años.
- **Agrupación**: `dia`, `semana` o `mes`, elegida según el largo del período.
- **Seguridad**: el id del reporte se busca en la lista, las fechas van como
  binds y la agrupación sale de un mapa fijo.
- **Agregar un reporte**: una entrada más en `REPORTES`.
- **Agregar un tablero**: una entrada más en `TABLEROS`. El front los pinta
  solo, a partir de los metadatos.

## Estructura

```
db/11_administracion.sql     usuario app_admin, permisos, datos esenciales
scripts/generar-modelos.mjs  modelos Sequelize desde el diccionario de Oracle
scripts/semilla-admin.mjs    primer administrador
scripts/humo.mjs             prueba de humo de punta a punta
src/
  server.js, app.js          arranque y ensamblado (json, CORS, correlación, log, routers, 404, errores)
  config/env.js, db.js       .env y Singleton de Sequelize; conUsuario / llamar / consulta
  models/                    tablas.generado.js + index.js (asociaciones)
  recursos/registro.js       descripción de los recursos con CRUD genérico
  repositories/              Repository: única capa con ORM o SQL (binds siempre)
  controllers/               status HTTP + Factory de respuesta; sin SQL
  routes/v1/                 rutas versionadas con su validación y permiso
  middlewares/               autenticacion, errorHandler, validación, paginación, CORS, correlación
  utils/                     AppError, clave (scrypt), patrones (regex compartidas, cédula)
```
