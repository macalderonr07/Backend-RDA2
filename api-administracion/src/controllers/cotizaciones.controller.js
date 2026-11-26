// src/controllers/cotizaciones.controller.js
// Cotizaciones de la tienda (ventas por confirmar).
import { matchedData } from "express-validator";
import { RespuestaFactory } from "../factories/respuesta.factory.js";
import * as repo from "../repositories/cotizacion.repository.js";
import { AppError } from "../utils/AppError.js";

const accion = (fn) => async (req, res, next) => {
    try {
        await fn(req, res);
    } catch (err) {
        next(err);
    }
};
const noExiste = (id) => new AppError(`No existe la cotización ${id} (pudo haber vencido)`, 404);

export const listar = accion(async (req, res) => {
    const { estado = "PENDIENTE", q = null } = matchedData(req, { locations: ["query"] });
    const { filas, total } = await repo.listar({ estado, q, ...req.paginacion });
    res.status(200).json(RespuestaFactory.exito(filas, RespuestaFactory.paginacion(req.paginacion, total)));
});

export const obtener = accion(async (req, res) => {
    const c = await repo.detalle(req.params.id);
    if (!c) throw noExiste(req.params.id);
    res.status(200).json(RespuestaFactory.exito(c));
});

export const cambiarCantidad = accion(async (req, res) => {
    const c = await repo.cambiarCantidad(req.params.id, req.params.idLinea, matchedData(req, { locations: ["body"] }).cantidad, req.usuario.idUsuario);
    if (!c) throw noExiste(req.params.id);
    res.status(200).json(RespuestaFactory.exito(c));
});

export const quitarLinea = accion(async (req, res) => {
    const c = await repo.quitarLinea(req.params.id, req.params.idLinea, req.usuario.idUsuario);
    if (!c) throw noExiste(req.params.id);
    res.status(200).json(RespuestaFactory.exito(c));
});

export const agregarLinea = accion(async (req, res) => {
    const c = await repo.agregarLinea(req.params.id, matchedData(req, { locations: ["body"] }), req.usuario.idUsuario);
    if (!c) throw noExiste(req.params.id);
    res.status(201).json(RespuestaFactory.exito(c));
});

export const confirmar = accion(async (req, res) => {
    const idPedido = await repo.confirmar(req.params.id, req.usuario.idUsuario);
    res.status(201).json(RespuestaFactory.exito({ idPedido }));
});

export const descartar = accion(async (req, res) => {
    if (!(await repo.descartar(req.params.id, req.usuario.idUsuario))) throw noExiste(req.params.id);
    res.status(204).end();
});
