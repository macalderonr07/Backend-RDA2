// src/middlewares/errorHandler.js
// Middleware de error centralizado (4 argumentos => Express lo reconoce
// como error handler). Todo controlador delega aqui con next(err).
import { AppError } from "../utils/AppError.js";

export function notFoundHandler(req, res, next) {
    next(new AppError(`Ruta no encontrada: ${req.method} ${req.originalUrl}`, 404));
}

export function errorHandler(err, req, res, next) {
    const statusCode = err.isOperational ? err.statusCode : 500;

    if (!err.isOperational) {
        console.error(`[${req.correlationId ?? "sin-id"}] Error no operacional:`, err);
    }

    res.status(statusCode).json({
        status: "error",
        message: err.isOperational ? err.message : "Error interno del servidor",
        ...(err.detalles ? { detalles: err.detalles } : {}),
    });
}
