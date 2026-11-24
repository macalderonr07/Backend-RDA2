// src/controllers/pedidos.controller.js
// Checkout del e-commerce, como lo preve la base: identificar al cliente del
// carrito (cuenta o datos de invitado) y confirmarlo como pedido WEB. El pedido
// se consulta con el token del carrito que lo origino: quien tiene el token
// puede seguir su pedido, nadie mas.
import { RespuestaFactory } from "../factories/respuesta.factory.js";
import { buscarCarrito } from "../models/carrito.model.js";
import { buscarPedidoDeCarrito, confirmarCarrito, identificarCliente } from "../models/pedido.model.js";
import { AppError } from "../utils/AppError.js";

const noExisteCarrito = (token) => new AppError(`No existe el carrito ${token}`, 404);

// POST /carritos/:token/cliente — datos de invitado del checkout
export async function identificar(req, res, next) {
    try {
        const { nombres, apellidos, correo, telefono } = req.body;
        const resultado = await identificarCliente(req.params.token, { nombres, apellidos, correo, telefono });
        if (resultado === "NO_EXISTE") throw noExisteCarrito(req.params.token);
        if (resultado === "CONVERTIDO") {
            throw new AppError("El carrito ya se convirtio en un pedido y su cliente no se cambia", 409);
        }
        res.status(200).json(RespuestaFactory.exito(await buscarCarrito(req.params.token)));
    } catch (err) {
        next(err);
    }
}

// POST /carritos/:token/pedido — confirma el carrito como pedido WEB (PEN)
export async function confirmar(req, res, next) {
    try {
        const pedido = await confirmarCarrito(req.params.token, {
            observacion: req.body.observacion ?? null,
            sesion: req.correlationId ?? null,
            ip: req.ip ?? null,
        });
        if (!pedido) throw noExisteCarrito(req.params.token);
        res.status(201)
            .location(`/api/v1/carritos/${req.params.token}/pedido`)
            .json(RespuestaFactory.exito(pedido));
    } catch (err) {
        next(err);
    }
}

// GET /carritos/:token/pedido — estado y total actuales del pedido del carrito
export async function obtenerPedido(req, res, next) {
    try {
        const pedido = await buscarPedidoDeCarrito(req.params.token);
        if (!pedido) {
            const carrito = await buscarCarrito(req.params.token);
            if (!carrito) throw noExisteCarrito(req.params.token);
            throw new AppError("El carrito todavia no se confirma como pedido", 404);
        }
        res.status(200).json(RespuestaFactory.exito(pedido));
    } catch (err) {
        next(err);
    }
}
