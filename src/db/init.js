// src/db/init.js
// Script de un solo uso: crea/migra la tabla y la puebla con 1000 productos
// si esta vacia. Ejecutar con: npm run db:setup
// Fuente de datos: catalogo real de DummyJSON (con imagen por producto); si la
// red falla, cae al generador sintetico local (sin imagen).
// Flag --reset: vacia la tabla antes de volver a insertar.
import { readFile } from "fs/promises";
import path from "path";
import { fileURLToPath } from "url";
import { pool } from "../config/db.js";
import { obtenerCatalogoReal } from "./catalogoDummyJson.js";
import { generarProductos } from "./generarProductos.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const LOTE = 100; // tamano de lote por INSERT para no armar una query gigante

async function crearTabla() {
    const schemaSql = await readFile(path.join(__dirname, "schema.sql"), "utf8");
    await pool.query(schemaSql);
}

async function contarProductos() {
    const { rows } = await pool.query("SELECT COUNT(*)::int AS total FROM productos");
    return rows[0].total;
}

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

async function obtenerProductos(cantidad) {
    try {
        const productos = await obtenerCatalogoReal(cantidad);
        console.log("Catalogo obtenido de DummyJSON (con imagenes reales).");
        return productos;
    } catch (err) {
        console.warn(`No se pudo usar DummyJSON (${err.message}). Se usan datos sinteticos sin imagen.`);
        return generarProductos(cantidad);
    }
}

async function main() {
    const reset = process.argv.includes("--reset");

    await crearTabla();

    if (reset) {
        await pool.query("TRUNCATE TABLE productos RESTART IDENTITY");
        console.log("Tabla productos vaciada (--reset).");
    }

    const total = await contarProductos();
    if (total > 0) {
        console.log(`La tabla productos ya tiene ${total} filas. No se vuelve a sembrar (usa --reset para forzar).`);
        await pool.end();
        return;
    }

    const productos = await obtenerProductos(1000);
    for (let i = 0; i < productos.length; i += LOTE) {
        await insertarLote(productos.slice(i, i + LOTE));
    }

    console.log(`Listo: ${productos.length} productos insertados.`);
    await pool.end();
}

main().catch((err) => {
    console.error("Error inicializando la base de datos:", err);
    process.exitCode = 1;
    pool.end();
});
