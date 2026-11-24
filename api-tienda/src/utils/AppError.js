// src/utils/AppError.js
// Error "operacional" (esperado): quien lo lanza decide el statusCode y el
// errorHandler central solo lo serializa. Los errores NO operacionales
// (caida de la base, bug) no usan esta clase y se responden como 500 generico.
export class AppError extends Error {
    constructor(message, statusCode = 500, detalles = null) {
        super(message);
        this.statusCode = statusCode;
        this.isOperational = true;
        if (detalles) this.detalles = detalles;
        Error.captureStackTrace(this, this.constructor);
    }
}
