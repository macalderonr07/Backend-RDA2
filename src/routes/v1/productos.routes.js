// src/routes/v1/productos.routes.js
// Montado en app.js bajo /api/v1/productos (versionamiento por URL).
import { Router } from "express";
import { actualizar, crear, eliminar, listar, obtenerPorId } from "../../controllers/productos.controller.js";
import {
    manejarValidacion,
    reglasBusqueda,
    reglasIdParam,
    reglasPaginacion,
    reglasProducto,
} from "../../middlewares/validarProducto.js";

const router = Router();

router.get("/", reglasPaginacion, reglasBusqueda, manejarValidacion, listar);
router.get("/:id", reglasIdParam, manejarValidacion, obtenerPorId);
router.post("/", reglasProducto, manejarValidacion, crear);
router.put("/:id", reglasIdParam, reglasProducto, manejarValidacion, actualizar);
router.delete("/:id", reglasIdParam, manejarValidacion, eliminar);

export default router;
