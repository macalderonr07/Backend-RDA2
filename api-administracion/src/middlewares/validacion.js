// src/middlewares/validacion.js
// Cierre comun de toda cadena de express-validator: si hubo errores, se arma un
// AppError 422 con el detalle por campo y se delega al errorHandler (nunca se
// responde inline en la ruta).
import { validationResult } from "express-validator";
import { AppError } from "../utils/AppError.js";

export function manejarValidacion(req, _res, next) {
    const resultado = validationResult(req);
    if (resultado.isEmpty()) return next();
    const detalles = resultado.array().map(({ path, msg }) => ({ campo: path, mensaje: msg }));
    next(new AppError("Datos de entrada invalidos", 422, detalles));
}
