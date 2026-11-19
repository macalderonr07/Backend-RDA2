// src/models/producto.model.js
// Capa de acceso a datos: unico lugar que arma SQL. Todas las consultas son
// parametrizadas ($1, $2, ...) para evitar inyeccion SQL.
import { pool } from "../config/db.js";

const COLUMNAS = "id, nombre, descripcion, categoria, pvp, stock, url_imagen, creado_en, actualizado_en";

// Escapa los comodines propios de LIKE/ILIKE (%, _ y la barra de escape)
// para que el termino de busqueda se compare literal, no como patron.
function escaparComodinesLike(texto) {
    return texto.replace(/[\\%_]/g, (caracter) => `\\${caracter}`);
}

export async function contarProductos({ q } = {}) {
    if (q) {
        const patron = `%${escaparComodinesLike(q)}%`;
        const { rows } = await pool.query(
            "SELECT COUNT(*)::int AS total FROM productos WHERE nombre ILIKE $1 OR categoria ILIKE $1",
            [patron]
        );
        return rows[0].total;
    }

    const { rows } = await pool.query("SELECT COUNT(*)::int AS total FROM productos");
    return rows[0].total;
}

export async function listarProductos({ limit, offset, q }) {
    if (q) {
        const patron = `%${escaparComodinesLike(q)}%`;
        const { rows } = await pool.query(
            `SELECT ${COLUMNAS} FROM productos
             WHERE nombre ILIKE $1 OR categoria ILIKE $1
             ORDER BY id ASC LIMIT $2 OFFSET $3`,
            [patron, limit, offset]
        );
        return rows;
    }

    const { rows } = await pool.query(
        `SELECT ${COLUMNAS} FROM productos ORDER BY id ASC LIMIT $1 OFFSET $2`,
        [limit, offset]
    );
    return rows;
}

export async function buscarProductoPorId(id) {
    const { rows } = await pool.query(`SELECT ${COLUMNAS} FROM productos WHERE id = $1`, [id]);
    return rows[0] ?? null;
}

export async function crearProducto({ nombre, descripcion, categoria, pvp, stock, url_imagen }) {
    const { rows } = await pool.query(
        `INSERT INTO productos (nombre, descripcion, categoria, pvp, stock, url_imagen)
         VALUES ($1, $2, $3, $4, $5, $6)
         RETURNING ${COLUMNAS}`,
        [nombre, descripcion ?? null, categoria, pvp, stock, url_imagen ?? null]
    );
    return rows[0];
}

export async function actualizarProducto(id, { nombre, descripcion, categoria, pvp, stock, url_imagen }) {
    const { rows } = await pool.query(
        `UPDATE productos
         SET nombre = $1, descripcion = $2, categoria = $3, pvp = $4, stock = $5, url_imagen = $6,
             actualizado_en = now()
         WHERE id = $7
         RETURNING ${COLUMNAS}`,
        [nombre, descripcion ?? null, categoria, pvp, stock, url_imagen ?? null, id]
    );
    return rows[0] ?? null;
}

export async function eliminarProducto(id) {
    const { rows } = await pool.query(`DELETE FROM productos WHERE id = $1 RETURNING id`, [id]);
    return rows[0] ?? null;
}
