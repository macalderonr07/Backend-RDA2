# Simulación a escala: Oracle optimizado + caché NoSQL (Redis) sincronizada

Objetivo: responder rápido y con pocas peticiones al backend, sin que la copia
NoSQL se desactualice respecto de Oracle.

**Decisión de arquitectura:** Oracle optimizado (migración 16) **más** Redis delante.
No compiten, son dos capas:

| Capa | Qué hace | Dónde se escribe |
|---|---|---|
| **Oracle** (fuente de verdad) | Reglas de negocio (`fn_*`), kárdex, pedidos, precios. Responde cuando a Redis le falta un documento y cuando hay que reconstruirlo. | Todas las escrituras |
| **Redis** (copia de lectura) | Un documento JSON por producto + lista de códigos por categoría. Ficha y catálogo de la tienda. | Solo lo escribe el worker de sincronía |
| **Outbox** (`catalogo_cambio`) | Triggers anotan *qué producto cambió* dentro de la misma transacción. | Triggers de Oracle |

Si Redis se cae, el backend sigue funcionando leyendo de Oracle optimizado (más lento, pero correcto).

## Escenario simulado

El esquema `SIMULA` es aparte y no toca producción. Las tablas tienen las mismas
columnas que producción y las vistas son las **reales**: la de stock anterior a la
migración 16 y la optimizada.

| Tabla | Filas |
|---|---|
| producto | 50.000 |
| variante | 150.000 |
| presentacion | 300.000 |
| historial_precio | 450.000 |
| lote (1 de cada 10 es un corte) | 300.000 |
| detalle_movimiento (kárdex) | 900.000 |
| pedido / historial de estados | 200.000 / 500.000 |
| detalle_pedido | 600.000 |
| detalle_orden_compra | 60.000 |

Es unas 10 veces la primera medición (`../INFORME.md`) y varios cientos de veces la base actual.

Backend de prueba (`backend.mjs`): Node + `oracledb` (pool de 16) + `redis`, con las
dos lecturas que más usa la tienda: la **ficha de producto** y una **página de
categoría** (20 productos con variantes, presentaciones, precio vigente y disponible).
La carga (`carga.mjs`) son 32 clientes simultáneos durante 15 s por escenario, con
productos y categorías al azar. Cada camino se corrió por separado, esperando a que
Oracle no tuviera sesiones activas.

## Resultados

### Lecturas con carga (32 clientes simultáneos)

| Camino | Ficha: req/s | Ficha: p50 / p95 | Categoría: req/s | Categoría: p50 / p95 |
|---|---|---|---|---|
| Oracle, vista de stock **anterior** ¹ | 0,7 | 7.020 / 8.458 ms | 0,5 | 8.893 / 9.555 ms |
| Oracle **optimizado** (migración 16) | 730 | 22 / 54 ms | 38 | 994 / 1.529 ms |
| **Redis** (+ Oracle optimizado si falta) | **7.088** | **3,7 / 8,1 ms** | **3.370** | **9,2 / 12,3 ms** |

¹ Con 4 clientes: con 32 solo formaba cola (60 a 115 s por petición, con timeouts).

- **Ficha:** de 7 s a 22 ms con Oracle optimizado (×300). Redis da 10 veces más rendimiento que Oracle optimizado.
- **Categoría:** es la consulta que más gana con Redis (×88 en rendimiento). Oracle tiene que calcular stock y precio de unas 60 variantes por página, mientras que Redis lee 20 documentos ya armados con un solo `LRANGE` y un solo `MGET`.

### Sincronía Oracle → Redis (`sincronia.mjs`)

El worker revisa la outbox cada 200 ms y reconstruye solo los productos que cambiaron.

| Ritmo de ventas | Ventas | Retraso commit → Redis p50 / p95 / máx | Sin reflejar | Costo de escritura (p50) |
|---|---|---|---|---|
| 20/s durante 30 s | 597 | 127 / 227 / 380 ms | 0 | 4,9 ms |
| 100/s durante 20 s | 1.960 | 182 / 311 / 423 ms | 0 | 3,9 ms |

Costo del trigger en la escritura (5.000 inserciones al kárdex, sin COMMIT):

| | por fila |
|---|---|
| sin trigger | 0,068 – 0,074 ms |
| con trigger outbox | 0,084 – 0,090 ms |

Son +0,016 ms por fila, despreciable frente a los ~4 ms del COMMIT de una venta.

### Carga inicial y memoria

Los 50.000 productos entraron en Redis en **67 s** y ocupan **41 MB** de RAM
(unos 850 bytes por producto). Con el catálogo real (cientos de productos) la carga
inicial tardaría menos de 1 s.

## Hallazgo en el camino

En la primera corrida, Oracle optimizado tardaba 320 ms por ficha. El plan
(`DBMS_XPLAN.DISPLAY_CURSOR`) mostró que la causa era el **precio vigente**, no el stock:
escrito como subconsulta escalar `MAX(...) KEEP (DENSE_RANK LAST ...)`, Oracle la
"desanidaba" en un `GROUP BY` sobre los 450.000 precios en cada petición.
Reescrito como `OUTER APPLY (... ORDER BY ... FETCH FIRST 1 ROW ONLY)` baja por el
índice `(id_presentacion, hpr_vigente_desde)` y la ficha pasó a **6 ms**.

La vista real `v_precio_vigente` (con `ROW_NUMBER() OVER (PARTITION BY id_presentacion)`)
**no** tiene el problema: Oracle aplica el filtro de la presentación dentro de la ventana.
Medida a esta escala, tarda 10 ms y devuelve lo mismo que una versión con `CROSS APPLY`
(MINUS = 0 en ambos sentidos). No requiere migración.

**Lección:** medir con el plan real (`ALLSTATS LAST`) y con las columnas que de verdad
se piden. Un `COUNT(*)` puede saltarse columnas y hacer ver rápida una consulta que no lo es.

## Cómo se integraría en el backend real de la tienda (`proyecto/servidor`)

1. **Migración Oracle:** tabla `catalogo_cambio` + 4 triggers:
   - `detalle_movimiento`: trigger compuesto, una fila por sentencia;
   - `historial_precio`;
   - `detalle_pedido`: reservas;
   - `historial_estado_pedido`: pagar o cancelar libera o confirma reservas.

   El script es el mismo de `02_vistas_y_outbox.sql`. Faltaría agregar `producto`
   (nombre, publicado), `oferta` y `presentacion` (activa). Como van en la misma
   transacción que la venta, si la venta hace ROLLBACK no queda nada que sincronizar.
2. **Worker** (proceso aparte o `setInterval` en la API): el bucle de `sincronia.mjs`:
   1. lee hasta 5.000 cambios;
   2. reconstruye esos productos desde `v_catalogo` (la vista real) con un solo `IN (...)`;
   3. los escribe con un pipeline `MULTI`;
   4. borra los cambios procesados.

   Si el worker se detiene, los cambios quedan guardados en Oracle y se procesan al volver:
   no se pierde nada.
3. **Rutas de lectura** (`GET /api/v1/productos/:codigo` y `GET /api/v1/productos?categoria=`):
   - Leer de Redis con *cache-aside*: si falta el documento, se consulta Oracle y se guarda.
   - Si Redis no responde, se lee directo de Oracle.

   Las rutas que **escriben** (carrito, pedido, cuentas) no cambian: van a Oracle y sus
   funciones validan el stock real. La caché solo sirve para *mostrar*. El stock que
   decide una venta siempre lo valida Oracle (`fn_crear_pedido`).
4. **Menos peticiones del front:**
   - La ficha devuelve un solo documento con variantes, presentaciones, precios y
     disponible. No hace falta una llamada por variante o por precio.
   - El catálogo devuelve la página completa en una respuesta (`MGET` de 20 claves).
   - Se puede agregar un `ETag` con el campo `actualizado` del documento, para que el
     navegador reciba `304` si nada cambió.
5. **Despliegue:** Redis en un contenedor (`redis:7.4-alpine`, ~40 MB para 50k productos).
   En Render existe "Key Value", compatible con Redis.

### ¿Cuándo vale la pena?

- **Hoy** (cientos de productos y pocos usuarios), Oracle optimizado ya responde en
  milisegundos. Redis agrega una pieza más que operar.
- **Con mucho catálogo o tráfico** (miles de productos, campañas, muchas visitas al
  catálogo), Redis absorbe las lecturas y deja a Oracle para las ventas.

La arquitectura queda preparada: se activa el worker y Redis sin cambiar las reglas de
negocio, porque Oracle sigue siendo quien decide.

## Archivos

| Archivo | Qué hace |
|---|---|
| `01_esquema_simula.sql` | Crea el esquema SIMULA y genera el volumen (la clave se pasa como argumento) |
| `02_vistas_y_outbox.sql` | Vistas reales (anterior y optimizada), outbox y triggers |
| `comun.mjs` | Conexiones y armado del documento de producto |
| `cargar-cache.mjs` | Carga inicial de Redis |
| `backend.mjs` | Backend de prueba con los tres caminos |
| `carga.mjs` | Prueba de carga (`CONCURRENCIA`, `DURACION`, `CAMINOS`) |
| `sincronia.mjs` | Retraso Oracle → Redis y costo de escritura (`VENTAS`, `INTERVALO`) |

Para reproducir:

```bash
podman run -d --name simula_redis -p 6380:6379 docker.io/library/redis:7.4-alpine
# sysdba en FREEPDB1: @01_esquema_simula.sql "<clave>"  y  @02_vistas_y_outbox.sql
export SIMULA_CLAVE='<clave>'
npm install && node cargar-cache.mjs && node backend.mjs &
node carga.mjs && node sincronia.mjs
```

Para borrar la simulación: `DROP USER simula CASCADE;` y `podman rm -f simula_redis`.

## Estado: integrado en la API de la tienda

Esta arquitectura ya está implementada en la API de la tienda:

| Pieza | Dónde |
|---|---|
| Outbox y triggers | `db/18_outbox_catalogo.sql` |
| Caché | `src/cache/` |
| Detalle | README de la API |

Con 32 clientes simultáneos:

| Consulta | Solo Oracle | Con caché |
|---|---|---|
| Listado | 49 req/s | 1.372 req/s |
| Ficha | 523 req/s | 2.324 req/s |

**Pruebas:**

- `npm run comparar-cache` compara 84 respuestas de la caché con las de Oracle: todas idénticas.
- La prueba de humo mide la reserva de un pedido real reflejada en la caché en 281 ms.

**Hallazgo adicional de la simulación:** `v_lote_saldo` tenía el mismo problema
que la vista de stock. La corrige `db/17_saldo_por_lote.sql`:

| Consulta (300.000 lotes) | Antes | Después |
|---|---|---|
| Lotes de una variante | 1,4 s | 0,01 s |
| Página de inventario | 89 s | 0,01 s |

Esa vista la usan la facturación y el consumo de lotes.
