// src/middlewares/validarCliente.js
// Reglas compartidas de datos de persona (checkout de invitado y registro de
// cuenta). Igual que los filtros del catalogo, no se escapan con escape():
// viajan como bind a la base (la barrera real) y escaparlos corromperia el
// dato guardado; se restringe forma y longitud (limites de produccion.cliente).
import { body } from "express-validator";

export const camposPersona = [
    body("nombres")
        .isString()
        .withMessage("nombres es requerido")
        .trim()
        .notEmpty()
        .withMessage("nombres es requerido")
        .isLength({ max: 100 })
        .withMessage("nombres debe tener hasta 100 caracteres"),
    body("apellidos")
        .optional({ values: "falsy" })
        .isString()
        .withMessage("apellidos debe ser texto")
        .trim()
        .isLength({ max: 100 })
        .withMessage("apellidos debe tener hasta 100 caracteres"),
    body("correo")
        .isString()
        .withMessage("correo es requerido")
        .trim()
        .toLowerCase()
        .isEmail()
        .withMessage("correo no tiene un formato valido")
        .isLength({ max: 120 })
        .withMessage("correo debe tener hasta 120 caracteres"),
    body("telefono")
        .optional({ values: "falsy" })
        .isString()
        .withMessage("telefono debe ser texto")
        .customSanitizer((valor) => String(valor).replace(/[\s()-]/g, ""))
        .matches(/^\+?\d{7,14}$/)
        .withMessage("telefono debe tener entre 7 y 14 digitos (puede empezar con +)"),
];
