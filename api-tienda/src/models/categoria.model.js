// src/models/categoria.model.js
// Repository de categorias (solo lectura). El e-commerce no lee la tabla
// produccion.categoria (no esta en el contrato entre nodos): lee
// v_categoria_web, que expone SOLO las categorias principales (raiz: sin
// categoria padre, o sea que no son subcategoria de otra), con los productos
// publicados de todo su arbol, sus subcategorias directas y una imagen.
import { db } from "../config/db.js";

/**
 * Categorias principales. Con soloConProductos, omite las que no tienen nada
 * publicado (lo que la tienda debe mostrar).
 */
export async function listarPrincipales({ soloConProductos = true } = {}) {
    const { rows } = await db.ejecutar(
        `SELECT codigo, nombre, subcategorias, productos, imagen_url
         FROM v_categoria_web
         WHERE (:solo = 0 OR productos > 0)
         ORDER BY id_categoria`, // orden en que se crearon las lineas
        { solo: soloConProductos ? 1 : 0 }
    );
    return rows.map((f) => ({
        codigo: f.CODIGO,
        nombre: f.NOMBRE,
        subcategorias: f.SUBCATEGORIAS ? f.SUBCATEGORIAS.split(" · ") : [],
        productos: f.PRODUCTOS,
        imagenUrl: f.IMAGEN_URL,
    }));
}
