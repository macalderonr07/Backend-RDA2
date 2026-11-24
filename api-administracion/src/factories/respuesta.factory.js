// src/factories/respuesta.factory.js
// Factory (ARQUITECTURA.md 3.3): unico lugar que da forma al JSON que viaja del
// controlador al cliente. Todos los endpoints, de cualquier modelo, responden
// { status, data, meta? } o { status: "error", message, detalles? }.
export const RespuestaFactory = Object.freeze({
    exito(data, meta = null) {
        return { status: "success", data, ...(meta ? { meta } : {}) };
    },

    error(message, detalles = null) {
        return { status: "error", message, ...(detalles ? { detalles } : {}) };
    },

    /** meta de paginacion a partir de req.paginacion y el total de la consulta. */
    paginacion({ page, limit }, totalItems, extra = {}) {
        return {
            page,
            limit,
            totalItems,
            totalPages: Math.max(1, Math.ceil(totalItems / limit)),
            ...extra,
        };
    },
});
