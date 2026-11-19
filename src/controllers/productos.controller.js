// src/controllers/productos.controller.js
// Orquesta request -> modelo -> response. Nunca arma SQL aqui (eso vive en
// el modelo) y nunca responde el error directamente: siempre next(err)
// para que lo resuelva el errorHandler central.
import {
    actualizarProducto,
    buscarProductoPorId,
    contarProductos,
    crearProducto,
    eliminarProducto,
    listarProductos,
} from "../models/producto.model.js";
import { AppError } from "../utils/AppError.js";

const TAMANO_PAGINA = 100;

export async function listar(req, res, next) {
    try {
        const page = Number(req.query.page) || 1;
        const offset = (page - 1) * TAMANO_PAGINA;
        const q = req.query.q || undefined;

        const [productos, total] = await Promise.all([
            listarProductos({ limit: TAMANO_PAGINA, offset, q }),
            contarProductos({ q }),
        ]);

        res.status(200).json({
            status: "success",
            data: productos,
            meta: {
                page,
                limit: TAMANO_PAGINA,
                totalItems: total,
                totalPages: Math.max(1, Math.ceil(total / TAMANO_PAGINA)),
                ...(q ? { q } : {}),
            },
        });
    } catch (err) {
        next(err);
    }
}

export async function obtenerPorId(req, res, next) {
    try {
        const producto = await buscarProductoPorId(req.params.id);
        if (!producto) {
            throw new AppError(`No existe un producto con id ${req.params.id}`, 404);
        }
        res.status(200).json({ status: "success", data: producto });
    } catch (err) {
        next(err);
    }
}

export async function crear(req, res, next) {
    try {
        const producto = await crearProducto(req.body);
        res.status(201).json({ status: "success", data: producto });
    } catch (err) {
        next(err);
    }
}

export async function actualizar(req, res, next) {
    try {
        const producto = await actualizarProducto(req.params.id, req.body);
        if (!producto) {
            throw new AppError(`No existe un producto con id ${req.params.id}`, 404);
        }
        res.status(200).json({ status: "success", data: producto });
    } catch (err) {
        next(err);
    }
}

export async function eliminar(req, res, next) {
    try {
        const eliminado = await eliminarProducto(req.params.id);
        if (!eliminado) {
            throw new AppError(`No existe un producto con id ${req.params.id}`, 404);
        }
        res.status(204).send();
    } catch (err) {
        next(err);
    }
}
