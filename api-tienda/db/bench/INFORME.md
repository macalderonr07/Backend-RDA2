# Rendimiento de productos y clientes: ¿NoSQL o índices?

Medido el 22/11/2026 sobre Oracle 23ai Free (contenedor `bd2_oracle`).

## 1. Punto de partida

- **La tienda no usa NoSQL.** El catálogo sale de Oracle por la API
  (`v_catalogo_web`). `data/catalogo.json` (16 productos) es solo el respaldo
  cuando la API no responde.
- En la raíz del repo hay una configuración de Firestore (`firebase.json`,
  `firestore.rules`), pero ningún archivo de la tienda la usa y sus reglas
  vencieron el 11/11/2026.
- Volumen actual: 76 productos, 223 variantes, 65 clientes y 67 pedidos. Con eso
  cualquier consulta tarda menos de 1 ms, así que **medir sobre los datos reales
  no muestra nada**.

## 2. Cómo se midió

- Se usó un esquema aparte, `BENCH`, con la misma estructura de columnas e
  índices que producción y un volumen de crecimiento:
  - 5.000 productos, 20.000 variantes y 40.000 presentaciones;
  - 120.000 precios, 60.000 lotes y 200.000 movimientos;
  - 20.000 clientes, 100.000 pedidos, 300.000 líneas de pedido y 30.000 líneas
    de orden de compra.
- Cada consulta se corrió 50 veces con valores distintos, que fueron los mismos
  en las dos fases.
- **ms** es el tiempo promedio. **Lecturas** son los bloques que Oracle tuvo que
  leer: es la medida estable del trabajo y crece con los datos.
- Producción no se tocó. El esquema se borra al terminar y se recrea en unos
  11 s con los scripts de esta carpeta.

## 3. Índices candidatos (los que faltan en producción)

| Índice | Para qué |
|---|---|
| `detalle_pedido(id_presentacion)` | lo reservado de cada variante (stock disponible) |
| `detalle_orden_compra(id_variante)` | lo que está en camino de cada variante |
| `datos_facturacion(dfa_identificacion)` | buscar cliente por cédula o RUC |
| `telefono(tel_numero)` | buscar cliente por teléfono |
| `variante_valor(id_valor_atributo)` | filtrar por color o talla |
| `producto(UPPER(prd_nombre))` | buscar por el inicio del nombre (autocompletar) |

## 4. Resultados

| Consulta | Sin índices | Con índices | Mejora |
|---|---|---|---|
| Q1 Ficha de producto por código (precio + stock) | 42,8 ms · 4.402 lect. | 0,6 ms · 280 lect. | ×71 |
| Q2 Listado de una categoría (20 productos) | 810,8 ms · 85.351 lect. | 6,0 ms · 2.908 lect. | ×135 |
| Q3 Búsqueda por nombre que **contiene** | 1,0 ms · 40 lect. | 1,0 ms · 40 lect. | sin cambio (un índice B-tree no sirve para `%texto%`) |
| Q3b Búsqueda por **inicio** del nombre | 0,8 ms · 41 lect. | 0,2 ms · 7 lect. | ×6 en lecturas |
| Q4 Cliente por cédula exacta | 0,4 ms · 114 lect. | 0,0 ms · 4 lect. | ×28 en lecturas |
| Q5 Cliente por teléfono exacto | 0,4 ms · 76 lect. | 0,2 ms · 4 lect. | ×19 en lecturas |
| Q6 Pedidos de un cliente (control: ya indexado) | 0,2 ms · 24 lect. | 0,2 ms · 24 lect. | igual, como se esperaba |
| Q7 Variantes de un color | 0,4 ms · 45 lect. | 0,2 ms · 7 lect. | ×6 en lecturas |

### El hallazgo que decide

| Stock de un producto | Sin índices | Con índices |
|---|---|---|
| Q8: con la estructura **actual** de `v_stock_variante` | 151 ms · 2.489 lect. | 145 ms · 2.395 lect. |
| Q8b: con la vista **reescrita** | 49 ms · 4.770 lect. | **1,3 ms · 420 lect.** |

La vista actual calcula el estado de **todos** los pedidos y el saldo de
**todas** las variantes (bloques `WITH … GROUP BY`) antes de filtrar por el
producto. Por eso los índices **solos casi no ayudan** (151 → 145 ms).

Reescrita para calcular solo las variantes pedidas (subconsultas por variante),
y con los índices, baja a **1,3 ms: unas 113 veces más rápido**. Hacen falta
las dos cosas. En el plan de la base real ya se ven los recorridos completos de
`detalle_pedido` y `detalle_orden_compra`; hoy no se notan porque las tablas
son pequeñas.

## 5. Costo de los índices

- **Espacio:** 8,6 MB con este volumen, el 19 % de las tablas medidas
  (44,9 MB). Casi todo es el índice de `detalle_pedido` (6 MB).
- **Escritura:** insertar 20.000 líneas de pedido tardó 50 ms sin los índices y
  90 ms con ellos. Son unos 2 µs más por línea: un pedido de 10 líneas paga unos
  20 µs más.

## 6. ¿Y NoSQL (Firestore, MongoDB) para productos y clientes?

| Criterio | Oracle con índices y vista reescrita | NoSQL para catálogo y clientes |
|---|---|---|
| Ficha de producto | 1,3 ms medido | rápida si el documento ya tiene el stock calculado |
| Stock correcto | se calcula del kárdex en la misma transacción que la venta | hay que copiar el stock al documento en cada venta, recepción o ajuste; dos fuentes de verdad que pueden desincronizarse |
| Reglas del negocio | ya viven en la base (bandas, cortes, reservas, crédito, permisos) | habría que reescribirlas en la aplicación |
| Transacciones | pedido, reserva y kárdex juntos o nada | limitadas entre documentos |
| Búsqueda "contiene" | B-tree no sirve; Oracle Text sí (no instalado en Free) | igual: Firestore no busca dentro del texto; hace falta un buscador aparte |
| Costo del cambio | 6 índices + reescribir 1 vista | segunda base, sincronización, reglas de seguridad, y migrar la API y la tienda |

**Conclusión de la medición.** El cuello de botella no es el motor
relacional: son dos índices faltantes y una vista que calcula de más. Con
índices y la vista reescrita, la ficha baja a ~1 ms y el listado a ~6 ms con 65
veces los productos actuales. NoSQL agregaría una segunda copia del stock y de
los clientes que habría que mantener sincronizada, sin un beneficio medible
para este caso.

Si más adelante el catálogo crece a decenas de miles de productos con mucho
tráfico, la opción intermedia es una **caché de lectura** (un documento por
producto, regenerado cuando cambia), con Oracle como única fuente de verdad.

## 7. Si decides integrarlo

1. Una migración (15) con los 6 índices.
2. Reescribir `v_stock_variante` (y lo que la usa: `v_catalogo`) con la forma
   de Q8b. Hay que verificar con las pruebas de humo, la E2E de la tienda y la
   administración.
3. Volver a medir con `01_crear_bench.sql`, `02_medir.sql`,
   `03_indices_candidatos.sql`, `04_vista_real.sql` y `05_vista_reescrita.sql`.

## Archivos

- `01_crear_bench.sql`: crea `BENCH` con el volumen de prueba (cuenta sin clave).
- `02_medir.sql <sin|con>`: Q1 a Q7.
- `03_indices_candidatos.sql`: crea los índices y mide el costo de escritura y el tamaño.
- `04_vista_real.sql <fase>`: Q8, con la estructura actual de la vista.
- `05_vista_reescrita.sql <fase>`: Q8b.
- `99_borrar_bench.sql`: borra el esquema de pruebas.
