// src/middlewares/validarCarrito.js
// Validacion + normalizacion de tipos para el carrito. No hay texto libre que
// sanitizar: solo un token UUID, ids enteros y cantidades numericas.
import { body, param, query } from "express-validator";

const CANTIDAD_MAXIMA = 100000; // tope de cordura, la base solo exige > 0
const ITEMS_MAXIMOS = 200;

// La base genera el token con SYS_GUID() en formato 8-4-4-4-12 hexadecimal. No es
// un UUID RFC 4122 (no lleva version), por eso no sirve isUUID(): se valida la forma.
const FORMATO_TOKEN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export const reglasToken = [
    param("token")
        .trim()
        .toLowerCase()
        .matches(FORMATO_TOKEN)
        .withMessage("token debe ser el identificador devuelto al crear el carrito"),
];

export const reglasIdPresentacionParam = [
    param("idPresentacion").isInt({ min: 1 }).withMessage("idPresentacion debe ser un entero positivo").toInt(),
    // ?pieza= la banda de la linea (productos por pieza); sin ella, la linea sin pieza
    query("pieza").optional().isInt({ min: 0 }).withMessage("pieza debe ser un entero (id de la pieza)").toInt(),
];

// pieza: la banda elegida (id de la pieza en v_pieza_web). Opcional: 0/ausente = sin pieza
const pieza = (campo) =>
    body(campo).optional({ values: "null" }).isInt({ min: 0 }).withMessage("pieza debe ser un entero (id de la pieza)").toInt();

const cantidad = (campo) =>
    body(campo)
        .exists({ values: "null" })
        .withMessage("cantidad es requerida")
        .isFloat({ gt: 0, max: CANTIDAD_MAXIMA })
        .withMessage(`cantidad debe ser un numero mayor que 0 y hasta ${CANTIDAD_MAXIMA}`)
        .toFloat();

// POST /items: agrega (o suma a) una linea
export const reglasNuevoItem = [
    body("idPresentacion").isInt({ min: 1 }).withMessage("idPresentacion debe ser un entero positivo").toInt(),
    cantidad("cantidad"),
    pieza("pieza"),
];

// PATCH /items/:idPresentacion: cambia solo la cantidad
export const reglasCantidad = [cantidad("cantidad")];

// POST /:token/pedido: confirma el carrito como pedido WEB
export const reglasPedidoNuevo = [
    body("observacion")
        .optional({ values: "falsy" })
        .isString()
        .withMessage("observacion debe ser texto")
        .trim()
        .isLength({ max: 250 })
        .withMessage("observacion debe tener hasta 250 caracteres"),
];

// PUT /items: reemplaza el contenido completo del carrito
export const reglasReemplazoItems = [
    body("items")
        .isArray({ max: ITEMS_MAXIMOS })
        .withMessage(`items debe ser un arreglo de hasta ${ITEMS_MAXIMOS} lineas`),
    body("items.*.idPresentacion").isInt({ min: 1 }).withMessage("idPresentacion debe ser un entero positivo").toInt(),
    cantidad("items.*.cantidad"),
    pieza("items.*.pieza"),
    body("items").custom((items) => {
        const claves = items.map((i) => `${Number(i.idPresentacion)}:${Number(i.pieza ?? 0)}`);
        if (new Set(claves).size !== claves.length) throw new Error("items no puede repetir una presentacion con la misma pieza");
        return true;
    }),
];
