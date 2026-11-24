// src/routes/v1/reportes.routes.js — montado en /api/v1/reportes
//   GET /resumen        lo que conviene atender hoy (pantalla de Inicio)
//   GET /indicadores    KPI del periodo con variacion vs. el periodo anterior
//   GET /tableros       configuracion de tableros (widgets)
//   GET /               catalogo de reportes del usuario (con metadatos)
//   GET /:id            filas + metadatos + totales del reporte
import { Router } from "express";
import { param, query } from "express-validator";
import * as c from "../../controllers/reportes.controller.js";
import { autenticar } from "../../middlewares/autenticacion.js";
import { manejarValidacion } from "../../middlewares/validacion.js";

const router = Router();
router.use(autenticar);

const fecha = (nombre, etiqueta) =>
    query(nombre).optional({ values: "falsy" }).matches(/^\d{4}-\d{2}-\d{2}$/).withMessage(`${etiqueta}: fecha AAAA-MM-DD`)
        .custom((v) => !Number.isNaN(Date.parse(`${v}T00:00:00Z`))).withMessage(`${etiqueta}: fecha no válida`);
const periodo = [
    fecha("desde", "Desde"),
    fecha("hasta", "Hasta"),
    query("agrupar").optional({ values: "falsy" }).isIn(["dia", "semana", "mes"]).withMessage("Agrupar: día, semana o mes"),
    manejarValidacion,
];

router.get("/resumen", c.resumen);
router.get("/indicadores", ...periodo, c.indicadores);
router.get("/tableros", c.tableros);
router.get("/", c.catalogo);
router.get("/:id", param("id").matches(/^[a-z-]{1,40}$/).withMessage("Reporte no válido"), ...periodo, c.reporte);

export default router;
