// src/middlewares/validarProducto.js
// Validacion de entrada de los recursos de catalogo (solo lectura).
// Los filtros no se escapan con escape(): no se renderizan, viajan como bind
// al SQL (que es la barrera real contra inyeccion). Se restringe su forma.
import { param, query } from "express-validator";

export const reglasCodigoProducto = [
    param("codigo")
        .trim()
        .toUpperCase()
        .matches(/^[A-Z0-9-]{1,20}$/)
        .withMessage("codigo debe tener hasta 20 letras, digitos o guiones (ej. CE-1042)"),
];

export const reglasFiltrosProducto = [
    query("linea")
        .optional()
        .trim()
        .toLowerCase()
        .matches(/^[a-z0-9-]{1,20}$/)
        .withMessage("linea debe ser un codigo de categoria (ej. cueros)"),
    // marca: nombre exacto (es opcional por producto; viaja como bind)
    query("marca")
        .optional()
        .trim()
        .isLength({ min: 1, max: 60 })
        .withMessage("marca debe tener entre 1 y 60 caracteres"),
    // q busca SOLO en el nombre del producto
    query("q").optional().trim().isLength({ min: 1, max: 100 }).withMessage("q debe tener entre 1 y 100 caracteres"),
];
