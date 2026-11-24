// src/routes/v1/combos.routes.js
// Montado en /api/v1/combos. Solo lectura (los combos los arma produccion):
//   GET /             combos ofrecidos (?producto=CE-9001 filtra los que lo incluyen)
//   GET /:codigo      un combo con sus componentes, precio y disponibilidad
// Para venderlo: POST /api/v1/carritos/:token/combos (lo convierte en lineas).
import { Router } from "express";
import { listar, obtener } from "../../controllers/combos.controller.js";
import { manejarValidacion } from "../../middlewares/validacion.js";
import { reglasCodigoCombo, reglasFiltroCombos } from "../../middlewares/validarCombo.js";

const router = Router();

router.get("/", reglasFiltroCombos, manejarValidacion, listar);
router.get("/:codigo", reglasCodigoCombo, manejarValidacion, obtener);

export default router;
