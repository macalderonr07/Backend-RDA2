// src/routes/v1/productos.routes.js
// Montado en /api/v1/productos. Solo lectura: el catalogo lo administra el nodo
// produccion; el e-commerce solo tiene SELECT sobre v_catalogo_web.
import { Router } from "express";
import { listar, obtenerPorCodigo } from "../../controllers/productos.controller.js";
import { paginacion, reglasPaginacion } from "../../middlewares/paginacion.js";
import { manejarValidacion } from "../../middlewares/validacion.js";
import { reglasCodigoProducto, reglasFiltrosProducto } from "../../middlewares/validarProducto.js";

const router = Router();

router.get("/", reglasPaginacion, reglasFiltrosProducto, manejarValidacion, paginacion, listar);
router.get("/:codigo", reglasCodigoProducto, manejarValidacion, obtenerPorCodigo);

export default router;
