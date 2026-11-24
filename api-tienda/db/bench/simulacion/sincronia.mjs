// sincronia.mjs — mide la sincronizacion Oracle -> Redis por outbox.
//  1. Worker: cada INTERVALO ms toma los cambios pendientes de catalogo_cambio,
//     reconstruye esos productos (vista optimizada) y los escribe en Redis
//     con un pipeline; luego borra los cambios procesados.
//  2. Simulador de ventas: inserta movimientos de venta (kardex) a un ritmo
//     fijo, como haria fn_crear_pedido / la facturacion.
//  3. Mide: retraso desde el COMMIT en Oracle hasta que Redis muestra el
//     nuevo disponible (p50/p95/max), y el costo extra del trigger al escribir.
import { cerrar, documentosPorIds, guardarEnCache, oracle, redis } from "./comun.mjs";

const INTERVALO = Number(process.env.INTERVALO ?? 200);
const VENTAS_POR_SEG = Number(process.env.VENTAS ?? 20);
const DURACION = Number(process.env.DURACION ?? 30);
const percentil = (xs, p) => xs[Math.min(xs.length - 1, Math.floor((p / 100) * xs.length))];

const pool = await oracle();
const r = await redis();

// ---- 1. worker
let activo = true;
let lotesProcesados = 0;
let productosReconstruidos = 0;
async function worker() {
    while (activo) {
        const cn = await pool.getConnection();
        try {
            const { rows } = await cn.execute(
                "SELECT id_cambio, id_producto FROM catalogo_cambio ORDER BY id_cambio FETCH FIRST 5000 ROWS ONLY");
            if (rows.length) {
                const ids = [...new Set(rows.map((f) => f[1]))];
                await guardarEnCache(await documentosPorIds(ids));
                await cn.execute("DELETE FROM catalogo_cambio WHERE id_cambio <= :m", { m: rows.at(-1)[0] }, { autoCommit: true });
                lotesProcesados += 1;
                productosReconstruidos += ids.length;
            }
        } finally {
            await cn.close();
        }
        await new Promise((ok) => setTimeout(ok, INTERVALO));
    }
}

// ---- 2. ventas simuladas: un movimiento VEN de 1 unidad sobre un lote al azar
const cn = await pool.getConnection();
let siguienteMov = (await cn.execute("SELECT NVL(MAX(id_movimiento), 0) FROM movimiento_inventario")).rows[0][0] + 1;
let siguienteDet = (await cn.execute("SELECT NVL(MAX(id_detalle_movimiento), 0) FROM detalle_movimiento")).rows[0][0] + 1;
await cn.close();

const retrasos = [];
const escrituras = [];
async function vender() {
    const idLote = 1 + Math.floor(Math.random() * 300000);
    let c = await pool.getConnection();
    let codigo, antes;
    try {
        const f = (await c.execute(
            `SELECT p.prd_codigo, v.var_sku FROM lote l JOIN variante v ON v.id_variante = l.id_variante
             JOIN producto p ON p.id_producto = v.id_producto WHERE l.id_lote = :l`, { l: idLote })).rows[0];
        [codigo] = f;
        const sku = f[1];
        const doc = JSON.parse(await r.get(`p:${codigo}`));
        antes = doc.variantes.find((x) => x.sku === sku).disponible;
        const idMov = siguienteMov++;
        const t0 = performance.now();
        await c.execute("INSERT INTO movimiento_inventario (id_movimiento, id_tipo_movimiento, mov_fechahora, id_usuario) VALUES (:m, 'VEN', SYSTIMESTAMP, 1)", { m: idMov });
        await c.execute("INSERT INTO detalle_movimiento (id_detalle_movimiento, id_movimiento, id_lote, dmo_cantidad) VALUES (:d, :m, :l, 1)", { d: siguienteDet++, m: idMov, l: idLote });
        await c.commit();
        const confirmado = performance.now();
        escrituras.push(confirmado - t0);
        await c.close(); // la conexion vuelve al pool; la espera de Redis no la ocupa
        c = null;
        // esperar a que Redis refleje el nuevo disponible
        while (performance.now() - confirmado < 10000) {
            const d = JSON.parse(await r.get(`p:${codigo}`));
            if (d.variantes.find((x) => x.sku === sku).disponible !== antes) {
                retrasos.push(performance.now() - confirmado);
                return;
            }
            await new Promise((ok) => setTimeout(ok, 5));
        }
        retrasos.push(Infinity);
    } finally {
        await c?.close();
    }
}

const w = worker();
const pendientes = [];
const fin = Date.now() + DURACION * 1000;
while (Date.now() < fin) {
    pendientes.push(vender());
    await new Promise((ok) => setTimeout(ok, 1000 / VENTAS_POR_SEG));
}
await Promise.all(pendientes);
activo = false;
await w;

retrasos.sort((a, b) => a - b);
escrituras.sort((a, b) => a - b);
const perdidos = retrasos.filter((x) => x === Infinity).length;
console.log(`SINCRONIA|${VENTAS_POR_SEG} ventas/s durante ${DURACION} s|intervalo worker ${INTERVALO} ms|${retrasos.length} ventas`
    + `|retraso Oracle->Redis p50 ${percentil(retrasos, 50).toFixed(0)} ms p95 ${percentil(retrasos, 95).toFixed(0)} ms max ${retrasos.at(-1 - perdidos)?.toFixed(0)} ms`
    + `|sin reflejar en 10 s: ${perdidos}|escritura con trigger p50 ${percentil(escrituras, 50).toFixed(1)} ms p95 ${percentil(escrituras, 95).toFixed(1)} ms`
    + `|${lotesProcesados} lotes del worker, ${productosReconstruidos} productos reconstruidos`);
await cerrar();
