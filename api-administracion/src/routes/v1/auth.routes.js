// src/routes/v1/auth.routes.js — montado en /api/v1/auth
//   POST /ingresar      {correo, clave} -> { token, usuario }
//   GET  /yo            perfil, roles y permisos del usuario de la sesion
//   PUT  /clave         {claveActual, claveNueva} cambia la propia clave
import { Router } from "express";
import { body } from "express-validator";
import { cambiarMiClave, ingresar, yo } from "../../controllers/auth.controller.js";
import { autenticar } from "../../middlewares/autenticacion.js";
import { manejarValidacion } from "../../middlewares/validacion.js";
import { PATRONES, regex } from "../../utils/patrones.js";

const router = Router();

router.post(
    "/ingresar",
    body("correo").isString().trim().toLowerCase().matches(regex("correo")).withMessage(PATRONES.correo.mensaje),
    body("clave").isString().isLength({ min: 1, max: 128 }).withMessage("Escribe tu clave"),
    manejarValidacion,
    ingresar
);
router.get("/yo", autenticar, yo);
router.put(
    "/clave",
    autenticar,
    body("claveActual").isString().isLength({ min: 1, max: 128 }).withMessage("Escribe tu clave actual"),
    body("claveNueva").isString().matches(regex("clave")).withMessage(PATRONES.clave.mensaje),
    manejarValidacion,
    cambiarMiClave
);

export default router;
