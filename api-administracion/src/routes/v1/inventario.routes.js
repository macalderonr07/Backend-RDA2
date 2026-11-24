// src/routes/v1/inventario.routes.js — montado en /api/v1/inventario
//   GET  /stock                        existencias por variante (?q, ?requiereCompra=1, ?idProducto, paginada)
//   GET  /variantes/:idVariante/lotes  lotes o piezas con saldo, reservado y libre
//   GET  /variantes/:idVariante/kardex kardex valorizado
//   GET  /tipos-movimiento
//   POST /ajustes                      {idVariante, tipo INI|AJP|AJN|MER, cantidad, motivo, costoUnitario?, idLote?}  (INV_AJUSTAR)
//   POST /lotes/:idLote/fraccionar     {piezas:[11.2, 11.2], motivo?}                                     (INV_FRACCIONAR)
//   POST /lotes/:idLote/devolver       {cantidad, motivo}  devolucion al proveedor                        (COMPRA_GESTIONAR)
import { Router } from "express";
import { body, query } from "express-validator";
import * as c from "../../controllers/inventario.controller.js";
import { autenticar, exigirPermiso } from "../../middlewares/autenticacion.js";
import { paginacion, reglasPaginacion } from "../../middlewares/paginacion.js";
import { manejarValidacion } from "../../middlewares/validacion.js";
import { fecha, id, idParam, lista, numero, texto } from "../../middlewares/validarNegocio.js";
import { PATRONES, regex } from "../../utils/patrones.js";

const router = Router();
router.use(autenticar);

router.get(
    "/stock",
    reglasPaginacion,
    query("q").optional().isString().trim().isLength({ max: 80 }),
    query("requiereCompra").optional({ values: "falsy" }).isIn(["0", "1"]).customSanitizer((v) => v === "1"),
    query("idVariante").optional({ values: "falsy" }).isInt({ min: 1 }).toInt(),
    query("idProducto").optional({ values: "falsy" }).isInt({ min: 1 }).toInt(),
    manejarValidacion,
    paginacion,
    c.stock
);
router.get("/variantes/:idVariante/lotes", idParam("idVariante"), manejarValidacion, c.lotes);
router.get("/variantes/:idVariante/kardex", idParam("idVariante"), manejarValidacion, c.kardex);
router.get("/tipos-movimiento", c.tiposMovimiento);

router.post(
    "/ajustes",
    exigirPermiso("INV_AJUSTAR"),
    id("idVariante", { etiqueta: "Variante" }),
    body("tipo").isIn(["INI", "AJP", "AJN", "MER"]).withMessage("Tipo de ajuste no válido"),
    numero("cantidad", "cantidad", { etiqueta: "Cantidad", minimo: 0 }),
    texto("motivo", "texto", { etiqueta: "Motivo", max: 200 }),
    numero("costoUnitario", "costo", { etiqueta: "Costo unitario", opcional: true }),
    id("idLote", { opcional: true }),
    fecha("fechaVencimiento", { etiqueta: "Vencimiento" }),
    manejarValidacion,
    c.ajustar
);
router.post(
    "/lotes/:idLote/fraccionar",
    exigirPermiso("INV_FRACCIONAR"),
    idParam("idLote"),
    lista("piezas", { min: 1, max: 50, etiqueta: "Piezas" }),
    body("piezas.*")
        .customSanitizer((v) => (typeof v === "number" ? String(v) : v))
        .matches(regex("cantidad"))
        .withMessage(`Cada pieza: ${PATRONES.cantidad.mensaje}`)
        .toFloat(),
    texto("motivo", "texto", { etiqueta: "Motivo", opcional: true, max: 200 }),
    manejarValidacion,
    c.fraccionar
);
router.post(
    "/lotes/:idLote/devolver",
    exigirPermiso("COMPRA_GESTIONAR"),
    idParam("idLote"),
    numero("cantidad", "cantidad", { etiqueta: "Cantidad", minimo: 0 }),
    texto("motivo", "texto", { etiqueta: "Motivo", max: 200 }),
    manejarValidacion,
    c.devolver
);

export default router;
