// src/middlewares/cors.js
// CORS con origen explicito por entorno. Sin CLIENT_ORIGIN no se habilita ningun
// origen cruzado (seguro por defecto); "*" solo si se pide a proposito.
// Los origenes loopback (localhost/127.0.0.1 en cualquier puerto) se permiten
// siempre: solo existen en la maquina del desarrollador, y asi el front funciona
// desde cualquier servidor local (http.server, Live Server...) sin tocar el .env.
import cors from "cors";

const LOOPBACK = /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/;

export function setupCors(origenes) {
    const lista = (origenes ?? "")
        .split(",")
        .map((o) => o.trim())
        .filter(Boolean);

    return cors({
        origin: lista.includes("*")
            ? "*"
            : (origen, listo) => listo(null, !origen || lista.includes(origen) || LOOPBACK.test(origen)),
        methods: ["GET", "POST", "PUT", "PATCH", "DELETE"],
        allowedHeaders: ["Content-Type", "X-Correlation-Id"],
        exposedHeaders: ["X-Correlation-Id"],
    });
}
