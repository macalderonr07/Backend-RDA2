// src/controllers/carritos.controller.js
// CRUD completo del carrito (ARQUITECTURA.md 6): el token UUID es el
// identificador publico; el id interno nunca sale de la base.
import { RespuestaFactory } from "../factories/respuesta.factory.js";
import { buscarCombo } from "../models/combo.model.js";
import {
    actualizarCantidad,
    agregarItem,
    agregarItems,
    buscarCarrito,
    crearCarrito,
    eliminarCarrito,
    eliminarItem,
    estadoPiezas,
    estadoPresentaciones,
    reemplazarItems,
} from "../models/carrito.model.js";
import { AppError } from "../utils/AppError.js";

const noExisteCarrito = (token) => new AppError(`No existe el carrito ${token}`, 404);
const noExisteItem = (id) => new AppError(`La presentacion ${id} no esta en el carrito`, 404);
const mismaLinea = (a, b) => a.idPresentacion === b.idPresentacion && (a.pieza ?? 0) === (b.pieza ?? 0);

// Reglas de entrada del carrito, con los datos de v_catalogo_web:
//  - solo presentaciones publicadas (la FK de la base solo exige que existan);
//  - cantidad >= cantidad minima de la presentacion;
//  - cantidad <= disponible (stock menos lo reservado por pedidos pendientes).
// El carrito no reserva: es la vitrina. La base vuelve a validar el stock al
// crear el pedido (fn_crear_pedido), que es la garantia real.
// lineas: [{ idPresentacion, cantidad }] con la cantidad FINAL que quedaria.
async function exigirVendibles(lineas) {
    const estado = await estadoPresentaciones(lineas.map((l) => l.idPresentacion));
    const noPublicadas = lineas.filter((l) => !estado.has(l.idPresentacion));
    if (noPublicadas.length > 0) {
        throw new AppError(
            "Presentaciones que no estan a la venta",
            422,
            noPublicadas.map((l) => ({
                campo: "idPresentacion",
                mensaje: `${l.idPresentacion} no esta publicada en el catalogo`,
            }))
        );
    }
    const bajoMinimo = lineas.filter((l) => l.cantidad < estado.get(l.idPresentacion).cantidadMinima);
    if (bajoMinimo.length > 0) {
        throw new AppError(
            "Cantidad menor que la minima de venta",
            422,
            bajoMinimo.map((l) => {
                const e = estado.get(l.idPresentacion);
                return { campo: "cantidad", mensaje: `${e.etiqueta}: se vende desde ${e.cantidadMinima}` };
            })
        );
    }
    // Incremento de venta (cuero por pie2: de 0.25 en 0.25; lo demas: enteros).
    // La base tambien lo exige al crear el pedido; aqui se avisa antes.
    const esMultiplo = (cantidad, paso) => Math.abs(cantidad / paso - Math.round(cantidad / paso)) < 1e-9;
    const fueraDePaso = lineas.filter((l) => !esMultiplo(l.cantidad, estado.get(l.idPresentacion).incremento));
    if (fueraDePaso.length > 0) {
        throw new AppError(
            "Cantidad fuera del incremento de venta",
            422,
            fueraDePaso.map((l) => {
                const e = estado.get(l.idPresentacion);
                return { campo: "cantidad", mensaje: `${e.etiqueta}: se vende en multiplos de ${e.incremento}` };
            })
        );
    }
    const sinStock = lineas.filter((l) => l.cantidad > estado.get(l.idPresentacion).disponible);
    if (sinStock.length > 0) {
        throw new AppError(
            "No hay existencias suficientes",
            409,
            sinStock.map((l) => {
                const e = estado.get(l.idPresentacion);
                return {
                    campo: "cantidad",
                    idPresentacion: l.idPresentacion,
                    disponible: e.disponible,
                    mensaje:
                        e.disponible > 0
                            ? `${e.etiqueta}: solo hay ${e.disponible} disponibles`
                            : `${e.etiqueta}: agotado`,
                };
            })
        );
    }

    // Bandas elegidas (productos por pieza): la pieza debe ser de la variante de
    // la presentacion y tener LIBRE lo que suman sus lineas (en unidad base).
    // La base vuelve a reservarla al crear el pedido (fn_crear_pedido).
    const conPieza = lineas.filter((l) => (l.pieza ?? 0) > 0);
    if (conPieza.length > 0) {
        const { piezas, presentaciones } = await estadoPiezas(
            [...new Set(conPieza.map((l) => l.pieza))],
            [...new Set(conPieza.map((l) => l.idPresentacion))]
        );
        const porPieza = new Map();
        const errores = [];
        for (const l of conPieza) {
            const p = piezas.get(l.pieza);
            const pres = presentaciones.get(l.idPresentacion);
            if (!p || !pres || p.idVariante !== pres.idVariante) {
                errores.push({ campo: "pieza", mensaje: `La banda ${l.pieza} ya no esta disponible para esa presentacion` });
                continue;
            }
            porPieza.set(l.pieza, (porPieza.get(l.pieza) ?? 0) + l.cantidad * pres.factor);
        }
        for (const [id, base] of porPieza) {
            const p = piezas.get(id);
            if (base > p.libre + 1e-9) {
                errores.push({ campo: "cantidad", mensaje: `La banda ${p.codigo ?? id} tiene ${p.libre} libres y se piden ${base}` });
            }
        }
        if (errores.length > 0) throw new AppError("La banda elegida no alcanza", 409, errores);
    }
}

export async function crear(_req, res, next) {
    try {
        const carrito = await crearCarrito();
        res.status(201).location(`/api/v1/carritos/${carrito.token}`).json(RespuestaFactory.exito(carrito));
    } catch (err) {
        next(err);
    }
}

export async function obtener(req, res, next) {
    try {
        const carrito = await buscarCarrito(req.params.token);
        if (!carrito) throw noExisteCarrito(req.params.token);
        res.status(200).json(RespuestaFactory.exito(carrito));
    } catch (err) {
        next(err);
    }
}

export async function agregar(req, res, next) {
    try {
        const { idPresentacion, cantidad } = req.body;
        const pieza = req.body.pieza ?? 0;
        // Se suma a lo que ya hay en el carrito: se valida la cantidad resultante.
        // Las demas lineas de la misma presentacion (otras bandas) tambien
        // cuentan para el disponible de la presentacion.
        const actual = await buscarCarrito(req.params.token);
        if (!actual) throw noExisteCarrito(req.params.token);
        const nueva = { idPresentacion, pieza };
        const enCarrito = actual.items.find((i) => mismaLinea(i, nueva))?.cantidad ?? 0;
        await exigirVendibles([{ idPresentacion, pieza, cantidad: enCarrito + cantidad }]);
        const carrito = await agregarItem(req.params.token, idPresentacion, cantidad, pieza);
        if (!carrito) throw noExisteCarrito(req.params.token);
        res.status(201).json(RespuestaFactory.exito(carrito));
    } catch (err) {
        next(err);
    }
}

// POST /:token/combos {codigo, color, cantidad}: el combo es uno solo y el
// color se elige al agregarlo (entre los que existen en todos sus
// componentes). Entra como sus lineas reales (receta x cantidad de combos);
// se valida la cantidad RESULTANTE de cada linea y se suman en una transaccion.
export async function agregarCombo(req, res, next) {
    try {
        const { codigo, color } = req.body;
        const veces = req.body.cantidad ?? 1;
        const combo = await buscarCombo(codigo);
        if (!combo) throw new AppError(`No existe un combo publicado con codigo ${codigo}`, 404);
        // Con un solo color posible, el color es opcional
        const opcion = color
            ? combo.colores.find((c) => c.color.toLowerCase() === color.toLowerCase())
            : combo.colores.length === 1
              ? combo.colores[0]
              : null;
        if (!opcion) {
            throw new AppError("Color no disponible para este combo", 422, [
                {
                    campo: "color",
                    mensaje: `Elija uno de: ${combo.colores.map((c) => c.color).join(", ")}`,
                },
            ]);
        }
        const actual = await buscarCarrito(req.params.token);
        if (!actual) throw noExisteCarrito(req.params.token);

        const lineas = opcion.lineas.map((l) => ({ idPresentacion: l.idPresentacion, cantidad: l.cantidad * veces }));
        await exigirVendibles(
            lineas.map((l) => ({
                idPresentacion: l.idPresentacion,
                cantidad:
                    l.cantidad + (actual.items.find((i) => i.idPresentacion === l.idPresentacion)?.cantidad ?? 0),
            }))
        );
        const carrito = await agregarItems(req.params.token, lineas);
        if (!carrito) throw noExisteCarrito(req.params.token);
        res.status(201).json(RespuestaFactory.exito(carrito));
    } catch (err) {
        next(err);
    }
}

// PUT: reemplazo completo de las lineas (lo que no viene, se quita)
export async function reemplazar(req, res, next) {
    try {
        const items = req.body.items.map(({ idPresentacion, cantidad, pieza }) => ({ idPresentacion, cantidad, pieza: pieza ?? 0 }));
        await exigirVendibles(items);
        const carrito = await reemplazarItems(req.params.token, items);
        if (!carrito) throw noExisteCarrito(req.params.token);
        res.status(200).json(RespuestaFactory.exito(carrito));
    } catch (err) {
        next(err);
    }
}

// PATCH: actualizacion parcial, solo la cantidad de una linea
export async function cambiarCantidad(req, res, next) {
    try {
        const { token, idPresentacion } = req.params;
        const pieza = req.query.pieza ?? 0;
        await exigirVendibles([{ idPresentacion, pieza, cantidad: req.body.cantidad }]);
        const { carrito, motivo } = await actualizarCantidad(token, idPresentacion, req.body.cantidad, pieza);
        if (motivo === "CARRITO") throw noExisteCarrito(token);
        if (motivo === "ITEM") throw noExisteItem(idPresentacion);
        res.status(200).json(RespuestaFactory.exito(carrito));
    } catch (err) {
        next(err);
    }
}

export async function quitarItem(req, res, next) {
    try {
        const { token, idPresentacion } = req.params;
        const resultado = await eliminarItem(token, idPresentacion, req.query.pieza ?? 0);
        if (resultado === "CARRITO") throw noExisteCarrito(token);
        if (resultado === "ITEM") throw noExisteItem(idPresentacion);
        res.status(204).send();
    } catch (err) {
        next(err);
    }
}

export async function eliminar(req, res, next) {
    try {
        const resultado = await eliminarCarrito(req.params.token);
        if (resultado === "NO_EXISTE") throw noExisteCarrito(req.params.token);
        if (resultado === "CONVERTIDO") {
            throw new AppError("El carrito ya se convirtio en un pedido y no se elimina", 409);
        }
        res.status(204).send();
    } catch (err) {
        next(err);
    }
}
