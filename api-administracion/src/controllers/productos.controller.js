// src/controllers/productos.controller.js
import { matchedData } from "express-validator";
import { RespuestaFactory } from "../factories/respuesta.factory.js";
import * as repo from "../repositories/producto.repository.js";
import { AppError } from "../utils/AppError.js";

const noExiste = (id) => new AppError(`No existe el producto ${id}`, 404);
const datos = (req) => matchedData(req, { locations: ["body"] });

/** Envuelve una accion: next(err) centralizado (los controladores no responden errores inline). */
const accion = (fn) => async (req, res, next) => {
    try {
        await fn(req, res);
    } catch (err) {
        next(err);
    }
};

export const listar = accion(async (req, res) => {
    const { q = null, idCategoria = null, publicado = null, requiereCompra = false } = matchedData(req, { locations: ["query"] });
    const { filas, total } = await repo.listar({ q, idCategoria, publicado, requiereCompra, ...req.paginacion });
    res.status(200).json(RespuestaFactory.exito(filas, RespuestaFactory.paginacion(req.paginacion, total)));
});

export const obtener = accion(async (req, res) => {
    const p = await repo.detalle(req.params.id);
    if (!p) throw noExiste(req.params.id);
    res.status(200).json(RespuestaFactory.exito(p));
});

export const atributosDeCategoria = accion(async (req, res) => {
    const a = await repo.atributosDeCategoria(Number(req.params.id));
    if (!a) throw new AppError(`No existe la categoría ${req.params.id}`, 404);
    res.status(200).json(RespuestaFactory.exito(a));
});

export const crear = accion(async (req, res) => {
    const d = datos(req);
    // Cada variante debe ser una combinacion distinta de valores
    const firmas = (d.variantes ?? []).map((v) => [...(v.valores ?? [])].sort((a, b) => a - b).join(","));
    if (new Set(firmas).size !== firmas.length) {
        throw new AppError("Hay variantes repetidas (misma combinación de valores)", 422);
    }
    const formas = d.presentaciones.map((p) => p.descripcion.toLowerCase());
    if (new Set(formas).size !== formas.length) throw new AppError("Hay formas de venta repetidas", 422);
    const id = await repo.crear(d, req.usuario.idUsuario);
    res.status(201).location(`/api/v1/catalogo/productos/${id}`).json(RespuestaFactory.exito(await repo.detalle(id)));
});

export const actualizar = accion(async (req, res) => {
    const id = await repo.actualizar(req.params.id, datos(req), req.usuario.idUsuario);
    if (!id) throw noExiste(req.params.id);
    res.status(200).json(RespuestaFactory.exito(await repo.detalle(id)));
});

export const agregarVariante = accion(async (req, res) => {
    const idVariante = await repo.agregarVariante(req.params.id, datos(req), req.usuario.idUsuario);
    if (!idVariante) throw noExiste(req.params.id);
    res.status(201).json(RespuestaFactory.exito(await repo.detalle(req.params.id)));
});

export const actualizarVariante = accion(async (req, res) => {
    const idProducto = await repo.actualizarVariante(req.params.idVariante, datos(req), req.usuario.idUsuario);
    if (!idProducto) throw new AppError(`No existe la variante ${req.params.idVariante}`, 404);
    res.status(200).json(RespuestaFactory.exito(await repo.detalle(idProducto)));
});

export const agregarPresentacion = accion(async (req, res) => {
    const n = await repo.agregarPresentacion(req.params.id, datos(req), req.usuario.idUsuario);
    if (n === null) throw new AppError("El producto no tiene variantes activas", 409);
    res.status(201).json(RespuestaFactory.exito(await repo.detalle(req.params.id)));
});

export const actualizarFormaDeVenta = accion(async (req, res) => {
    const { descripcion, ...cambios } = datos(req);
    const n = await repo.actualizarFormaDeVenta(req.params.id, descripcion, cambios, req.usuario.idUsuario);
    if (n === 0) throw new AppError(`El producto no tiene la forma de venta "${descripcion}"`, 404);
    res.status(200).json(RespuestaFactory.exito(await repo.detalle(req.params.id)));
});

export const registrarPrecio = accion(async (req, res) => {
    const n = await repo.registrarPrecio(req.params.id, datos(req), req.usuario.idUsuario);
    if (n === 0) throw new AppError("No se encontró esa forma de venta en el producto", 404);
    res.status(200).json(RespuestaFactory.exito(await repo.detalle(req.params.id), { preciosRegistrados: n }));
});

export const historialPrecios = accion(async (req, res) => {
    const p = await repo.detalle(req.params.id);
    if (!p) throw noExiste(req.params.id);
    res.status(200).json(RespuestaFactory.exito(await repo.historialPrecios(p.codigo)));
});

export const listarOfertas = accion(async (_req, res) => {
    res.status(200).json(RespuestaFactory.exito(await repo.listarOfertas()));
});

export const crearOferta = accion(async (req, res) => {
    const id = await repo.crearOferta(datos(req), req.usuario.idUsuario);
    res.status(201).json(RespuestaFactory.exito({ idOferta: id }));
});

export const cambiarEstadoOferta = accion(async (req, res) => {
    await repo.cambiarEstadoOferta(req.params.idOferta, datos(req), req.usuario.idUsuario);
    res.status(204).send();
});

export const listarCombos = accion(async (_req, res) => {
    res.status(200).json(RespuestaFactory.exito(await repo.listarCombos()));
});

export const guardarCombo = accion(async (req, res) => {
    const id = await repo.guardarCombo(req.params.idCombo ?? null, datos(req), req.usuario.idUsuario);
    if (!id) throw new AppError(`No existe el combo ${req.params.idCombo}`, 404);
    const combo = (await repo.listarCombos()).find((c) => c.idCombo === id);
    res.status(req.params.idCombo ? 200 : 201).json(RespuestaFactory.exito(combo));
});

export const eliminarCombo = accion(async (req, res) => {
    if (!(await repo.eliminarCombo(req.params.idCombo, req.usuario.idUsuario))) {
        throw new AppError(`No existe el combo ${req.params.idCombo}`, 404);
    }
    res.status(204).send();
});
