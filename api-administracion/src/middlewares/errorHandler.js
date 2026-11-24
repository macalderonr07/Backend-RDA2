// src/middlewares/errorHandler.js
// 404 estandarizado + manejador central de errores: unico lugar que decide el
// status final. Traduce los errores de Sequelize y de Oracle a mensajes para
// el usuario SIN filtrar detalles internos (tablas, restricciones, esquemas).
import { RespuestaFactory } from "../factories/respuesta.factory.js";
import { AppError } from "../utils/AppError.js";

export function notFoundHandler(req, _res, next) {
    next(new AppError(`Ruta no encontrada: ${req.method} ${req.path}`, 404));
}

// ORA-20001/20003: los lanza la propia base (pr_error / fn_exigir_permiso) con
// mensajes de negocio en espanol pensados para el usuario: se reenvian tal cual.
const ERRORES_ORACLE = {
    20000: { status: 409, mensaje: null },
    20001: { status: 409, mensaje: null },
    20003: { status: 403, mensaje: null },
    1: { status: 409, mensaje: "Ya existe un registro con esos datos" },
    1400: { status: 422, mensaje: "Falta un dato obligatorio" },
    1438: { status: 422, mensaje: "Un número es demasiado grande" },
    2290: { status: 422, mensaje: "Los datos no cumplen una regla del negocio" },
    2291: { status: 422, mensaje: "Hace referencia a un registro que no existe" },
    2292: { status: 409, mensaje: "El registro está en uso por otros datos y no se puede eliminar; puedes desactivarlo" },
    12899: { status: 422, mensaje: "Un valor supera la longitud permitida" },
};

function errorOracle(err) {
    // Sequelize envuelve el error del driver en .original / .parent
    const base = err?.errorNum != null ? err : (err?.original ?? err?.parent);
    if (base?.errorNum == null) return null;
    const conocido = ERRORES_ORACLE[base.errorNum];
    if (!conocido) return null;
    const mensaje = conocido.mensaje ?? String(base.message).split("\n")[0].replace(/^ORA-\d+:\s*/, "");
    return new AppError(mensaje, conocido.status);
}

function errorSequelize(err) {
    switch (err?.name) {
        case "SequelizeValidationError":
            return new AppError(
                "Datos de entrada inválidos",
                422,
                err.errors.map((e) => ({ campo: e.path, mensaje: e.message }))
            );
        case "SequelizeUniqueConstraintError":
            return new AppError("Ya existe un registro con esos datos", 409);
        case "SequelizeForeignKeyConstraintError":
            return new AppError("El registro está en uso o hace referencia a datos que no existen", 409);
        default:
            return null;
    }
}

export function errorHandler(err, req, res, _next) {
    const operacional = err?.isOperational
        ? err
        : err?.type === "entity.parse.failed"
          ? new AppError("El cuerpo de la petición no es JSON válido", 400)
          : (errorOracle(err) ?? errorSequelize(err));

    if (!operacional) {
        // Solo al log del servidor, con el id de correlacion para rastrearlo
        console.error(`[${req.correlationId ?? "sin-id"}] Error no operacional:`, err);
        return res.status(500).json(RespuestaFactory.error("Error interno del servidor"));
    }
    res.status(operacional.statusCode).json(RespuestaFactory.error(operacional.message, operacional.detalles));
}
