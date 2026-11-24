// src/controllers/categorias.controller.js
import { RespuestaFactory } from "../factories/respuesta.factory.js";
import { listarPrincipales } from "../models/categoria.model.js";

export async function listar(_req, res, next) {
    try {
        const lineas = await listarPrincipales();
        res.status(200).json(RespuestaFactory.exito(lineas, { totalItems: lineas.length }));
    } catch (err) {
        next(err);
    }
}
