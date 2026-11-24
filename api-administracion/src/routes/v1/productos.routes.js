// src/routes/v1/productos.routes.js — montado en /api/v1/catalogo
//   GET    /productos                          lista (?q, ?idCategoria, ?publicado, paginada)
//   GET    /productos/:id                      producto completo (variantes, formas de venta, precios, stock)
//   POST   /productos                          alta con variantes + formas de venta + precios (CATALOGO_GESTIONAR)
//   PATCH  /productos/:id                      datos generales, publicar (CATALOGO_GESTIONAR)
//   POST   /productos/:id/variantes            nueva variante (copia formas de venta y precios)
//   PATCH  /variantes/:idVariante              activa / stock minimo
//   POST   /productos/:id/formas-de-venta      nueva forma de venta para todas las variantes, con precio
//   PATCH  /productos/:id/formas-de-venta      {descripcion, activa?, cantidadMinima?, incremento?}
//   POST   /productos/:id/precios              precio nuevo {descripcion | idPresentacion, precio} (PRECIO_GESTIONAR)
//   GET    /productos/:id/precios              historial de precios
//   GET    /ofertas | POST /ofertas | PATCH /ofertas/:idOferta   (PRECIO_GESTIONAR)
//   GET    /combos  | POST /combos | PUT /combos/:idCombo | DELETE /combos/:idCombo (CATALOGO_GESTIONAR)
import { Router } from "express";
import { body, query } from "express-validator";
import * as c from "../../controllers/productos.controller.js";
import { autenticar, exigirPermiso } from "../../middlewares/autenticacion.js";
import { paginacion, reglasPaginacion } from "../../middlewares/paginacion.js";
import { manejarValidacion } from "../../middlewares/validacion.js";
import { booleano, codigoTexto, fecha, id, idParam, lista, numero, texto } from "../../middlewares/validarNegocio.js";

const router = Router();
router.use(autenticar);
const catalogo = exigirPermiso("CATALOGO_GESTIONAR");
const precios = exigirPermiso("PRECIO_GESTIONAR");

// Forma de venta (presentacion) con su precio
const formaDeVenta = (prefijo, { conPrecio = true } = {}) => [
    texto(`${prefijo}descripcion`, "nombre", { etiqueta: "Forma de venta", max: 40 }),
    numero(`${prefijo}factor`, "cantidad", { etiqueta: "Contenido en unidad base", minimo: 0 }),
    numero(`${prefijo}cantidadMinima`, "cantidad", { etiqueta: "Compra mínima", opcional: true, minimo: 0 }),
    numero(`${prefijo}incremento`, "cantidad", { etiqueta: "Se vende de a", opcional: true, minimo: 0 }),
    // el precio se escribe CON IVA; el repositorio lo convierte a la base sin IVA
    ...(conPrecio ? [numero(`${prefijo}precioConIva`, "dinero", { etiqueta: "Precio con IVA", minimo: 0 })] : []),
];

const datosGenerales = (parcial) => [
    // sin "codigo": lo genera el servidor y no se edita (utils/codigos.js)
    texto("nombre", "nombre", { etiqueta: "Nombre", opcional: parcial }),
    id("idCategoria", { etiqueta: "Categoría", opcional: parcial }),
    ...(parcial ? [] : [codigoTexto("idUnidadMedida", { etiqueta: "Unidad de medida", max: 4 })]),
    codigoTexto("idTarifaIva", { etiqueta: "Tarifa de IVA", max: 2, opcional: parcial }),
    id("idMarca", { etiqueta: "Marca", opcional: true }),
    texto("descripcion", "texto", { etiqueta: "Descripción", opcional: true, max: 300 }),
    texto("uso", "texto", { etiqueta: "Uso típico", opcional: true, max: 200 }),
    texto("imagenUrl", "url", { etiqueta: "Imagen (URL)", opcional: true, max: 500 }),
    booleano("publicado"),
    booleano("ventaPorPieza"),
    booleano("precioPorVariante"),
    // unidad de compra: "Rollo × 30 m" + contenido (30); sin contenido = piezas que se miden al recibir
    body("compraDescripcion").optional({ values: "null" }).isString().trim().isLength({ max: 40 }).withMessage("Unidad de compra: hasta 40 caracteres")
        .matches(/^[^<>]*$/u).withMessage("Unidad de compra: sin < ni >"),
    body("compraFactor").optional({ values: "falsy" }).isFloat({ gt: 0, max: 100000 }).withMessage("Contenido de la unidad de compra: un número mayor que 0").toFloat(),
    ...(parcial ? [] : [booleano("cortesEstandar")]),
];

router.get(
    "/productos",
    reglasPaginacion,
    query("q").optional().isString().trim().isLength({ max: 80 }),
    query("idCategoria").optional().isInt({ min: 1 }).toInt(),
    query("publicado").optional().isIn(["0", "1"]).toInt(),
    query("requiereCompra").optional({ values: "falsy" }).isIn(["0", "1"]).customSanitizer((v) => v === "1"),
    manejarValidacion,
    paginacion,
    c.listar
);
router.get("/productos/:id", idParam(), manejarValidacion, c.obtener);
// Atributos para las variantes de un producto nuevo: los de la categoria (y su linea) y los demas
router.get("/categorias/:id/atributos", idParam(), manejarValidacion, c.atributosDeCategoria);
router.post(
    "/productos",
    catalogo,
    precios,
    ...datosGenerales(false),
    lista("variantes", { min: 0, max: 300, etiqueta: "Variantes" }).optional(),
    body("variantes.*.valores").optional().isArray({ max: 6 }),
    body("variantes.*.valores.*").isInt({ min: 1 }).toInt(),
    numero("variantes.*.stockMinimo", "cantidad", { opcional: true, etiqueta: "Stock mínimo" }),
    lista("presentaciones", { min: 1, max: 12, etiqueta: "Formas de venta" }),
    ...formaDeVenta("presentaciones.*."),
    manejarValidacion,
    c.crear
);
router.patch("/productos/:id", catalogo, idParam(), ...datosGenerales(true), manejarValidacion, c.actualizar);
router.post(
    "/productos/:id/variantes",
    catalogo,
    idParam(),
    lista("valores", { min: 0, max: 6, etiqueta: "Valores" }),
    body("valores.*").isInt({ min: 1 }).toInt(),
    numero("stockMinimo", "cantidad", { opcional: true, etiqueta: "Stock mínimo" }),
    manejarValidacion,
    c.agregarVariante
);
router.patch(
    "/variantes/:idVariante",
    catalogo,
    idParam("idVariante"),
    booleano("activa"),
    numero("stockMinimo", "cantidad", { opcional: true, etiqueta: "Stock mínimo" }),
    manejarValidacion,
    c.actualizarVariante
);
router.post("/productos/:id/formas-de-venta", catalogo, precios, idParam(), ...formaDeVenta(""), manejarValidacion, c.agregarPresentacion);
router.patch(
    "/productos/:id/formas-de-venta",
    catalogo,
    idParam(),
    texto("descripcion", "nombre", { etiqueta: "Forma de venta", max: 40 }),
    booleano("activa"),
    numero("cantidadMinima", "cantidad", { opcional: true, etiqueta: "Compra mínima", minimo: 0 }),
    numero("incremento", "cantidad", { opcional: true, etiqueta: "Se vende de a", minimo: 0 }),
    manejarValidacion,
    c.actualizarFormaDeVenta
);
router.post(
    "/productos/:id/precios",
    precios,
    idParam(),
    texto("descripcion", "nombre", { etiqueta: "Forma de venta", max: 40, opcional: true }),
    id("idPresentacion", { opcional: true }),
    body().custom((b) => {
        if (!b.descripcion && !b.idPresentacion) throw new Error("Indica la forma de venta");
        return true;
    }),
    numero("precioConIva", "dinero", { etiqueta: "Precio con IVA", minimo: 0 }),
    manejarValidacion,
    c.registrarPrecio
);
router.get("/productos/:id/precios", idParam(), manejarValidacion, c.historialPrecios);

router.get("/ofertas", c.listarOfertas);
router.post(
    "/ofertas",
    precios,
    id("idProducto", { etiqueta: "Producto" }),
    numero("porcentaje", "porcentaje", { etiqueta: "Porcentaje" }),
    fecha("desde", { etiqueta: "Desde" }),
    fecha("hasta", { etiqueta: "Hasta" }),
    texto("descripcion", "nombre", { etiqueta: "Descripción", opcional: true, max: 100 }),
    manejarValidacion,
    c.crearOferta
);
router.patch("/ofertas/:idOferta", precios, idParam("idOferta"), booleano("activa", { opcional: false }), fecha("hasta"), manejarValidacion, c.cambiarEstadoOferta);

const combo = [
    // sin "codigo": CMB-0001, CMB-0002... lo genera el servidor
    texto("nombre", "nombre", { etiqueta: "Nombre", max: 120 }),
    texto("descripcion", "texto", { etiqueta: "Descripción", opcional: true, max: 300 }),
    booleano("publicado"),
    lista("componentes", { min: 2, max: 10, etiqueta: "Componentes" }),
    body("componentes.*.idProducto").isInt({ min: 1 }).withMessage("Elige el producto").toInt(),
    body("componentes.*.presentacion").isString().trim().isLength({ min: 1, max: 40 }).withMessage("Indica la forma de venta"),
    numero("componentes.*.cantidad", "cantidad", { etiqueta: "Cantidad", minimo: 0 }),
];
router.get("/combos", c.listarCombos);
router.post("/combos", catalogo, ...combo, manejarValidacion, c.guardarCombo);
router.put("/combos/:idCombo", catalogo, idParam("idCombo"), ...combo, manejarValidacion, c.guardarCombo);
router.delete("/combos/:idCombo", catalogo, idParam("idCombo"), manejarValidacion, c.eliminarCombo);

export default router;
