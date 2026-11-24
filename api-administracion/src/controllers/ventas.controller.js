// src/controllers/ventas.controller.js
import { matchedData } from "express-validator";
import { RespuestaFactory } from "../factories/respuesta.factory.js";
import * as repo from "../repositories/venta.repository.js";
import * as clientes from "../repositories/cliente.repository.js";
import { AppError } from "../utils/AppError.js";

const accion = (fn) => async (req, res, next) => {
    try {
        await fn(req, res);
    } catch (err) {
        next(err);
    }
};
const datos = (req) => matchedData(req, { locations: ["body"] });
const noExiste = (id) => new AppError(`No existe el pedido ${id}`, 404);

export const listar = accion(async (req, res) => {
    const { estado = null, canal = null, q = null } = matchedData(req, { locations: ["query"] });
    const { filas, total } = await repo.listarPedidos({ estado, canal, q, ...req.paginacion });
    res.status(200).json(RespuestaFactory.exito(filas, RespuestaFactory.paginacion(req.paginacion, total)));
});

export const obtener = accion(async (req, res) => {
    const p = await repo.detallePedido(req.params.id);
    if (!p) throw noExiste(req.params.id);
    res.status(200).json(RespuestaFactory.exito(p));
});

export const crear = accion(async (req, res) => {
    if (!req.usuario.esEmpleado) {
        throw new AppError("Para registrar ventas tu usuario necesita su ficha de empleado (Talento humano)", 409);
    }
    const id = await repo.crearPedido(datos(req), req.usuario.idUsuario);
    res.status(201).location(`/api/v1/ventas/pedidos/${id}`).json(RespuestaFactory.exito(await repo.detallePedido(id)));
});

export const pagar = accion(async (req, res) => {
    await repo.registrarPago(req.params.id, datos(req), req.usuario.idUsuario);
    res.status(201).json(RespuestaFactory.exito(await repo.detallePedido(req.params.id)));
});

export const facturar = accion(async (req, res) => {
    const idComprobante = await repo.facturar(req.params.id, datos(req), req.usuario.idUsuario);
    res.status(201).json(RespuestaFactory.exito({ idComprobante, pedido: await repo.detallePedido(req.params.id) }));
});

export const cambiarEstado = accion(async (req, res) => {
    await repo.cambiarEstado(req.params.id, datos(req), req.usuario.idUsuario);
    const p = await repo.detallePedido(req.params.id);
    if (!p) throw noExiste(req.params.id);
    res.status(200).json(RespuestaFactory.exito(p));
});

export const presentaciones = accion(async (req, res) => {
    const { q = null } = matchedData(req, { locations: ["query"] });
    res.status(200).json(RespuestaFactory.exito(await repo.presentacionesVendibles(q)));
});

export const productos = accion(async (req, res) => {
    const { q = null } = matchedData(req, { locations: ["query"] });
    res.status(200).json(RespuestaFactory.exito(await repo.productosVendibles(q)));
});

export const producto = accion(async (req, res) => {
    const p = await repo.productoVendible(Number(req.params.id));
    if (!p) throw new AppError(`El producto ${req.params.id} no está a la venta (sin publicar, sin precio o inactivo)`, 404);
    res.status(200).json(RespuestaFactory.exito(p));
});

export const cuentasPorCobrar = accion(async (_req, res) => {
    res.status(200).json(RespuestaFactory.exito(await repo.cuentasPorCobrar()));
});

export const abonar = accion(async (req, res) => {
    const id = await repo.abonar(datos(req), req.usuario.idUsuario);
    res.status(201).json(RespuestaFactory.exito({ idAbono: id }));
});

// ------------------------------------------------------------------ Clientes de la venta
export const buscarClientes = accion(async (req, res) => {
    const { q = "" } = matchedData(req, { locations: ["query"] });
    res.status(200).json(RespuestaFactory.exito(await clientes.buscar(q)));
});

export const fichaCliente = accion(async (req, res) => {
    const c = await clientes.ficha(Number(req.params.id));
    if (!c) throw new AppError(`No existe el cliente ${req.params.id}`, 404);
    res.status(200).json(RespuestaFactory.exito(c));
});

export const crearCliente = accion(async (req, res) => {
    res.status(201).json(RespuestaFactory.exito(await clientes.crear(datos(req), req.usuario.idUsuario)));
});

export const agregarFacturacion = accion(async (req, res) => {
    const r = await clientes.agregarFacturacion(Number(req.params.id), datos(req), req.usuario.idUsuario);
    if (!r) throw new AppError(`No existe el cliente ${req.params.id}`, 404);
    res.status(201).json(RespuestaFactory.exito(r));
});

export const agregarDireccion = accion(async (req, res) => {
    const r = await clientes.agregarDireccion(Number(req.params.id), datos(req), req.usuario.idUsuario);
    if (!r) throw new AppError(`No existe el cliente ${req.params.id}`, 404);
    res.status(201).json(RespuestaFactory.exito(r));
});

export const registrarAvance = accion(async (req, res) => {
    await repo.registrarAvance(Number(req.params.id), datos(req), req.usuario.idUsuario);
    res.status(201).json(RespuestaFactory.exito(await repo.detallePedido(req.params.id)));
});

export const deudasCliente = accion(async (req, res) => {
    res.status(200).json(RespuestaFactory.exito(await clientes.deudas(Number(req.params.id))));
});
