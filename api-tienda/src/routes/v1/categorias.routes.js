// src/routes/v1/categorias.routes.js
// Montado en /api/v1/categorias. Solo lectura: categorias PRINCIPALES (no
// subcategorias) con productos publicados.
import { Router } from "express";
import { listar } from "../../controllers/categorias.controller.js";

const router = Router();

router.get("/", listar);

export default router;
