// src/routes/v1/compras.routes.js — montado en /api/v1/compras
//   GET  /ordenes                     ordenes con estado de recepcion (?estado)
//   GET  /ordenes/:id                 cabecera + lineas (pedido, recibido, pendiente)
//   POST /ordenes                     BORRADOR {idProveedor, fechaEntregaEsperada?, observacion?, lineas[]}  (COMPRA_GESTIONAR)
//   POST /ordenes/:id/estado          {estado EMITIDA|ANULADA|CERRADA}                                      (COMPRA_GESTIONAR)
//   POST /ordenes/:id/recepciones     {lineas:[{idDetalleOrdenCompra, cantidad, codigoLote?, costoUnitario?}], idComprobanteCompra?} (INV_RECEPCIONAR)
//   GET  /comprobantes                cuentas por pagar | POST /comprobantes (COMPRA_GESTIONAR)
//   GET  /por-facturar                recepciones sin factura del proveedor
import { Router } from "express";
import { body, query } from "express-validator";
import * as c from "../../controllers/compras.controller.js";
import { autenticar, exigirPermiso } from "../../middlewares/autenticacion.js";
import { paginacion, reglasPaginacion } from "../../middlewares/paginacion.js";
import { manejarValidacion } from "../../middlewares/validacion.js";
import { fecha, id, idParam, lista, numero, texto } from "../../middlewares/validarNegocio.js";

const router = Router();
router.use(autenticar);
const gestionar = exigirPermiso("COMPRA_GESTIONAR");

router.get(
    "/ordenes",
    reglasPaginacion,
    query("estado").optional().isIn(["BORRADOR", "EMITIDA", "CERRADA", "ANULADA"]),
    manejarValidacion,
    paginacion,
    c.listarOrdenes
);
router.get("/ordenes/:id", idParam(), manejarValidacion, c.obtenerOrden);
router.post(
    "/ordenes",
    gestionar,
    id("idProveedor", { etiqueta: "Proveedor" }),
    fecha("fechaEntregaEsperada", { etiqueta: "Entrega esperada" }),
    texto("observacion", "texto", { etiqueta: "Observación", opcional: true, max: 250 }),
    lista("lineas", { min: 1, max: 100, etiqueta: "Líneas" }),
    body("lineas.*.idVariante").isInt({ min: 1 }).withMessage("Elige el producto de cada línea").toInt(),
    numero("lineas.*.cantidad", "cantidad", { etiqueta: "Cantidad", minimo: 0 }),
    numero("lineas.*.costoUnitario", "costo", { etiqueta: "Costo unitario" }),
    manejarValidacion,
    c.crearOrden
);
router.post(
    "/ordenes/:id/estado",
    gestionar,
    idParam(),
    body("estado").isIn(["EMITIDA", "ANULADA", "CERRADA"]).withMessage("Estado no válido"),
    manejarValidacion,
    c.cambiarEstado
);
router.post(
    "/ordenes/:id/recepciones",
    exigirPermiso("INV_RECEPCIONAR"),
    idParam(),
    lista("lineas", { min: 1, max: 300, etiqueta: "Líneas recibidas" }),
    body("lineas.*.idDetalleOrdenCompra").isInt({ min: 1 }).toInt(),
    numero("lineas.*.cantidad", "cantidad", { etiqueta: "Cantidad recibida", minimo: 0 }),
    numero("lineas.*.costoUnitario", "costo", { etiqueta: "Costo", opcional: true }),
    body("lineas.*.codigoLote").optional({ values: "falsy" }).isString().trim().matches(/^[A-Za-z0-9-]{1,30}$/).withMessage("Código de lote: letras, dígitos y guiones (hasta 30)"),
    body("lineas.*.fechaVencimiento").optional({ values: "falsy" }).isISO8601().withMessage("Vencimiento no válido"),
    id("idComprobanteCompra", { opcional: true }),
    manejarValidacion,
    c.recepcionar
);
// orden de compra: primero el producto, luego cantidades por variante
router.get("/productos", gestionar, query("q").optional().isString().trim().isLength({ max: 80 }),
    query("idProveedor").optional({ values: "falsy" }).isInt({ min: 1 }).toInt(), manejarValidacion, c.productos);
router.get("/productos/:id", gestionar, idParam(), manejarValidacion, c.producto);
router.get("/comprobantes", reglasPaginacion, manejarValidacion, paginacion, c.comprobantes);
router.post(
    "/comprobantes",
    gestionar,
    id("idProveedor", { etiqueta: "Proveedor" }),
    body("tipo").isIn(["01", "02", "00"]).withMessage("Tipo de comprobante no válido"),
    // un recibo (00) no trae numero del proveedor: lo genera el servidor (REC-000001...)
    body("numero").if((v, { req }) => req.body.tipo !== "00").isString().withMessage("Escribe el número del comprobante").trim()
        .matches(/^(\d{3}-\d{3}-\d{9}|[A-Z0-9-]{1,20})$/).withMessage("Número: 001-001-000000123"),
    fecha("fechaEmision", { opcional: false, etiqueta: "Emisión" }),
    fecha("fechaVencimiento", { opcional: false, etiqueta: "Vencimiento" }),
    numero("subtotal0", "dinero", { opcional: true, etiqueta: "Subtotal 0 %" }),
    numero("subtotalGravado", "dinero", { opcional: true, etiqueta: "Subtotal gravado" }),
    numero("iva", "dinero", { opcional: true, etiqueta: "IVA" }),
    body("claveAcceso").optional({ values: "falsy" }).matches(/^\d{49}$/).withMessage("La clave de acceso tiene 49 dígitos"),
    manejarValidacion,
    c.registrarComprobante
);
router.get("/por-facturar", c.porFacturar);

export default router;
