// src/middlewares/paginacion.js
// Paginacion como middleware reutilizable (ARQUITECTURA.md 5, el PENDIENTE de
// api-productos): valida ?page y ?limit y deja req.paginacion = { page, limit,
// offset } listo para cualquier controlador.
import { matchedData, query } from "express-validator";

export const LIMITE_POR_DEFECTO = 20;
export const LIMITE_MAXIMO = 100;

export const reglasPaginacion = [
    query("page").optional().isInt({ min: 1 }).withMessage("page debe ser un entero >= 1").toInt(),
    query("limit")
        .optional()
        .isInt({ min: 1, max: LIMITE_MAXIMO })
        .withMessage(`limit debe ser un entero entre 1 y ${LIMITE_MAXIMO}`)
        .toInt(),
    // orden: clave de columna; cada repositorio la traduce con su lista blanca
    // (nunca se concatena lo que manda el cliente)
    query("orden").optional().isString().matches(/^[A-Za-z_]{1,40}$/).withMessage("orden: nombre de columna no válido"),
    query("dir").optional().isIn(["asc", "desc"]).withMessage("dir: asc o desc"),
];

/**
 * ORDER BY seguro: mapa = { clave: "expresion SQL" } (lista blanca). Una clave
 * desconocida usa el orden por defecto. El id de desempate hace estable la
 * paginacion (sin el, una fila podria repetirse o perderse entre paginas).
 */
export function ordenSql({ orden, dir } = {}, mapa, defecto, desempate) {
    const expr = orden && Object.hasOwn(mapa, orden) ? mapa[orden] : null;
    if (!expr) return defecto;
    return `${expr} ${dir === "desc" ? "DESC" : "ASC"} NULLS LAST, ${desempate}`;
}

// Va DESPUES de manejarValidacion. En Express 5 req.query es un getter que se
// vuelve a parsear en cada acceso (los toInt() no quedan ahi): los valores ya
// convertidos se leen con matchedData().
export function paginacion(req, _res, next) {
    const { page = 1, limit = LIMITE_POR_DEFECTO, orden = null, dir = "asc" } = matchedData(req, { locations: ["query"] });
    req.paginacion = { page, limit, offset: (page - 1) * limit, orden, dir };
    next();
}
