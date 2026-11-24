// src/controllers/inventario.controller.js
import { matchedData } from "express-validator";
import { RespuestaFactory } from "../factories/respuesta.factory.js";
import * as repo from "../repositories/inventario.repository.js";

const accion = (fn) => async (req, res, next) => {
    try {
        await fn(req, res);
    } catch (err) {
        next(err);
    }
};
const datos = (req) => matchedData(req, { locations: ["body"] });

export const stock = accion(async (req, res) => {
    const { q = null, requiereCompra = false, idVariante = null, idProducto = null } = matchedData(req, { locations: ["query"] });
    const { filas, total } = await repo.stock({ q, requiereCompra, idVariante, idProducto, ...req.paginacion });
    res.status(200).json(RespuestaFactory.exito(filas, RespuestaFactory.paginacion(req.paginacion, total)));
});

export const lotes = accion(async (req, res) => {
    res.status(200).json(RespuestaFactory.exito(await repo.lotes(req.params.idVariante)));
});

export const kardex = accion(async (req, res) => {
    res.status(200).json(RespuestaFactory.exito(await repo.kardex(req.params.idVariante)));
});

export const tiposMovimiento = accion(async (_req, res) => {
    res.status(200).json(RespuestaFactory.exito(await repo.tiposMovimiento()));
});

export const ajustar = accion(async (req, res) => {
    const idMovimiento = await repo.ajustar(datos(req), req.usuario.idUsuario);
    res.status(201).json(RespuestaFactory.exito({ idMovimiento }));
});

export const fraccionar = accion(async (req, res) => {
    const { piezas, motivo } = datos(req);
    const paquetes = await repo.fraccionar(req.params.idLote, piezas, motivo, req.usuario.idUsuario);
    res.status(201).json(RespuestaFactory.exito({ paquetes }));
});

export const devolver = accion(async (req, res) => {
    const idMovimiento = await repo.devolverAProveedor(req.params.idLote, datos(req), req.usuario.idUsuario);
    res.status(201).json(RespuestaFactory.exito({ idMovimiento }));
});
