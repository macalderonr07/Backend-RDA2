// src/controllers/productos.controller.js
// Orquesta request -> modelo -> respuesta. Sin SQL (vive en el modelo) y sin
// responder errores inline: siempre next(err) hacia el errorHandler central.
import { matchedData } from "express-validator";
import { listadoDesdeCache, productoDesdeCache } from "../cache/catalogo.cache.js";
import { RespuestaFactory } from "../factories/respuesta.factory.js";
import { buscarProductoPorCodigo, contarProductos, listarProductos } from "../models/producto.model.js";
import { AppError } from "../utils/AppError.js";

export async function listar(req, res, next) {
    try {
        // matchedData: filtros ya validados y normalizados (Express 5 no guarda
        // los sanitizers en req.query)
        const { linea = null, marca = null, q = null } = matchedData(req, { locations: ["query"] });
        const { limit, offset } = req.paginacion;

        // Redis (principal) -> Oracle (respaldo, misma respuesta)
        const cache = await listadoDesdeCache({ linea, marca, q, limit, offset });
        const [productos, total] = cache
            ? [cache.productos, cache.total]
            : await Promise.all([listarProductos({ linea, marca, q, limit, offset }), contarProductos({ linea, marca, q })]);
        res.set("X-Cache", cache?.fuente ?? "ORACLE");

        const filtros = { ...(linea ? { linea } : {}), ...(marca ? { marca } : {}), ...(q ? { q } : {}) };
        res.status(200).json(RespuestaFactory.exito(productos, RespuestaFactory.paginacion(req.paginacion, total, filtros)));
    } catch (err) {
        next(err);
    }
}

export async function obtenerPorCodigo(req, res, next) {
    try {
        const { codigo } = req.params;
        const cache = await productoDesdeCache(codigo);
        const producto = cache?.producto ?? (await buscarProductoPorCodigo(codigo));
        res.set("X-Cache", cache?.fuente ?? "ORACLE");
        if (!producto) throw new AppError(`No existe un producto publicado con codigo ${codigo}`, 404);
        res.status(200).json(RespuestaFactory.exito(producto));
    } catch (err) {
        next(err);
    }
}
