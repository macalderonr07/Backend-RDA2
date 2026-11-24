// src/app.js — ensambla middlewares globales y routers (ARQUITECTURA.md 5).
// Orden: json -> CORS -> correlacion -> log -> routers v1 -> 404 -> errores.
import express from "express";
import morgan from "morgan";
import { config } from "./config/env.js";
import { meta } from "./controllers/meta.controller.js";
import { autenticar } from "./middlewares/autenticacion.js";
import { correlation } from "./middlewares/correlation.js";
import { setupCors } from "./middlewares/cors.js";
import { errorHandler, notFoundHandler } from "./middlewares/errorHandler.js";
import authRouter from "./routes/v1/auth.routes.js";
import comprasRouter from "./routes/v1/compras.routes.js";
import inventarioRouter from "./routes/v1/inventario.routes.js";
import productosRouter from "./routes/v1/productos.routes.js";
import { montarRecursos } from "./routes/v1/recursos.routes.js";
import reportesRouter from "./routes/v1/reportes.routes.js";
import usuariosRouter from "./routes/v1/usuarios.routes.js";
import ventasRouter from "./routes/v1/ventas.routes.js";

export const app = express();

app.disable("x-powered-by");
app.use(express.json({ limit: "200kb" }));
app.use(setupCors(config.clientOrigin));
app.use(correlation);
morgan.token("id", (req) => req.correlationId);
app.use(morgan(":method :url :status :response-time ms [:id]"));

app.get("/api/v1/salud", (_req, res) => res.json({ status: "success", data: { servicio: "administracion" } }));
app.use("/api/v1/auth", authRouter);
app.get("/api/v1/meta", autenticar, meta);
// Modulos con logica propia ANTES de los recursos genericos: /productos y
// /usuarios tienen su CRUD especifico (el generico de esos dos es solo /opciones)
app.use("/api/v1/catalogo", productosRouter);
app.use("/api/v1/inventario", inventarioRouter);
app.use("/api/v1/compras", comprasRouter);
app.use("/api/v1/ventas", ventasRouter);
app.use("/api/v1/seguridad", usuariosRouter);
app.use("/api/v1/reportes", reportesRouter);
montarRecursos(app);

app.use(notFoundHandler);
app.use(errorHandler);
