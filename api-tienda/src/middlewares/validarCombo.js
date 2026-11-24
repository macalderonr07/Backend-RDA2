// src/middlewares/validarCombo.js
// Validacion de entrada de combos. Los codigos viajan como bind al SQL; aqui
// solo se restringe su forma.
import { body, param, query } from "express-validator";

const FORMATO_CODIGO = /^[A-Z0-9-]{1,20}$/;
const COMBOS_MAXIMOS = 1000; // tope de cordura por agregado

export const reglasCodigoCombo = [
    param("codigo")
        .trim()
        .toUpperCase()
        .matches(FORMATO_CODIGO)
        .withMessage("codigo debe tener hasta 20 letras, digitos o guiones (ej. CMB-CIERRE)"),
];

export const reglasFiltroCombos = [
    query("producto")
        .optional()
        .trim()
        .toUpperCase()
        .matches(FORMATO_CODIGO)
        .withMessage("producto debe ser un codigo de producto (ej. CE-9001)"),
];

// POST /carritos/:token/combos
export const reglasNuevoCombo = [
    body("codigo")
        .isString()
        .withMessage("codigo es requerido")
        .trim()
        .toUpperCase()
        .matches(FORMATO_CODIGO)
        .withMessage("codigo debe ser el codigo de un combo (ej. CMB-CIERRE)"),
    body("color")
        .optional()
        .isString()
        .trim()
        .isLength({ min: 1, max: 40 })
        .withMessage("color debe ser el nombre de un color del combo (ej. Negro)"),
    body("cantidad")
        .optional()
        .isInt({ min: 1, max: COMBOS_MAXIMOS })
        .withMessage(`cantidad debe ser un entero entre 1 y ${COMBOS_MAXIMOS}`)
        .toInt(),
];
