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
];

// Va DESPUES de manejarValidacion. En Express 5 req.query es un getter que se
// vuelve a parsear en cada acceso (los toInt() no quedan ahi): los valores ya
// convertidos se leen con matchedData().
export function paginacion(req, _res, next) {
    const { page = 1, limit = LIMITE_POR_DEFECTO } = matchedData(req, { locations: ["query"] });
    req.paginacion = { page, limit, offset: (page - 1) * limit };
    next();
}
