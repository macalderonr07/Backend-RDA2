// src/utils/codigos.js
// Codigos AUTOMATICOS (no los escribe el usuario ni se editan despues): asi no
// hay codigos repetidos, mal escritos o que no siguen la convencion del negocio.
// Se calculan DENTRO de la transaccion del alta; la restriccion UNIQUE de la
// base es la ultima barrera si dos personas crean a la vez (409, reintentar).
//
//  - Categoria hija:  <codigo del padre>-<siguiente numero>   suelas -> suelas-3
//  - Linea (sin padre): primera palabra del nombre, sin tildes  "Pega industrial" -> pega
//  - Producto: CE-<numero> en el bloque de mil de su linea      suelas (3xxx) -> CE-3007
//  - Combo: CMB-0001, CMB-0002...
import { consulta } from "../config/db.js";
import { AppError } from "./AppError.js";

/** "Pega Industrial Ñandú" -> ["pega", "industrial", "nandu"] */
export function palabras(texto) {
    return String(texto ?? "")
        .normalize("NFD")
        .replace(/[̀-ͯ]/g, "")
        .toLowerCase()
        .split(/[^a-z0-9]+/)
        .filter(Boolean);
}

export async function codigoCategoria(t, { nombre, idCategoriaPadre }) {
    if (idCategoriaPadre) {
        // FOR UPDATE del padre: dos subcategorias nuevas del mismo padre se numeran en fila
        const [padre] = await consulta(
            "SELECT cat_codigo FROM produccion.categoria WHERE id_categoria = :id FOR UPDATE",
            { id: idCategoriaPadre },
            t
        );
        if (!padre) throw new AppError("La categoría padre no existe", 422, [{ campo: "idCategoriaPadre", mensaje: "Elige una categoría padre que exista" }]);
        const hijos = await consulta(
            "SELECT cat_codigo FROM produccion.categoria WHERE id_categoria_padre = :id",
            { id: idCategoriaPadre },
            t
        );
        const prefijo = `${padre.cat_codigo}-`;
        const usados = hijos
            .map((h) => h.cat_codigo)
            .filter((c) => c.startsWith(prefijo) && /^\d+$/.test(c.slice(prefijo.length)))
            .map((c) => Number(c.slice(prefijo.length)));
        return `${prefijo}${Math.max(0, ...usados) + 1}`;
    }
    const p = palabras(nombre);
    if (p.length === 0) throw new AppError("El nombre debe tener letras para generar el código", 422, [{ campo: "nombre", mensaje: "Escribe un nombre con letras" }]);
    // primera palabra; si ya existe, se agregan las siguientes (pega -> pega-industrial)
    const candidatos = p.map((_, i) => p.slice(0, i + 1).join("-"));
    for (const c of candidatos) {
        const [{ n }] = await consulta("SELECT COUNT(*) AS n FROM produccion.categoria WHERE cat_codigo = :c", { c }, t);
        if (n === 0) return c;
    }
    throw new AppError(`Ya existe una línea con el código "${candidatos.at(-1)}": usa un nombre distinto`, 409, [{ campo: "nombre", mensaje: "Ya existe una línea con ese nombre" }]);
}

export async function codigoProducto(t, idCategoria) {
    // la linea (categoria raiz) de la categoria elegida
    const [linea] = await consulta(
        `SELECT NVL(c.id_categoria_padre, c.id_categoria) AS id_linea
         FROM produccion.categoria c WHERE c.id_categoria = :id`,
        { id: idCategoria },
        t
    );
    if (!linea) throw new AppError("La categoría no existe", 422, [{ campo: "idCategoria", mensaje: "Elige una categoría que exista" }]);
    const numeros = (filas) => filas.map((f) => /^CE-(\d+)$/.exec(f.prd_codigo)).filter(Boolean).map((x) => Number(x[1]));
    const deLinea = numeros(await consulta(
        `SELECT p.prd_codigo FROM produccion.producto p
         JOIN produccion.categoria c ON c.id_categoria = p.id_categoria
         WHERE NVL(c.id_categoria_padre, c.id_categoria) = :linea`,
        { linea: linea.id_linea },
        t
    ));
    const todos = numeros(await consulta("SELECT prd_codigo FROM produccion.producto WHERE prd_codigo LIKE 'CE-%'", {}, t));
    let siguiente;
    if (deLinea.length > 0) {
        // el bloque de mil de la linea (cueros 1000-1999, suelas 3000-3999...)
        const bloque = Math.floor(Math.min(...deLinea) / 1000) * 1000;
        siguiente = Math.max(...deLinea.filter((n) => n >= bloque && n < bloque + 1000)) + 1;
        if (siguiente >= bloque + 1000) siguiente = null; // bloque lleno: se busca el siguiente libre
    }
    if (!siguiente) {
        // linea nueva: el primer bloque de mil sin productos
        const ocupados = new Set(todos.map((n) => Math.floor(n / 1000)));
        let b = 1;
        while (ocupados.has(b)) b += 1;
        siguiente = b * 1000 + 1;
    }
    const usados = new Set(todos);
    while (usados.has(siguiente)) siguiente += 1;
    return `CE-${siguiente}`;
}

export async function codigoCombo(t) {
    const filas = await consulta("SELECT cmb_codigo FROM produccion.combo WHERE REGEXP_LIKE(cmb_codigo, '^CMB-[0-9]+$')", {}, t);
    const n = Math.max(0, ...filas.map((f) => Number(f.cmb_codigo.slice(4)))) + 1;
    return `CMB-${String(n).padStart(4, "0")}`;
}
