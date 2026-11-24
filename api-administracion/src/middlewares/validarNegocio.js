// src/middlewares/validarNegocio.js
// Constructores de reglas de express-validator reutilizados por los modulos de
// negocio (productos, inventario, compras, ventas). Mismos patrones que el
// frontend (src/utils/patrones.js).
import { body, param, query } from "express-validator";
import { PATRONES, regex } from "../utils/patrones.js";

const comoTexto = (v) => (typeof v === "number" ? String(v) : v);

/** Numero validado con un patron (cantidad, dinero, porcentaje...) y convertido a float. */
export function numero(campo, patron, { opcional = false, etiqueta = campo, minimo = null } = {}) {
    let r = body(campo);
    r = opcional ? r.optional({ values: "null" }) : r.exists({ values: "null" }).withMessage(`${etiqueta} es obligatorio`).bail();
    r = r.customSanitizer(comoTexto).isString().matches(regex(patron)).withMessage(`${etiqueta}: ${PATRONES[patron].mensaje}`).toFloat();
    if (minimo !== null) r = r.custom((v) => v > minimo).withMessage(`${etiqueta} debe ser mayor que ${minimo}`);
    return r;
}

export function texto(campo, patron, { opcional = false, etiqueta = campo, max = 150, mayusculas = false, minusculas = false } = {}) {
    let r = body(campo);
    r = opcional ? r.optional({ values: "falsy" }) : r.exists({ values: "falsy" }).withMessage(`${etiqueta} es obligatorio`).bail();
    r = r.isString().trim();
    if (mayusculas) r = r.toUpperCase();
    if (minusculas) r = r.toLowerCase();
    return r.isLength({ max }).withMessage(`${etiqueta}: hasta ${max} caracteres`).matches(regex(patron)).withMessage(`${etiqueta}: ${PATRONES[patron].mensaje}`);
}

export function id(campo, { opcional = false, etiqueta = campo, en = "body" } = {}) {
    const fuente = { body, param, query }[en];
    let r = fuente(campo);
    if (opcional) r = r.optional({ values: "falsy" });
    return r.isInt({ min: 1 }).withMessage(`${etiqueta}: elige una opción válida`).toInt();
}

export function codigoTexto(campo, { opcional = false, etiqueta = campo, max = 20 } = {}) {
    let r = body(campo);
    if (opcional) r = r.optional({ values: "falsy" });
    return r.isString().trim().isLength({ min: 1, max }).matches(/^[A-Za-z0-9-]+$/).withMessage(`${etiqueta}: opción no válida`);
}

export function booleano(campo, { opcional = true } = {}) {
    let r = body(campo);
    if (opcional) r = r.optional({ values: "null" });
    return r.isIn([0, 1, true, false, "0", "1"]).withMessage(`${campo}: sí o no`).customSanitizer((v) => v === true || v === 1 || v === "1");
}

export function fecha(campo, { opcional = true, etiqueta = campo } = {}) {
    let r = body(campo);
    if (opcional) r = r.optional({ values: "falsy" });
    return r.isISO8601().withMessage(`${etiqueta}: fecha no válida`).toDate();
}

export function lista(campo, { min = 1, max = 200, etiqueta = campo } = {}) {
    return body(campo).isArray({ min, max }).withMessage(`${etiqueta}: entre ${min} y ${max} elementos`);
}

export const idParam = (nombre = "id") => param(nombre).isInt({ min: 1 }).withMessage("Identificador no válido").toInt();
