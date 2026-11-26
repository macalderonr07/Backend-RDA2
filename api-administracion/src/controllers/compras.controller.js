// src/controllers/compras.controller.js
import { matchedData } from "express-validator";
import { RespuestaFactory } from "../factories/respuesta.factory.js";
import * as repo from "../repositories/compra.repository.js";
import { AppError } from "../utils/AppError.js";

const accion = (fn) => async (req, res, next) => {
    try {
        await fn(req, res);
    } catch (err) {
        next(err);
    }
};
const datos = (req) => matchedData(req, { locations: ["body"] });
const noExiste = (id) => new AppError(`No existe la orden de compra ${id}`, 404);

export const listarOrdenes = accion(async (req, res) => {
    const { estado = null } = matchedData(req, { locations: ["query"] });
    const { filas, total } = await repo.listarOrdenes({ estado, ...req.paginacion });
    res.status(200).json(RespuestaFactory.exito(filas, RespuestaFactory.paginacion(req.paginacion, total)));
});

export const obtenerOrden = accion(async (req, res) => {
    const oc = await repo.detalleOrden(req.params.id);
    if (!oc) throw noExiste(req.params.id);
    res.status(200).json(RespuestaFactory.exito(oc));
});

export const crearOrden = accion(async (req, res) => {
    const d = datos(req);
    const variantes = d.lineas.map((l) => l.idVariante);
    if (new Set(variantes).size !== variantes.length) throw new AppError("Hay productos repetidos en la orden: suma las cantidades en una línea", 422);
    const id = await repo.crearOrden(d, req.usuario.idUsuario);
    res.status(201).location(`/api/v1/compras/ordenes/${id}`).json(RespuestaFactory.exito(await repo.detalleOrden(id)));
});

export const cambiarEstado = accion(async (req, res) => {
    await repo.cambiarEstado(req.params.id, datos(req).estado, req.usuario.idUsuario);
    const oc = await repo.detalleOrden(req.params.id);
    if (!oc) throw noExiste(req.params.id);
    res.status(200).json(RespuestaFactory.exito(oc));
});

export const recepcionar = accion(async (req, res) => {
    const idMovimiento = await repo.recepcionar(req.params.id, datos(req), req.usuario.idUsuario);
    res.status(201).json(RespuestaFactory.exito({ idMovimiento, orden: await repo.detalleOrden(req.params.id) }));
});

export const comprobantes = accion(async (req, res) => {
    const { filas, total } = await repo.comprobantes(req.paginacion);
    res.status(200).json(RespuestaFactory.exito(filas, RespuestaFactory.paginacion(req.paginacion, total)));
});

export const registrarComprobante = accion(async (req, res) => {
    const id = await repo.registrarComprobante(datos(req), req.usuario.idUsuario);
    res.status(201).json(RespuestaFactory.exito({ idComprobanteCompra: id }));
});

export const porFacturar = accion(async (_req, res) => {
    res.status(200).json(RespuestaFactory.exito(await repo.recepcionesPorFacturar()));
});

export const productos = async (req, res, next) => {
    try {
        const { q = null, idProveedor = null } = matchedData(req, { locations: ["query"] });
        res.status(200).json(RespuestaFactory.exito(await repo.productosCompra(q, idProveedor ?? null)));
    } catch (err) {
        next(err);
    }
};

export const producto = async (req, res, next) => {
    try {
        const p = await repo.productoCompra(Number(req.params.id));
        if (!p) throw new AppError(`El producto ${req.params.id} no tiene variantes activas`, 404);
        res.status(200).json(RespuestaFactory.exito(p));
    } catch (err) {
        next(err);
    }
};
