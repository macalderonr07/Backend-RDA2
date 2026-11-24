// src/middlewares/errorHandler.js
// 404 estandarizado + manejador central de errores (4 argumentos => Express lo
// reconoce como error handler). Unico lugar que decide el status final.
import { RespuestaFactory } from "../factories/respuesta.factory.js";
import { AppError } from "../utils/AppError.js";

export function notFoundHandler(req, res, next) {
    next(new AppError(`Ruta no encontrada: ${req.method} ${req.path}`, 404));
}

// Errores de Oracle que SON esperables y cuyo texto es seguro de mostrar.
// ORA-20001/20003 los lanza la propia base (pr_error / fn_exigir_permiso) con
// mensajes de negocio en espanol pensados para el usuario: se reenvian tal cual.
// El resto de codigos ORA solo se traducen a un mensaje generico: nunca se
// expone el texto de Oracle (nombres de tablas, restricciones, esquemas).
const ERRORES_ORACLE = {
    20001: { status: 409, mensaje: null },
    20003: { status: 403, mensaje: null },
    1: { status: 409, mensaje: "El registro ya existe" },
    2290: { status: 422, mensaje: "Los datos no cumplen las reglas del catalogo" },
    2291: { status: 422, mensaje: "Hace referencia a un registro que no existe" },
    2292: { status: 409, mensaje: "El registro esta en uso y no se puede eliminar" },
    12899: { status: 422, mensaje: "Un valor supera la longitud permitida" },
};

function traducirErrorOracle(err) {
    const conocido = ERRORES_ORACLE[err?.errorNum];
    if (!conocido) return null;
    // "ORA-20001: <mensaje>\nORA-06512: at ..." -> "<mensaje>"
    const mensaje = conocido.mensaje ?? String(err.message).split("\n")[0].replace(/^ORA-\d+:\s*/, "");
    return new AppError(mensaje, conocido.status);
}

// JSON mal formado en el body: lo detecta express.json() antes de cualquier ruta
function esJsonInvalido(err) {
    return err?.type === "entity.parse.failed";
}

export function errorHandler(err, req, res, _next) {
    const operacional = err?.isOperational
        ? err
        : esJsonInvalido(err)
          ? new AppError("El cuerpo de la peticion no es JSON valido", 400)
          : traducirErrorOracle(err);

    if (!operacional) {
        // Solo al log del servidor, con el id de correlacion para rastrearlo
        console.error(`[${req.correlationId ?? "sin-id"}] Error no operacional:`, err);
        return res.status(500).json(RespuestaFactory.error("Error interno del servidor"));
    }

    res.status(operacional.statusCode).json(RespuestaFactory.error(operacional.message, operacional.detalles));
}
