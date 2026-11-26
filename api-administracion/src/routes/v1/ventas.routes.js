// src/routes/v1/ventas.routes.js — montado en /api/v1/ventas
//   GET  /pedidos                 todos los canales (?estado, ?canal, ?q cliente o numero)
//   GET  /pedidos/:id             lineas, totales, pagos, historial, comprobantes
//   POST /pedidos                 venta en tienda/WhatsApp {idCliente, canal TDA|WSP, lineas[], observacion?} (VENTA_REGISTRAR)
//   POST /pedidos/:id/pagos       {idMetodoPago, monto, referencia?}                    (PAGO_REGISTRAR)
//   POST /pedidos/:id/factura     {idDatosFacturacion, idPuntoEmision, tipo 01|02, plazoDias?} (VENTA_FACTURAR)
//   POST /pedidos/:id/estado      {estado DES|ENT|CAN, observacion?}   (PEDIDO_DESPACHAR o VENTA_REGISTRAR)
//   GET  /productos?q=            productos a la venta (uno por fila) | GET /productos/:id variantes, formas y piezas
//   GET  /presentaciones?q=       lo vendible, con precio final y disponible
//   GET  /cuentas-por-cobrar | POST /abonos {idCliente, monto, idMetodoPago, referencia?} (PAGO_REGISTRAR)
import { Router } from "express";
import { body, query } from "express-validator";
import * as c from "../../controllers/ventas.controller.js";
import * as cot from "../../controllers/cotizaciones.controller.js";
import { autenticar, exigirPermiso } from "../../middlewares/autenticacion.js";
import { paginacion, reglasPaginacion } from "../../middlewares/paginacion.js";
import { manejarValidacion } from "../../middlewares/validacion.js";
import { booleano, id, idParam, lista, numero, texto } from "../../middlewares/validarNegocio.js";
import { PATRONES, identificacionValida, regex } from "../../utils/patrones.js";

const router = Router();
router.use(autenticar);

router.get(
    "/pedidos",
    reglasPaginacion,
    query("estado").optional().isIn(["PEN", "PAG", "FAC", "DES", "ENT", "CAN"]),
    // Pedidos (en curso o cancelados) y Ventas (facturadas o entregadas) se ven aparte
    query("grupo").optional().isIn(["pedidos", "ventas"]),
    query("canal").optional().isIn(["TDA", "WEB", "WSP"]),
    query("q").optional().isString().trim().isLength({ max: 80 }),
    manejarValidacion,
    paginacion,
    c.listar
);
router.get("/pedidos/:id", idParam(), manejarValidacion, c.obtener);
router.post(
    "/pedidos",
    exigirPermiso("VENTA_REGISTRAR"),
    id("idCliente", { etiqueta: "Cliente" }),
    body("canal").isIn(["TDA", "WSP"]).withMessage("Canal: tienda o WhatsApp (los pedidos web nacen en la tienda en línea)"),
    lista("lineas", { min: 1, max: 100, etiqueta: "Líneas" }),
    body("lineas.*.idPresentacion").isInt({ min: 1 }).withMessage("Elige el producto de cada línea").toInt(),
    numero("lineas.*.cantidad", "cantidad", { etiqueta: "Cantidad", minimo: 0 }),
    body("lineas.*.idLote").optional({ values: "falsy" }).isInt({ min: 1 }).toInt(),
    numero("lineas.*.valorFinal", "dinero", { etiqueta: "Valor pactado", opcional: true }),
    texto("observacion", "texto", { etiqueta: "Observación", opcional: true, max: 250 }),
    // pedido a domicilio: la direccion es obligatoria; sin envio, retira en el local
    body("envio").optional({ values: "null" }).isObject().withMessage("Envío no válido"),
    body("envio.idDireccion").if(body("envio").exists({ values: "null" })).isInt({ min: 1 }).withMessage("Elige la dirección de entrega").toInt(),
    numero("envio.costo", "dinero", { etiqueta: "Costo del envío", opcional: true }),
    body("envio.idTransportista").optional({ values: "falsy" }).isInt({ min: 1 }).toInt(),
    manejarValidacion,
    c.crear
);

// Avance de dinero al cliente (cuenta por cobrar tipo AVANCE)
router.post(
    "/pedidos/:id/avances",
    exigirPermiso("CREDITO_OTORGAR"),
    idParam(),
    numero("monto", "dinero", { etiqueta: "Monto", minimo: 0 }),
    texto("concepto", "texto", { etiqueta: "Concepto", max: 150 }),
    id("idMetodoPago", { etiqueta: "Cómo se entregó el dinero" }),
    id("idMotivoAvance", { etiqueta: "Motivo", opcional: true }),
    body("plazoDias").isInt({ min: 1, max: 365 }).withMessage("Plazo: de 1 a 365 días").toInt(),
    manejarValidacion,
    c.registrarAvance
);

// ---- Clientes de la venta: buscar por nombre, cedula/RUC o telefono; alta en linea
// p = prefijo ("direccion." dentro del alta del cliente). Las reglas de un
// objeto anidado solo corren si el objeto vino (.if): sin direccion, no se piden.
const vino = (objeto) => (v, { req }) => !objeto || (req.body[objeto] !== undefined && req.body[objeto] !== null);
const reglasDireccion = (p, objeto = null) => [
    body(`${p}idCiudad`).if(vino(objeto)).isInt({ min: 1 }).withMessage("Elige la ciudad").toInt(),
    // .if va ANTES de exists(): si no vino la direccion, no se exige la calle
    body(`${p}callePrincipal`).if(vino(objeto)).exists({ values: "falsy" }).withMessage("Calle principal es obligatorio").bail()
        .isString().trim().isLength({ max: 120 }).withMessage("Calle principal: hasta 120 caracteres")
        .matches(regex("nombre")).withMessage(`Calle principal: ${PATRONES.nombre.mensaje}`),
    // toda direccion pertenece a un sector de su ciudad (se crea si no existe)
    body(`${p}sector`).if(vino(objeto)).exists({ values: "falsy" }).withMessage("Sector es obligatorio").bail()
        .isString().trim().isLength({ min: 2, max: 80 }).withMessage("Sector: de 2 a 80 caracteres")
        .matches(regex("nombre")).withMessage(`Sector: ${PATRONES.nombre.mensaje}`),
    texto(`${p}numero`, "codigo", { etiqueta: "Número", opcional: true, max: 15 }),
    texto(`${p}calleSecundaria`, "nombre", { etiqueta: "Calle secundaria", opcional: true, max: 120 }),
    texto(`${p}referencia`, "texto", { etiqueta: "Referencia", opcional: true, max: 200 }),
];
const reglasFacturacion = (p, objeto = null) => {
    const datos = (req) => (objeto ? req.body[objeto] : req.body) ?? {};
    // consumidor final no lleva identificacion ni razon social (la base usa 9999999999999)
    const conIdentificacion = (v, { req }) => vino(objeto)(v, { req }) && !datos(req).consumidorFinal;
    return [
        booleano(`${p}consumidorFinal`),
        body(`${p}idTipoIdentificacion`).if(conIdentificacion).isIn(["04", "05", "06"]).withMessage("Tipo: cédula, RUC o pasaporte"),
        body(`${p}identificacion`).if(conIdentificacion).isString().withMessage("Escribe la identificación").trim().toUpperCase()
            .custom((v, { req }) => {
                const error = identificacionValida(String(datos(req).idTipoIdentificacion ?? ""), v);
                if (error) throw new Error(error);
                return true;
            }),
        body(`${p}razonSocial`).if(conIdentificacion).isString().withMessage("Escribe la razón social").trim()
            .isLength({ min: 2, max: 150 }).withMessage("Razón social: de 2 a 150 caracteres").matches(/^[^<>]+$/u).withMessage("Razón social: sin < ni >"),
        texto(`${p}correo`, "correo", { etiqueta: "Correo para la factura", opcional: true, max: 120, minusculas: true }),
        // sector obligatorio (la direccion no): ciudad + nombre, o el de la direccion elegida
        body(`${p}idCiudad`).if(conIdentificacion).optional({ values: "falsy" }).isInt({ min: 1 }).withMessage("Elige la ciudad").toInt(),
        texto(`${p}sector`, "nombre", { etiqueta: "Sector", opcional: true, max: 80 }),
    ];
};
router.get("/sectores", query("idCiudad").isInt({ min: 1 }).withMessage("Elige la ciudad").toInt(), manejarValidacion, c.sectores);
router.get("/clientes", query("q").optional().isString().trim().isLength({ max: 60 }), manejarValidacion, c.buscarClientes);
router.get("/clientes/:id", idParam(), manejarValidacion, c.fichaCliente);
router.get("/clientes/:id/deudas", idParam(), manejarValidacion, c.deudasCliente);
router.post(
    "/clientes",
    exigirPermiso("VENTA_REGISTRAR"),
    texto("nombres", "nombre", { etiqueta: "Nombres o razón social", max: 100 }),
    texto("apellidos", "nombrePersona", { etiqueta: "Apellidos", opcional: true, max: 100 }),
    texto("correo", "correo", { etiqueta: "Correo", opcional: true, max: 120, minusculas: true }),
    body("telefono").optional({ values: "falsy" }).isString().customSanitizer((v) => String(v).replace(/[\s()-]/g, "")).matches(/^0\d{8,9}$/).withMessage("Teléfono: 09XXXXXXXX o fijo 02XXXXXXX"),
    body("direccion").optional({ values: "null" }).isObject(),
    ...reglasDireccion("direccion.", "direccion"),
    body("facturacion").optional({ values: "null" }).isObject(),
    ...reglasFacturacion("facturacion.", "facturacion"),
    manejarValidacion,
    c.crearCliente
);
router.post("/clientes/:id/facturacion", exigirPermiso("VENTA_REGISTRAR"), idParam(), ...reglasFacturacion(""),
    body("idDireccion").optional({ values: "falsy" }).isInt({ min: 1 }).toInt(),
    manejarValidacion, c.agregarFacturacion);
// ---- Cotizaciones de la tienda (ventas por confirmar): no reservan stock; se
// editan, se confirman como pedido o vencen a los 14 dias
const registrar = exigirPermiso("VENTA_REGISTRAR");
router.get("/cotizaciones", query("estado").optional().isIn(["PENDIENTE", "CONFIRMADA"]),
    query("q").optional().isString().trim().isLength({ max: 60 }), ...reglasPaginacion, manejarValidacion, paginacion, cot.listar);
router.get("/cotizaciones/:id", idParam(), manejarValidacion, cot.obtener);
router.patch("/cotizaciones/:id/lineas/:idLinea", registrar, idParam(), idParam("idLinea"),
    body("cantidad").isFloat({ gt: 0, max: 100000 }).withMessage("Cantidad: mayor que 0").toFloat(), manejarValidacion, cot.cambiarCantidad);
router.delete("/cotizaciones/:id/lineas/:idLinea", registrar, idParam(), idParam("idLinea"), manejarValidacion, cot.quitarLinea);
router.post("/cotizaciones/:id/lineas", registrar, idParam(), body("idPresentacion").isInt({ min: 1 }).withMessage("Elige la forma de venta").toInt(),
    body("cantidad").isFloat({ gt: 0, max: 100000 }).withMessage("Cantidad: mayor que 0").toFloat(), manejarValidacion, cot.agregarLinea);
router.post("/cotizaciones/:id/confirmar", registrar, idParam(), manejarValidacion, cot.confirmar);
router.delete("/cotizaciones/:id", registrar, idParam(), manejarValidacion, cot.descartar);

router.post("/clientes/:id/direcciones", exigirPermiso("VENTA_REGISTRAR"), idParam(), ...reglasDireccion(""), manejarValidacion, c.agregarDireccion);
router.post(
    "/pedidos/:id/pagos",
    exigirPermiso("PAGO_REGISTRAR"),
    idParam(),
    id("idMetodoPago", { etiqueta: "Método de pago" }),
    numero("monto", "dinero", { etiqueta: "Monto", minimo: 0 }),
    body("referencia").optional({ values: "falsy" }).isString().trim().matches(/^[A-Za-z0-9 .#/-]{1,60}$/).withMessage("Referencia: letras, dígitos y - / # (hasta 60)"),
    manejarValidacion,
    c.pagar
);
router.post(
    "/pedidos/:id/factura",
    exigirPermiso("VENTA_FACTURAR"),
    idParam(),
    id("idDatosFacturacion", { etiqueta: "Datos de facturación", opcional: true }),
    id("idPuntoEmision", { etiqueta: "Punto de emisión" }),
    body("tipo").isIn(["01", "02"]).withMessage("Tipo: factura (01) o nota de venta (02)"),
    body("plazoDias").optional({ values: "falsy" }).isInt({ min: 1, max: 180 }).withMessage("Plazo de crédito: 1 a 180 días").toInt(),
    body().custom((b) => {
        if (b.tipo === "01" && !b.idDatosFacturacion) throw new Error("La factura necesita los datos de facturación del cliente");
        return true;
    }),
    manejarValidacion,
    c.facturar
);
router.post(
    "/pedidos/:id/estado",
    exigirPermiso("PEDIDO_DESPACHAR", "VENTA_REGISTRAR"),
    idParam(),
    body("estado").isIn(["DES", "ENT", "CAN"]).withMessage("Estado: despachado, entregado o cancelado"),
    texto("observacion", "texto", { etiqueta: "Observación", opcional: true, max: 200 }),
    manejarValidacion,
    c.cambiarEstado
);
// venta de mostrador: primero el producto, luego se especifica (variante, forma de venta, pieza)
router.get("/productos", query("q").optional().isString().trim().isLength({ max: 80 }), manejarValidacion, c.productos);
router.get("/productos/:id", idParam(), manejarValidacion, c.producto);
router.get("/presentaciones", query("q").optional().isString().trim().isLength({ max: 80 }), manejarValidacion, c.presentaciones);
router.get("/cuentas-por-cobrar", c.cuentasPorCobrar);
router.post(
    "/abonos",
    exigirPermiso("PAGO_REGISTRAR"),
    id("idCliente", { etiqueta: "Cliente" }),
    numero("monto", "dinero", { etiqueta: "Monto", minimo: 0 }),
    id("idMetodoPago", { etiqueta: "Método de pago" }),
    body("referencia").optional({ values: "falsy" }).isString().trim().matches(/^[A-Za-z0-9 .#/-]{1,60}$/),
    manejarValidacion,
    c.abonar
);

export default router;
