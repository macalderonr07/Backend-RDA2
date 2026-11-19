// src/app.js
// Ensamblado de la app Express: middlewares globales, rutas versionadas y
// manejo de errores al final (el orden importa en Express).
import express from "express";
import morgan from "morgan";
import { correlation } from "./middlewares/correlation.js";
import { setupCors } from "./middlewares/cors.js";
import { errorHandler, notFoundHandler } from "./middlewares/errorHandler.js";
import productosV1Router from "./routes/v1/productos.routes.js";

export const app = express();

app.use(express.json());
app.use(setupCors(process.env.CLIENT_ORIGIN));
app.use(correlation);
app.use(morgan(":method :url :status - :response-time ms [:date[iso]]"));

app.get("/", (req, res) => {
    res.status(200).json({ status: "success", message: "API de Productos activa", version: "v1" });
});

app.use("/api/v1/productos", productosV1Router);

// A partir de aqui solo manejo de errores: 404 para rutas no mapeadas y
// handler central para todo lo que llegue via next(err).
app.use(notFoundHandler);
app.use(errorHandler);
