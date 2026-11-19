// src/middlewares/validarProducto.js
// Validacion + sanitizacion de entrada con express-validator.
// trim()/escape() sanitizan texto (previene XSS en campos que luego se
// puedan renderizar); toFloat()/toInt() normalizan tipos antes de llegar
// al modelo, que ademas parametriza el SQL (segunda barrera anti-inyeccion).
import { body, param, query, validationResult } from "express-validator";
import { AppError } from "../utils/AppError.js";

export const reglasProducto = [
    body("nombre")
        .trim()
        .notEmpty()
        .withMessage("nombre es requerido")
        .isLength({ max: 150 })
        .withMessage("nombre no puede superar 150 caracteres")
        .escape(),
    body("descripcion")
        .optional({ values: "falsy" })
        .trim()
        .isLength({ max: 2000 })
        .withMessage("descripcion no puede superar 2000 caracteres")
        .escape(),
    body("categoria")
        .trim()
        .notEmpty()
        .withMessage("categoria es requerida")
        .isLength({ max: 80 })
        .withMessage("categoria no puede superar 80 caracteres")
        .escape(),
    body("pvp")
        .notEmpty()
        .withMessage("pvp es requerido")
        .isFloat({ min: 0 })
        .withMessage("pvp debe ser un numero >= 0")
        .toFloat(),
    body("stock")
        .notEmpty()
        .withMessage("stock es requerido")
        .isInt({ min: 0 })
        .withMessage("stock debe ser un entero >= 0")
        .toInt(),
    // url_imagen NO lleva escape(): convertiria "&" en "&amp;" y romperia la
    // URL. En su lugar se restringe a http/https con protocolo explicito
    // (bloquea javascript:/data:, vector de XSS si se usa en <img src>).
    body("url_imagen")
        .optional({ values: "falsy" })
        .trim()
        .isLength({ max: 500 })
        .withMessage("url_imagen no puede superar 500 caracteres")
        .isURL({ protocols: ["http", "https"], require_protocol: true })
        .withMessage("url_imagen debe ser una URL http(s) valida"),
];

export const reglasIdParam = [param("id").isInt({ min: 1 }).withMessage("id debe ser un entero positivo").toInt()];

export const reglasPaginacion = [
    query("page").optional().isInt({ min: 1 }).withMessage("page debe ser un entero >= 1").toInt(),
];

export const reglasBusqueda = [
    query("q").optional().trim().isLength({ max: 150 }).withMessage("q no puede superar 150 caracteres"),
];

export function manejarValidacion(req, res, next) {
    const resultado = validationResult(req);
    if (!resultado.isEmpty()) {
        const detalles = resultado.array().map(({ path, msg }) => ({ campo: path, mensaje: msg }));
        const error = new AppError("Datos de entrada invalidos", 422);
        error.detalles = detalles;
        return next(error);
    }
    next();
}
