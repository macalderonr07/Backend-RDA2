// src/middlewares/validarCuenta.js
// Validacion de cuentas web. La clave NO se recorta ni se sanitiza (puede
// llevar espacios o simbolos a proposito): solo se exige tipo y longitud, y de
// aqui va directo a scrypt — nunca a un SQL ni a un log.
import { body } from "express-validator";
import { camposPersona } from "./validarCliente.js";

const CLAVE_MINIMA = 8;
const CLAVE_MAXIMA = 100;

const clave = body("clave")
    .isString()
    .withMessage("clave es requerida")
    .isLength({ min: CLAVE_MINIMA, max: CLAVE_MAXIMA })
    .withMessage(`clave debe tener entre ${CLAVE_MINIMA} y ${CLAVE_MAXIMA} caracteres`);

export const reglasCuentaNueva = [...camposPersona, clave];

export const reglasInicioSesion = [
    body("correo")
        .isString()
        .withMessage("correo es requerido")
        .trim()
        .toLowerCase()
        .isEmail()
        .withMessage("correo no tiene un formato valido"),
    body("clave").isString().withMessage("clave es requerida").notEmpty().withMessage("clave es requerida"),
];
