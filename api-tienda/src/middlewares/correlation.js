// src/middlewares/correlation.js
// Id de correlacion por request (observabilidad): se reutiliza el que mande el
// cliente si es un id razonable, o se genera uno. Viaja en la respuesta y en los
// logs de error para poder rastrear un fallo concreto.
import { randomUUID } from "node:crypto";

const ID_VALIDO = /^[A-Za-z0-9-]{8,64}$/; // evita inyectar saltos de linea en los logs

export function correlation(req, res, next) {
    const recibido = req.get("x-correlation-id");
    req.correlationId = recibido && ID_VALIDO.test(recibido) ? recibido : randomUUID();
    res.setHeader("X-Correlation-Id", req.correlationId);
    next();
}
