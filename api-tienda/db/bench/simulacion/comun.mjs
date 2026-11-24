// comun.mjs — conexiones y armado del documento de producto.
// Oracle es la UNICA fuente de verdad; Redis guarda una copia de lectura por
// producto (un documento JSON) que se reconstruye cuando Oracle anota un
// cambio en la outbox (catalogo_cambio).
import oracledb from "oracledb";
import { createClient } from "redis";

export const VISTAS = { anterior: "v_stock_variante_anterior", optimizada: "v_stock_variante" };

let pool;
export async function oracle() {
    if (!pool) {
        pool = await oracledb.createPool({
            user: "simula",
            password: process.env.SIMULA_CLAVE,
            connectString: process.env.SIMULA_DSN ?? "localhost:1521/FREEPDB1",
            poolMin: 4,
            poolMax: 16,
            poolIncrement: 2,
            stmtCacheSize: 60,
        });
    }
    return pool;
}

let cliente;
export async function redis() {
    if (!cliente) {
        cliente = createClient({ url: process.env.SIMULA_REDIS ?? "redis://localhost:6380" });
        await cliente.connect();
    }
    return cliente;
}

export async function cerrar() {
    await cliente?.quit().catch(() => {});
    await pool?.close(0).catch(() => {});
}

// Filas de producto -> presentacion con stock disponible y precio vigente
const columnas = (vista) => `
    SELECT p.id_producto, p.prd_codigo, p.prd_nombre, p.id_categoria, v.var_sku, s.disponible,
           pr.id_presentacion, pr.pre_descripcion, pr.pre_factor, hp.precio
    FROM producto p
    JOIN variante v      ON v.id_producto = p.id_producto
    JOIN ${vista} s      ON s.id_variante = v.id_variante
    JOIN presentacion pr ON pr.id_variante = v.id_variante
    -- precio vigente: el ultimo por el indice (id_presentacion, hpr_vigente_desde).
    -- Escrito como subconsulta escalar, Oracle la "desanidaba" en un GROUP BY de
    -- TODO el historial de precios (450.000 filas, 0,45 s por peticion).
    OUTER APPLY (SELECT h.hpr_precio AS precio FROM historial_precio h
                 WHERE h.id_presentacion = pr.id_presentacion AND h.hpr_vigente_desde <= SYSTIMESTAMP
                 ORDER BY h.hpr_vigente_desde DESC FETCH FIRST 1 ROW ONLY) hp`;

/** Agrupa filas en documentos { codigo, nombre, categoria, variantes: [{ sku, disponible, presentaciones }] }. */
export function documentos(filas) {
    const porProducto = new Map();
    for (const f of filas) {
        let d = porProducto.get(f.PRD_CODIGO);
        if (!d) {
            d = { id: f.ID_PRODUCTO, codigo: f.PRD_CODIGO, nombre: f.PRD_NOMBRE, categoria: f.ID_CATEGORIA, variantes: [], actualizado: Date.now() };
            porProducto.set(f.PRD_CODIGO, d);
        }
        let v = d.variantes.find((x) => x.sku === f.VAR_SKU);
        if (!v) {
            v = { sku: f.VAR_SKU, disponible: f.DISPONIBLE, presentaciones: [] };
            d.variantes.push(v);
        }
        v.presentaciones.push({ id: f.ID_PRESENTACION, descripcion: f.PRE_DESCRIPCION, factor: f.PRE_FACTOR, precio: f.PRECIO });
    }
    return [...porProducto.values()];
}

async function ejecutar(sql, binds) {
    const cn = await (await oracle()).getConnection();
    try {
        return (await cn.execute(sql, binds, { outFormat: oracledb.OUT_FORMAT_OBJECT })).rows;
    } finally {
        await cn.close();
    }
}

export const productoOracle = async (vista, codigo) =>
    documentos(await ejecutar(`${columnas(VISTAS[vista])} WHERE p.prd_codigo = :c`, { c: codigo }))[0] ?? null;

export const categoriaOracle = async (vista, idCategoria, pagina) =>
    documentos(await ejecutar(
        `${columnas(VISTAS[vista])}
         WHERE p.id_producto IN (SELECT id_producto FROM producto WHERE id_categoria = :c
                                 ORDER BY prd_codigo OFFSET :o ROWS FETCH NEXT 20 ROWS ONLY)
         ORDER BY p.prd_codigo`,
        { c: idCategoria, o: (pagina - 1) * 20 }
    ));

/** Documentos de varios productos (sincronizacion y carga inicial), con la vista optimizada. */
export async function documentosPorIds(ids) {
    const salida = [];
    for (let i = 0; i < ids.length; i += 900) {
        const lote = ids.slice(i, i + 900);
        const binds = Object.fromEntries(lote.map((id, k) => [`i${k}`, id]));
        salida.push(...documentos(await ejecutar(`${columnas(VISTAS.optimizada)} WHERE p.id_producto IN (${lote.map((_, k) => `:i${k}`).join(",")})`, binds)));
    }
    return salida;
}

/** Guarda documentos en Redis: p:<codigo> = JSON (una sola ida y vuelta por lote: pipeline). */
export async function guardarEnCache(docs) {
    const r = await redis();
    const multi = r.multi();
    for (const d of docs) multi.set(`p:${d.codigo}`, JSON.stringify(d));
    await multi.exec();
}

export async function productoCache(codigo) {
    const r = await redis();
    const json = await r.get(`p:${codigo}`);
    if (json) return { doc: JSON.parse(json), acierto: true };
    // fallo de cache: se lee de Oracle (optimizado) y se guarda
    const doc = await productoOracle("optimizada", codigo);
    if (doc) await guardarEnCache([doc]);
    return { doc, acierto: false };
}

export async function categoriaCache(idCategoria, pagina) {
    const r = await redis();
    const codigos = await r.lRange(`c:${idCategoria}`, (pagina - 1) * 20, pagina * 20 - 1);
    if (!codigos.length) return categoriaOracle("optimizada", idCategoria, pagina);
    const jsons = await r.mGet(codigos.map((c) => `p:${c}`));
    return jsons.filter(Boolean).map((j) => JSON.parse(j));
}
