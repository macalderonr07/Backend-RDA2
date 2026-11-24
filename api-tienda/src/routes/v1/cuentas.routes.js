// src/routes/v1/cuentas.routes.js
// Montado en /api/v1/cuentas. Cuentas de la tienda en linea:
//   POST /         crea la cuenta (201); correo ya registrado -> 409
//   POST /sesion   inicio de sesion (200 con la cuenta); credenciales malas -> 401
import { Router } from "express";
import { iniciarSesion, registrar } from "../../controllers/cuentas.controller.js";
import { manejarValidacion } from "../../middlewares/validacion.js";
import { reglasCuentaNueva, reglasInicioSesion } from "../../middlewares/validarCuenta.js";

const router = Router();

router.post("/", reglasCuentaNueva, manejarValidacion, registrar);
router.post("/sesion", reglasInicioSesion, manejarValidacion, iniciarSesion);

export default router;
