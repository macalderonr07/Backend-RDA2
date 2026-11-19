// src/middlewares/cors.js
// CORS como middleware propio (no inline en app.js) para poder fijar el
// origen permitido vía entorno en vez de abrir "*" por defecto.
import cors from "cors";

export function setupCors(origin) {
    return cors({
        origin: origin && origin !== "*" ? origin.split(",").map((o) => o.trim()) : "*",
        methods: ["GET", "POST", "PUT", "DELETE"],
    });
}
