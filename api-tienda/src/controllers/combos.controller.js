// src/controllers/combos.controller.js
import { RespuestaFactory } from "../factories/respuesta.factory.js";
import { buscarCombo, listarCombos } from "../models/combo.model.js";
import { AppError } from "../utils/AppError.js";

export async function listar(req, res, next) {
    try {
        const combos = await listarCombos({ producto: req.query.producto ?? null });
        res.status(200).json(RespuestaFactory.exito(combos, { totalItems: combos.length }));
    } catch (err) {
        next(err);
    }
}

export async function obtener(req, res, next) {
    try {
        const combo = await buscarCombo(req.params.codigo);
        if (!combo) throw new AppError(`No existe un combo publicado con codigo ${req.params.codigo}`, 404);
        res.status(200).json(RespuestaFactory.exito(combo));
    } catch (err) {
        next(err);
    }
}
