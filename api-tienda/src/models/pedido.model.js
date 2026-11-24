// src/models/pedido.model.js
// Repository del checkout: convierte el carrito en un pedido WEB real llamando
// a la logica que ya vive en la base (seccion D3 de ComercialElite_Oracle_2_logica.sql).
// La API no arma el pedido ni toca precios: la base toma las lineas del carrito,
// aplica el precio y la oferta VIGENTES y valida el stock (fn_crear_pedido).
// Las funciones de la base se califican con el esquema porque CURRENT_SCHEMA
// no cubre la resolucion de nombres dentro de bloques PL/SQL.
import oracledb from "oracledb";
import { config } from "../config/env.js";
import { db } from "../config/db.js";

// Validado en env.js (solo letras, digitos y _): seguro de interpolar
const ESQUEMA = config.oracle.schema;

/**
 * Identifica al cliente del carrito (datos de invitado del checkout).
 * produccion.fn_registrar_cliente crea el cliente o lo reconoce por su correo:
 * quien ya compraba en tienda conserva su historial.
 * Devuelve "IDENTIFICADO" | "NO_EXISTE" | "CONVERTIDO".
 */
export async function identificarCliente(token, { nombres, apellidos, correo, telefono }) {
    return db.transaccion(async (conexion) => {
        const { rows } = await conexion.execute(
            `SELECT id_carrito, id_pedido FROM carrito WHERE car_token = :token FOR UPDATE`,
            { token }
        );
        if (rows.length === 0) return "NO_EXISTE";
        // Un carrito convertido es la traza del pedido: su cliente no se cambia
        if (rows[0].ID_PEDIDO != null) return "CONVERTIDO";
        await conexion.execute(
            `DECLARE
                 v_cliente NUMBER;
             BEGIN
                 v_cliente := produccion.fn_registrar_cliente(:nombres, :apellidos, :correo, :telefono);
                 UPDATE ${ESQUEMA}.carrito SET id_cliente = v_cliente WHERE id_carrito = :id;
             END;`,
            {
                nombres,
                apellidos: apellidos ?? null,
                correo,
                telefono: telefono ?? null,
                id: rows[0].ID_CARRITO,
            }
        );
        return "IDENTIFICADO";
    });
}

/**
 * Confirma el carrito: la base crea el pedido WEB (estado PEN) y deja el
 * carrito cerrado con ese pedido. Devuelve el pedido creado o null si el
 * carrito no existe. Las reglas (carrito vacio, sin cliente, ya convertido,
 * stock insuficiente) las hace cumplir la base con ORA-20001 -> 409.
 */
export async function confirmarCarrito(token, { observacion = null, sesion = null, ip = null } = {}) {
    const idPedido = await db.transaccion(async (conexion) => {
        const { rows } = await conexion.execute(`SELECT id_carrito FROM carrito WHERE car_token = :token`, { token });
        if (rows.length === 0) return null;
        const { outBinds } = await conexion.execute(
            `BEGIN
                 :pedido := ${ESQUEMA}.fn_crear_pedido_desde_carrito(:carrito, :observacion, :sesion, :ip);
             END;`,
            {
                pedido: { dir: oracledb.BIND_OUT, type: oracledb.NUMBER },
                carrito: rows[0].ID_CARRITO,
                observacion,
                sesion,
                ip,
            }
        );
        return outBinds.pedido;
    });
    return idPedido === null ? null : buscarPedidoDeCarrito(token);
}

/**
 * Pedido en que se convirtio un carrito, con su estado y total actuales
 * (v_pedido_web: "mis pedidos" del nodo e-commerce). El token del carrito es
 * la credencial del visitante para seguir su pedido. null si no hay pedido.
 */
export async function buscarPedidoDeCarrito(token) {
    const { rows } = await db.ejecutar(
        `SELECT p.id_pedido, p.fecha, p.estado, p.estado_nombre, p.total, p.comprobante_venta
         FROM v_pedido_web p
         JOIN carrito c ON c.id_pedido = p.id_pedido
         WHERE c.car_token = :token`,
        { token }
    );
    if (rows.length === 0) return null;
    const f = rows[0];
    return {
        idPedido: f.ID_PEDIDO,
        fecha: f.FECHA,
        estado: f.ESTADO,
        estadoNombre: f.ESTADO_NOMBRE,
        total: f.TOTAL,
        comprobanteVenta: f.COMPROBANTE_VENTA,
    };
}
