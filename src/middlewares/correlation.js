// src/middlewares/correlation.js
// Propaga/genera un x-correlation-id por request para poder rastrear un
// pedido a traves de logs (observabilidad minima).
import { randomUUID } from "crypto";

export function correlation(req, res, next) {
    const id = req.headers["x-correlation-id"] || randomUUID();
    req.correlationId = id;
    res.setHeader("x-correlation-id", id);
    next();
}
