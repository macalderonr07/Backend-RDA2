// src/db/setup.js
// Prepara la base: crea/migra la tabla y la siembra con 1000 productos si esta
// vacia. Es idempotente: se puede llamar en cada arranque sin duplicar filas.
// Lo usan src/db/init.js (CLI: npm run db:setup) y src/server.js cuando
// AUTO_SETUP=true (PaaS sin shell, como el plan free de Render).
import { readFile } from "fs/promises";
import path from "path";
import { fileURLToPath } from "url";
import { pool } from "../config/db.js";
import { obtenerCatalogoReal } from "./catalogoDummyJson.js";
import { generarProductos } from "./generarProductos.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const LOTE = 100; // tamano de lote por INSERT para no armar una query gigante
const CANTIDAD_INICIAL = 1000;

// INSERT multi-fila parametrizado: nunca se concatena valor de usuario/dato
// directo al SQL, siempre via placeholders ($1, $2, ...).
async function insertarLote(lote) {
    const columnas = ["nombre", "descripcion", "categoria", "pvp", "stock", "url_imagen"];
    const valores = [];
    const placeholders = lote
        .map((producto, fila) => {
            const base = fila * columnas.length;
            valores.push(...columnas.map((columna) => producto[columna] ?? null));
            return `(${columnas.map((_, col) => `$${base + col + 1}`).join(", ")})`;
        })
        .join(", ");

    const sql = `INSERT INTO productos (${columnas.join(", ")}) VALUES ${placeholders}`;
    await pool.query(sql, valores);
}

async function obtenerProductos(cantidad, log) {
    try {
        const productos = await obtenerCatalogoReal(cantidad);
        log("Catalogo obtenido de DummyJSON (con imagenes reales).");
        return productos;
    } catch (err) {
        log(`No se pudo usar DummyJSON (${err.message}). Se usan datos sinteticos sin imagen.`);
        return generarProductos(cantidad);
    }
}

/**
 * Crea la tabla si falta y siembra los productos iniciales cuando esta vacia.
 * @param {{ reset?: boolean, log?: (mensaje: string) => void }} opciones
 * @returns {Promise<number>} cantidad total de productos tras preparar la base
 */
export async function prepararBaseDeDatos({ reset = false, log = console.log } = {}) {
    const schemaSql = await readFile(path.join(__dirname, "schema.sql"), "utf8");
    await pool.query(schemaSql);

    if (reset) {
        await pool.query("TRUNCATE TABLE productos RESTART IDENTITY");
        log("Tabla productos vaciada (--reset).");
    }

    const { rows } = await pool.query("SELECT COUNT(*)::int AS total FROM productos");
    if (rows[0].total > 0) {
        log(`La tabla productos ya tiene ${rows[0].total} filas. No se vuelve a sembrar (usa --reset para forzar).`);
        return rows[0].total;
    }

    const productos = await obtenerProductos(CANTIDAD_INICIAL, log);
    for (let i = 0; i < productos.length; i += LOTE) {
        await insertarLote(productos.slice(i, i + LOTE));
    }

    log(`Listo: ${productos.length} productos insertados.`);
    return productos.length;
}
