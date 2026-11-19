// src/utils/AppError.js
// Error "operacional" (esperado): el controlador decide el statusCode y el
// errorHandler central solo lo serializa. Los errores NO operacionales
// (fallo de BD, bug) no usan esta clase y el handler los trata como 500.
export class AppError extends Error {
    constructor(message, statusCode = 500) {
        super(message);
        this.statusCode = statusCode;
        this.isOperational = true;
        Error.captureStackTrace(this, this.constructor);
    }
}
