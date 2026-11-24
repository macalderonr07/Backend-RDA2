# Servidor Comercial Elite (API e-commerce sobre Oracle)

API REST del e-commerce de Comercial Elite. Sigue la arquitectura de
[`Mi_servidor/api-productos/ARQUITECTURA.md`](../../Mi_servidor/api-productos/ARQUITECTURA.md):
cliente-servidor, N-capas, REST, MVC adaptado a API, Repository, Singleton y Factory.
Consume la base **Comercial Elite v5** (Oracle) y la usa el frontend
`negocio tailwind/comercial-elite`.

## Lugar en la base de datos

La base está dividida en dos nodos. Esta API es la **aplicación del nodo
e-commerce**, tal como lo prevé la sección E de `ComercialElite_Oracle_2_logica.sql`:

- Se conecta como `app_web`, que **solo** tiene el rol `ELITE_ECOMMERCE`, y
  trabaja con `CURRENT_SCHEMA = ECOMMERCE`.
- **Lee** el catálogo por `v_catalogo_web`: precio vigente, IVA, oferta y stock
  ya calculados por la base (3FN: la API no recalcula precios).
- **Escribe** solo en sus tablas (`carrito`, `item_carrito`).
- No ve las tablas de producción. Un `UPDATE produccion.producto` desde
  `app_web` da `ORA-00942`: un fallo en la API no alcanza stock, dinero ni
  comprobantes.

Por eso productos y categorías son de **solo lectura** aquí (el catálogo lo
administra producción), y el CRUD completo se hace sobre **carritos**.

El resto de la lógica del e-commerce también es la de la base, no una copia en
la API:

- **Checkout**: identificar al cliente del carrito usa
  `produccion.fn_registrar_cliente` (si el correo ya compraba en tienda,
  conserva su historial) y confirmar el carrito llama
  `fn_crear_pedido_desde_carrito`, que crea el pedido `WEB` en producción con
  el **precio y la oferta vigentes** y valida existencias. El carrito queda
  cerrado como traza del pedido y su token pasa a ser la credencial para
  seguir el estado (`v_pedido_web`).
- **Cuentas**: `fn_registrar_cuenta_web` crea el cliente en producción y la
  cuenta en este nodo; la API solo aporta el hash de la clave (scrypt,
  `utils/clave.js`) porque así lo reparte el modelo: la base guarda el hash y
  registra cada intento de acceso (`fn_registrar_acceso_web` → bitácora
  `log_evento_web` + último acceso).

### Cambio en la base: imagen por URL

Se agregó la columna **`producto.prd_imagen_url`** (`VARCHAR2(500)`, `NULL`), con
`CHECK` que solo admite `http://` o `https://` (bloquea `javascript:` y `data:`).
También se agregaron columnas al final de `v_catalogo` (`imagen_url`, `uso`,
`categoria_codigo`, `linea_codigo`, `linea` y `fecha_creacion`) y la columna se
añadió a la auditoría de `producto`. El cambio está replicado en PostgreSQL
(`PDM` + `logica`) y verificado en los dos motores (Oracle: instalación limpia y
prueba de humo 38/38; PostgreSQL: 150/150).

## Instalación

Requisitos: Node 20+, contenedor Oracle `bd2_oracle` (gvenzl/oracle-free, PDB `FREEPDB1`).

```bash
podman start bd2_oracle

# 1. Base (solo la primera vez), desde la carpeta de los scripts Oracle:
#    sqlplus system@//localhost:1521/FREEPDB1 @ComercialElite_Oracle_0_instalar.sql

# 2. Usuario de la app (la clave debe coincidir con ORACLE_PASSWORD del .env)
sqlplus system@//localhost:1521/FREEPDB1 @db/01_usuario_app.sql "<clave>"

# 3. Catálogo inicial (generado desde data/catalogo.json del frontend)
npm run db:generar-catalogo      # regenera db/02_catalogo_inicial.sql
sqlplus system@//localhost:1521/FREEPDB1 @db/02_catalogo_inicial.sql

# 4. Inventario inicial (ajuste INI por variante con fn_registrar_ajuste;
#    deja algunas variantes agotadas a propósito para probar la tienda)
sqlplus system@//localhost:1521/FREEPDB1 @db/03_inventario_inicial.sql

# 4b. Cuero por pieza: bandas medidas, precios por pie2 y v_pieza_web
sqlplus system@//localhost:1521/FREEPDB1 @db/06_cuero_por_pieza.sql
# 4c. Tallas (suelas, plantillas) y presentaciones de hebillas, ojalillos y galón
sqlplus system@//localhost:1521/FREEPDB1 @db/07_tallas_y_presentaciones.sql
# 4d. Línea "Cierres y llaves" y combos (tablas combo / combo_componente)
sqlplus system@//localhost:1521/FREEPDB1 @db/08_cierres_llaves_combos.sql
# 4e. Marcas, descuento por volumen, incrementos de venta, sintético por metro, combo único
sqlplus system@//localhost:1521/FREEPDB1 @db/09_marca_volumen_incrementos.sql
# 4f. La banda vendida queda reservada (cada banda es su propia línea)
sqlplus system@//localhost:1521/FREEPDB1 @db/10_pieza_reservada.sql

# 4g. Rendimiento: indices, stock por variante, saldo por lote (16, 17)
#     y outbox del catalogo para la cache Redis (18)
sqlplus system@//localhost:1521/FREEPDB1 @db/16_indices_y_stock.sql
sqlplus system@//localhost:1521/FREEPDB1 @db/17_saldo_por_lote.sql
sqlplus system@//localhost:1521/FREEPDB1 @db/18_outbox_catalogo.sql

# 5. Redis (cache del catalogo; opcional: sin el, todo se lee de Oracle)
podman run -d --name ce_redis -p 6379:6379 docker.io/library/redis:7.4-alpine

# 6. API
cp .env.example .env             # completar ORACLE_PASSWORD
npm install
npm start                        # http://localhost:5050

# 7. Pruebas (con la API corriendo)
npm run humo                     # contrato completo + sincronia de la cache
npm run comparar-cache           # la cache responde identico a Oracle
npm run medir-cache              # carga: Oracle vs Redis
```

## Caché del catálogo (Redis principal, Oracle de respaldo)

Solo las dos lecturas más pesadas y frecuentes pasan por la caché:
`GET /productos` y `GET /productos/:codigo`. El carrito, los pedidos y las cuentas
siguen yendo directo a Oracle, y es Oracle quien valida el stock al vender.

```
petición ─► memoria del proceso (L1) ─► Redis (L2) ─► Oracle (v_catalogo_web)
                ~0 ms                     ~1 ms          respaldo / fuente de verdad
```

- **Sincronía:** cada cambio que altera el catálogo anota el producto en
  `produccion.catalogo_cambio`, dentro de la misma transacción. Las fuentes son
  el kárdex, los precios, las reservas, los estados de pedido, los datos del
  producto y las categorías y marcas. El worker (`src/cache/sincronizador.js`):
  1. revisa la outbox cada 200 ms;
  2. reconstruye solo esos productos;
  3. los escribe en Redis;
  4. avisa por pub/sub para que cada instancia limpie su memoria.

  Retraso medido: unos 0,3 s desde el COMMIT.
- **Cambios por tiempo:** las ofertas que empiezan o vencen, los precios
  programados y las novedades que caducan no escriben nada en la base. El job
  `JOB_CATALOGO_VENCIMIENTOS` las anota cada minuto.
- **Fallas:** si Redis no está, se cae o le falta un documento, la respuesta
  sale de Oracle (header `X-Cache: ORACLE`). Cuando Redis vuelve vacío, el worker
  lo recarga solo. `GET /salud` informa el estado de la caché.
- **Varias instancias:** solo trabaja el worker que tiene el candado en Redis.
- **Red de seguridad:** hay una reconstrucción completa cada 30 min
  (`CACHE_RECONCILIAR_MIN`).
- **Header `X-Cache`:** `MEMORIA`, `REDIS` u `ORACLE`, para ver de dónde salió
  cada respuesta.

Medido en esta API, con 32 clientes simultáneos (`npm run medir-cache`):

| Consulta | Solo Oracle optimizado | Redis + memoria |
|---|---|---|
| Listado (12 por página) | 49 req/s · p95 1.339 ms | 1.372 req/s · p95 41 ms |
| Ficha de producto | 523 req/s · p95 99 ms | 2.324 req/s · p95 24 ms |

La simulación a 50.000 productos y el diseño completo están en
`db/bench/simulacion/INFORME.md`.

Si no tienes `sqlplus` local, usa el del contenedor:
`podman cp db/01_usuario_app.sql bd2_oracle:/tmp/` y luego
`podman exec -it bd2_oracle sqlplus system@//localhost:1521/FREEPDB1 @/tmp/01_usuario_app.sql "<clave>"`.

Frontend: en `negocio tailwind/comercial-elite`, `npm run serve` (puerto 8080, ya
incluido en `CLIENT_ORIGIN`). En `localhost`, `js/api.js` usa la API. Si la API no
responde, o en GitHub Pages, usa `data/catalogo.json` como respaldo.

## Endpoints (`/api/v1`)

| Verbo | Ruta | Éxito | Errores |
|---|---|---|---|
| GET | `/salud` | 200 (consulta la base) | 500 |
| GET | `/categorias` | 200 líneas con productos publicados | — |
| GET | `/combos?producto=` | 200 combos: componentes y, por color disponible en todos, precio (suma) y cuántos se arman | 422 |
| GET | `/combos/:codigo` | 200 un combo | 404, 422 |
| GET | `/productos?page&limit&linea&marca&q` | 200 + `meta` de paginación; cada producto trae marca, `descuentosVolumen` y, por presentación, `incremento` y `factor` | 422 |
| GET | `/productos/:codigo` | 200 | 404, 422 |
| POST | `/carritos` | 201 + `token` | — |
| GET | `/carritos/:token` | 200 líneas, precios vigentes y total | 404, 422 |
| DELETE | `/carritos/:token` | 204 | 404; 409 si ya es pedido |
| POST | `/carritos/:token/items` `{idPresentacion, cantidad, pieza?}` | 201 (agrega o suma; con `pieza`, la banda elegida es su propia línea) | 404, 409, 422 |
| PUT | `/carritos/:token/items` `{items:[...]}` | 200 (reemplazo atómico) | 404, 422 |
| PATCH | `/carritos/:token/items/:idPresentacion` `{cantidad}` | 200 | 404, 422 |
| DELETE | `/carritos/:token/items/:idPresentacion` | 204 | 404 |
| POST | `/carritos/:token/combos` `{codigo, color, cantidad?}` | 201 (entra como sus líneas, todo o nada) | 404, 409, 422 |
| POST | `/carritos/:token/cliente` `{nombres, apellidos?, correo, telefono?}` | 200 carrito identificado | 404, 422; 409 ya es pedido |
| POST | `/carritos/:token/pedido` `{observacion?}` | 201 pedido WEB (PENDIENTE) | 404, 422; 409 vacío / sin cliente / ya convertido / sin stock |
| GET | `/carritos/:token/pedido` | 200 estado y total actuales | 404, 422 |
| POST | `/cuentas` `{nombres, apellidos?, correo, telefono?, clave}` | 201 cuenta | 422; 409 correo ya registrado |
| POST | `/cuentas/sesion` `{correo, clave}` | 200 cuenta | 401 credenciales malas, 422 |

`q` busca sin distinguir mayúsculas ni tildes (`COLLATE BINARY_AI`) y trata `%` y
`_` como texto literal. Un carrito ya convertido en pedido lo bloquea la propia
base (`ORA-20001`), y la API lo devuelve como 409 con el mensaje de negocio.

## Estructura

```
db/
  01_usuario_app.sql        usuario app_web con el rol ELITE_ECOMMERCE
  generar-catalogo.mjs      data/catalogo.json -> 02_catalogo_inicial.sql
  02_catalogo_inicial.sql   GENERADO: líneas, productos, variantes por color, precios sin IVA,
                            unidad base real (pie2, m, l, kg, par, u), factor de cada presentación
                            e imagen por URL externa (Wikimedia Commons, mapa IMAGENES del generador)
  03_inventario_inicial.sql stock inicial (INI) en presentaciones x factor = unidad base
  04_v_catalogo_unidad.sql  migración: v_catalogo expone la unidad (solo bases ya instaladas)
  05_categoria_principal.sql migración: v_categoria_principal / v_categoria_web
                            (solo bases ya instaladas; una instalación nueva ya trae 04 y 05)
  06_cuero_por_pieza.sql    migración: el cuero se vende POR PIEZA — CE-1042/43 pasan a
                            prd_venta_por_pieza, el inventario se fracciona en bandas medidas
                            (18-29 pie2, fn_fraccionar_lote), presentaciones "Pie2 al detal" y
                            "Pie2 precio banda", vista v_pieza_web (bandas visibles en la tienda)
                            y v_catalogo expone venta_por_pieza
  07_tallas_y_presentaciones.sql migración: atributo Talla y una variante por color x talla en
                            suelas y plantillas (inventario redistribuido por el kárdex: AJN + INI);
                            hebillas por Unidad / 1/2 docena / Docena; ojalillos por Ciento o
                            Millar; galón también por Litro, 1/2 y 1/4 de litro
  08_cierres_llaves_combos.sql migración: línea "Cierres y llaves" (cierre por paquete de 100 m o
                            por metro; llaves x2, 1/2 docena, docena, 50, ciento) y COMBOS: tablas
                            combo / combo_componente (receta de presentaciones) y vista v_combo_web.
                            Un combo se vende como sus líneas: mismo checkout, precio y stock
  09_marca_volumen_incrementos.sql migración: marca (opcional) y v_proveedor_marca; presentacion.
                            pre_incremento (cuero de 0.25 en 0.25, lo demás enteros); sintético por
                            metro, 1/2 y 1/4 (rollo inactivo); descuento_volumen genérico por producto
                            (se aplica como la oferta: detalle_pedido.id_descuento_volumen y la rebaja
                            en v_detalle_pedido_valor); fn_crear_pedido valida el incremento y asigna
                            el escalón; combo único con color elegido al agregar
  10_pieza_reservada.sql    migración: la banda de cada línea queda RESERVADA (detalle_pedido.
                            id_lote_reservado) mientras el pedido está PEN/PAG; v_pieza_libre (saldo,
                            reservado, libre); la tienda ve lo libre; carrito y pedido llevan una línea
                            por banda (item_carrito.ica_pieza); la factura descuenta de la pieza
                            reservada; disponible en múltiplos del incremento (una banda de 28.5 se
                            ofrece entera, no 28)
src/
  server.js                 abre el pool antes de escuchar; lo cierra en SIGINT/SIGTERM
  app.js                    json -> CORS -> correlación -> morgan -> routers v1 -> 404 -> errores
  config/env.js             .env independiente del cwd; falla al arrancar si falta algo
  config/db.js              Singleton ConexionDB (pool oracledb, modo thin) + transaccion()
  factories/respuesta.factory.js   Factory de { status, data, meta } / errores
  middlewares/              cors, correlation, errorHandler (traduce ORA-200xx),
                            paginacion (reutilizable), validacion, validarProducto,
                            validarCarrito, validarCliente, validarCuenta
  routes/v1/                productos, categorias, carritos (incluye checkout), cuentas
  controllers/              deciden el status HTTP; sin SQL (productos, categorias,
                            carritos, pedidos, cuentas)
  models/                   Repository: único lugar con SQL, siempre con binds
                            (producto, categoria, carrito, pedido, cuenta)
  utils/                    AppError, caracteristicas (color de una variante),
                            clave (hash scrypt, sin dependencias nuevas)
```

## Seguridad aplicada

- SQL 100 % con binds (también la lista `IN` del carrito: un bind por id).
- Mínimo privilegio en la base: `app_web` solo tiene el rol del nodo e-commerce.
- CORS con orígenes explícitos; sin `CLIENT_ORIGIN` no se habilita ninguno.
- Los errores de Oracle nunca llegan crudos al cliente: los de negocio
  (`ORA-20001/20003`) pasan con su mensaje, los demás como 4xx/500 genéricos;
  el detalle queda en el log con el id de correlación.
- Validación de tipos y forma antes del modelo; body JSON limitado a 100 kB.
- Claves de cuenta con scrypt (`node:crypto`): la base solo guarda el hash y la
  clave nunca va a un SQL ni a un log.
- Login sin filtrar correos: mismo 401 exista o no la cuenta, y verificación
  contra un hash señuelo cuando no existe (tiempos parecidos); cada intento
  queda en la bitácora de la base (`fn_registrar_acceso_web`).
- El id interno del cliente nunca sale de la base: el carrito expone solo
  `clienteIdentificado` y el pedido se consulta con el token del carrito que lo
  originó (quien tiene el token sigue su pedido, nadie más).
