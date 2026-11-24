// src/app.js
// Ensamblado de Express en el orden de ARQUITECTURA.md 5 (el orden importa):
// json -> CORS -> correlacion -> logging -> routers v1 -> 404 -> errorHandler.
import express from "express";
import morgan from "morgan";
import { config } from "./config/env.js";
import { db } from "./config/db.js";
import { estadoCache } from "./cache/catalogo.cache.js";
import { RespuestaFactory } from "./factories/respuesta.factory.js";
import { setupCors } from "./middlewares/cors.js";
import { correlation } from "./middlewares/correlation.js";
import { errorHandler, notFoundHandler } from "./middlewares/errorHandler.js";
import carritosV1Router from "./routes/v1/carritos.routes.js";
import categoriasV1Router from "./routes/v1/categorias.routes.js";
import combosV1Router from "./routes/v1/combos.routes.js";
import cuentasV1Router from "./routes/v1/cuentas.routes.js";
import productosV1Router from "./routes/v1/productos.routes.js";

export const app = express();

app.disable("x-powered-by"); // no anunciar el framework
app.use(express.json({ limit: "100kb" }));
app.use(setupCors(config.clientOrigin));
app.use(correlation);
morgan.token("id", (req) => req.correlationId);
app.use(morgan(":method :url :status :response-time ms [:id]"));

app.get("/", (_req, res) => {
    res.status(200).json(RespuestaFactory.exito({ servicio: "API Comercial Elite (e-commerce)", version: "v1" }));
});

// Salud real: confirma que la base responde, no solo que el proceso esta vivo
app.get("/api/v1/salud", async (_req, res, next) => {
    try {
        await db.ejecutar("SELECT 1 FROM dual");
        // la cache es opcional: si esta caida, la API sigue sana (responde desde Oracle)
        res.status(200).json(RespuestaFactory.exito({ api: "ok", baseDeDatos: "ok", cache: await estadoCache() }));
    } catch (err) {
        next(err);
    }
});

app.use("/api/v1/productos", productosV1Router);
app.use("/api/v1/categorias", categoriasV1Router);
app.use("/api/v1/combos", combosV1Router);
app.use("/api/v1/carritos", carritosV1Router);
app.use("/api/v1/cuentas", cuentasV1Router);

app.use(notFoundHandler);
app.use(errorHandler);
