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
 * Envia el carrito como COTIZACION (venta por confirmar): no reserva stock; el
 * personal la revisa, la edita y la confirma como pedido en la administracion,
 * o vence a los 14 dias. Devuelve la cotizacion o null si el carrito no existe.
 * Las reglas (vacio, sin cliente, ya enviado) las hace cumplir la base (409).
 */
export async function confirmarCarrito(token, { observacion = null, sesion = null, ip = null } = {}) {
    const idCotizacion = await db.transaccion(async (conexion) => {
        const { rows } = await conexion.execute(`SELECT id_carrito FROM carrito WHERE car_token = :token`, { token });
        if (rows.length === 0) return null;
        const { outBinds } = await conexion.execute(
            `BEGIN
                 :cotizacion := ${ESQUEMA}.fn_crear_cotizacion_desde_carrito(:carrito, :observacion, :sesion, :ip);
             END;`,
            {
                cotizacion: { dir: oracledb.BIND_OUT, type: oracledb.NUMBER },
                carrito: rows[0].ID_CARRITO,
                observacion,
                sesion,
                ip,
            }
        );
        return outBinds.cotizacion;
    });
    return idCotizacion === null ? null : buscarPedidoDeCarrito(token);
}

/**
 * Lo que se envio desde un carrito: su cotizacion (numero, vencimiento) y, si
 * el personal ya la confirmo, el pedido con su estado y total. El token del
 * carrito es la credencial del visitante. null si no se envio nada.
 */
export async function buscarPedidoDeCarrito(token) {
    const { rows } = await db.ejecutar(
        `SELECT co.id_cotizacion, co.numero, co.fecha AS fecha_cot, co.vence, co.estado AS estado_cot,
                p.id_pedido, p.fecha, p.estado, p.estado_nombre, p.total, p.comprobante_venta
         FROM v_cotizacion_web co
         LEFT JOIN v_pedido_web p ON p.id_pedido = co.id_pedido
         WHERE co.car_token = :token`,
        { token }
    );
    if (rows.length === 0) return buscarPedidoAntiguo(token);
    const f = rows[0];
    const confirmada = f.ESTADO_COT === "CONFIRMADA" && f.ID_PEDIDO;
    return {
        idCotizacion: f.ID_COTIZACION,
        numeroCotizacion: f.NUMERO,
        vence: f.VENCE,
        idPedido: confirmada ? f.ID_PEDIDO : null,
        fecha: confirmada ? f.FECHA : f.FECHA_COT,
        estado: confirmada ? f.ESTADO : "COT",
        estadoNombre: confirmada ? f.ESTADO_NOMBRE : "Cotización por confirmar",
        total: confirmada ? f.TOTAL : null,
        comprobanteVenta: confirmada ? f.COMPROBANTE_VENTA : null,
    };
}

/** Carritos confirmados antes de las cotizaciones (crearon el pedido directo). */
async function buscarPedidoAntiguo(token) {
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
