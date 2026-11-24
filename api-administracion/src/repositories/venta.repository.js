// src/repositories/venta.repository.js
// Ventas: pedidos de todos los canales (tienda, WhatsApp, e-commerce). Todo lo
// que mueve dinero o stock va por las funciones de la base: fn_crear_pedido
// (precio y oferta vigentes, descuento por volumen, reserva de stock y de
// piezas), fn_registrar_pago, fn_facturar_pedido / fn_facturar_a_credito /
// fn_emitir_nota_venta y fn_cambiar_estado_pedido.
import { conUsuario, consulta, llamar, procedimiento, ESQUEMA } from "../config/db.js";
import { m } from "../models/index.js";
import { ordenSql } from "../middlewares/paginacion.js";
import { direccionDelCliente } from "./cliente.repository.js";

const ORDEN_PEDIDOS = {
    id_pedido: "p.id_pedido", fecha: "p.ped_fechahora", canal: "p.id_canal_venta",
    cliente: "TRIM(c.cli_nombres || ' ' || c.cli_apellidos)", estado: "ea.id_estado_pedido",
    total: "NVL(t.total, 0)", pagado: "NVL(pg.pagado, 0)",
};

export async function listarPedidos({ estado = null, canal = null, q = null, limit, offset, orden, dir }) {
    const filtros = [];
    const binds = {};
    if (estado) {
        filtros.push("ea.id_estado_pedido = :estado");
        binds.estado = estado;
    }
    if (canal) {
        filtros.push("p.id_canal_venta = :canal");
        binds.canal = canal;
    }
    if (q) {
        filtros.push("(INSTR(LOWER(c.cli_nombres || ' ' || c.cli_apellidos), :q) > 0 OR TO_CHAR(p.id_pedido) = :q)");
        binds.q = q.toLowerCase();
    }
    const where = filtros.length ? `WHERE ${filtros.join(" AND ")}` : "";
    const desde = `FROM ${ESQUEMA}.pedido p
         JOIN ${ESQUEMA}.cliente c ON c.id_cliente = p.id_cliente
         JOIN ${ESQUEMA}.v_pedido_estado_actual ea ON ea.id_pedido = p.id_pedido
         LEFT JOIN ${ESQUEMA}.v_pedido_totales t ON t.id_pedido = p.id_pedido
         LEFT JOIN ${ESQUEMA}.v_pedido_pagos pg ON pg.id_pedido = p.id_pedido
         ${where}`;
    const [{ total }] = await consulta(`SELECT COUNT(*) AS total ${desde}`, binds);
    const filas = await consulta(
        `SELECT p.id_pedido, p.ped_fechahora AS fecha, p.id_canal_venta AS canal,
                TRIM(c.cli_nombres || ' ' || c.cli_apellidos) AS cliente, ea.id_estado_pedido AS estado,
                ea.estado AS estado_nombre, NVL(t.total, 0) AS total, NVL(pg.pagado, 0) AS pagado,
                NVL(pg.cubierto, 0) AS cubierto
         ${desde}
         ORDER BY ${ordenSql({ orden, dir }, ORDEN_PEDIDOS, "p.id_pedido DESC", "p.id_pedido DESC")}
         OFFSET :offset ROWS FETCH NEXT :limit ROWS ONLY`,
        { ...binds, offset, limit }
    );
    return { filas: filas.map((f) => ({ ...f, id: f.id_pedido })), total };
}

export async function detallePedido(idPedido) {
    const [cab] = await consulta(
        `SELECT p.id_pedido, p.ped_fechahora AS fecha, p.id_canal_venta AS canal, p.ped_observacion AS observacion,
                p.id_cliente, TRIM(c.cli_nombres || ' ' || c.cli_apellidos) AS cliente, c.cli_correo AS correo,
                ea.id_estado_pedido AS estado, ea.estado AS estado_nombre,
                t.subtotal_0, t.subtotal_gravado, t.descuento, t.costo_envio, t.iva, t.total,
                NVL(pg.pagado, 0) AS pagado, NVL(pg.credito, 0) AS credito, NVL(pg.cubierto, 0) AS cubierto,
                e.epl_nombres || ' ' || e.epl_apellidos AS vendedor
         FROM ${ESQUEMA}.pedido p
         JOIN ${ESQUEMA}.cliente c ON c.id_cliente = p.id_cliente
         JOIN ${ESQUEMA}.v_pedido_estado_actual ea ON ea.id_pedido = p.id_pedido
         LEFT JOIN ${ESQUEMA}.v_pedido_totales t ON t.id_pedido = p.id_pedido
         LEFT JOIN ${ESQUEMA}.v_pedido_pagos pg ON pg.id_pedido = p.id_pedido
         LEFT JOIN ${ESQUEMA}.empleado e ON e.id_usuario = p.id_empleado_vendedor
         WHERE p.id_pedido = :pedido`,
        { pedido: idPedido }
    );
    if (!cab) return null;
    const lineas = await consulta(
        `SELECT dv.id_detalle_pedido, v.var_sku, pr.prd_nombre, pre.pre_descripcion AS presentacion, dv.dpe_cantidad AS cantidad,
                dv.dpe_precio_unitario AS precio,
                ROUND(dv.dpe_precio_unitario * (1 + dv.tiv_porcentaje / 100), 2) AS precio_con_iva,
                dv.base_imponible + dv.iva AS total_con_iva, dv.pct_oferta, dv.pct_volumen, dv.descuento_total, dv.base_imponible, dv.iva,
                l.lot_codigo_proveedor AS pieza
         FROM ${ESQUEMA}.v_detalle_pedido_valor dv
         JOIN ${ESQUEMA}.presentacion pre ON pre.id_presentacion = dv.id_presentacion
         JOIN ${ESQUEMA}.variante v ON v.id_variante = dv.id_variante
         JOIN ${ESQUEMA}.producto pr ON pr.id_producto = v.id_producto
         JOIN ${ESQUEMA}.detalle_pedido d ON d.id_detalle_pedido = dv.id_detalle_pedido
         LEFT JOIN ${ESQUEMA}.lote l ON l.id_lote = d.id_lote_reservado
         WHERE dv.id_pedido = :pedido
         ORDER BY dv.id_detalle_pedido`,
        { pedido: idPedido }
    );
    const pagos = await consulta(
        `SELECT pa.id_pago, pa.pag_fechahora AS fecha, mp.mpa_nombre AS metodo, pa.pag_monto AS monto,
                pa.pag_referencia AS referencia, pa.pag_estado AS estado
         FROM ${ESQUEMA}.pago pa JOIN ${ESQUEMA}.metodo_pago mp ON mp.id_metodo_pago = pa.id_metodo_pago
         WHERE pa.id_pedido = :pedido ORDER BY pa.pag_fechahora`,
        { pedido: idPedido }
    );
    const historial = await consulta(
        `SELECT h.hep_fechahora AS fecha, e.esp_nombre AS estado, h.hep_observacion AS observacion
         FROM ${ESQUEMA}.historial_estado_pedido h JOIN ${ESQUEMA}.estado_pedido e ON e.id_estado_pedido = h.id_estado_pedido
         WHERE h.id_pedido = :pedido ORDER BY h.hep_fechahora`,
        { pedido: idPedido }
    );
    const comprobantes = await consulta(
        `SELECT id_comprobante_venta, tipo_comprobante, numero, fecha, estado_sri, razon_social, total
         FROM ${ESQUEMA}.v_comprobante_venta WHERE id_pedido = :pedido`,
        { pedido: idPedido }
    );
    const facturacion = await m.DatosFacturacion.findAll({ where: { idCliente: cab.id_cliente, activo: 1 } });
    const cuentas = await consulta(
        `SELECT id_cuenta_por_cobrar, tipo, motivo, concepto, fecha, vencimiento, monto, abonado, saldo, estado, dias_vencida
         FROM ${ESQUEMA}.v_cuentas_por_cobrar WHERE id_pedido = :pedido ORDER BY fecha`,
        { pedido: idPedido }
    );
    const [envio] = await consulta(
        `SELECT e.env_costo AS costo, e.env_guia AS guia, d.dir_calle_principal || NVL2(d.dir_numero, ' ' || d.dir_numero, '')
                || NVL2(d.dir_calle_secundaria, ' y ' || d.dir_calle_secundaria, '') || ', ' || ci.ciu_nombre AS direccion
         FROM ${ESQUEMA}.envio e JOIN ${ESQUEMA}.direccion d ON d.id_direccion = e.id_direccion
         JOIN ${ESQUEMA}.ciudad ci ON ci.id_ciudad = d.id_ciudad WHERE e.id_pedido = :pedido`,
        { pedido: idPedido }
    );
    return {
        ...cab,
        id: cab.id_pedido,
        lineas,
        pagos,
        historial,
        comprobantes,
        cuentas,
        envio: envio ?? null,
        datosFacturacion: facturacion.map((d) => ({ id: d.idDatosFacturacion, idTipoIdentificacion: d.idTipoIdentificacion, etiqueta: d.idTipoIdentificacion === "07" ? "Consumidor final" : `${d.razonSocial} (${d.identificacion})` })),
    };
}

/**
 * Venta en tienda o por WhatsApp; el vendedor es el usuario de la sesion (debe
 * ser empleado). Con `envio` ({ idDireccion, costo?, idTransportista? }) es un
 * PEDIDO a domicilio: la direccion es obligatoria y queda en la tabla envio en
 * la misma transaccion. Sin envio, el cliente retira en el local.
 */
export function crearPedido({ idCliente, canal, lineas, observacion, envio: envioPedido }, idUsuario) {
    // matchedData puede traer { envio: {} }: hay envio solo si trae su direccion
    const envio = envioPedido?.idDireccion ? envioPedido : null;
    return conUsuario(idUsuario, async (t) => {
        if (envio) await direccionDelCliente(t, idCliente, envio.idDireccion);
        const idPedido = await llamar(t, "fn_crear_pedido", {
            p_cliente: idCliente,
            p_canal: canal,
            p_lineas: JSON.stringify(
                lineas.map((l) => ({
                    id_presentacion: l.idPresentacion,
                    cantidad: l.cantidad,
                    ...(l.idLote ? { id_lote: l.idLote } : {}),
                    ...(l.valorFinal != null ? { valor_final: l.valorFinal } : {}),
                }))
            ),
            p_vendedor: idUsuario,
            p_observacion: observacion ?? null,
        });
        if (envio) {
            await m.Envio.create(
                { idPedido, idDireccion: envio.idDireccion, idTransportista: envio.idTransportista ?? null, costo: envio.costo ?? 0, idTarifaIva: "4" },
                { transaction: t }
            );
        }
        return idPedido;
    });
}

/**
 * AVANCE de dinero: el cliente pide efectivo (pasaje, comprar en otro local)
 * dentro de su pedido. No es una venta ni toca el inventario: la base lo
 * registra como CUENTA POR COBRAR tipo AVANCE (fn_registrar_avance, permiso
 * CREDITO_OTORGAR) y el cliente lo devuelve con abonos.
 */
export function registrarAvance(idPedido, { monto, concepto, idMetodoPago, idMotivoAvance, plazoDias }, idUsuario) {
    return conUsuario(idUsuario, (t) =>
        llamar(t, "fn_registrar_avance", {
            p_pedido: idPedido,
            p_monto: monto,
            p_concepto: concepto,
            p_metodo_entrega: idMetodoPago,
            p_plazo_dias: plazoDias,
            p_usuario: idUsuario,
            p_motivo: idMotivoAvance ?? null,
        })
    );
}

export function registrarPago(idPedido, { idMetodoPago, monto, referencia }, idUsuario) {
    return conUsuario(idUsuario, (t) =>
        llamar(t, "fn_registrar_pago", {
            p_pedido: idPedido,
            p_metodo: idMetodoPago,
            p_monto: monto,
            p_usuario: idUsuario,
            p_referencia: referencia ?? null,
        })
    );
}

/** Factura (01), nota de venta (02) o factura a credito: la base valida pagos y stock y descuenta lotes. */
export function facturar(idPedido, { idDatosFacturacion, idPuntoEmision, tipo, plazoDias }, idUsuario) {
    return conUsuario(idUsuario, (t) => {
        if (plazoDias) {
            return llamar(t, "fn_facturar_a_credito", {
                p_pedido: idPedido,
                p_plazo_dias: plazoDias,
                p_datos_facturacion: idDatosFacturacion,
                p_punto_emision: idPuntoEmision,
                p_usuario: idUsuario,
                p_tipo_comprobante: tipo,
            });
        }
        if (tipo === "02") {
            return llamar(t, "fn_emitir_nota_venta", {
                p_pedido: idPedido,
                p_punto_emision: idPuntoEmision,
                p_usuario: idUsuario,
                p_datos_facturacion: idDatosFacturacion ?? null,
            });
        }
        return llamar(t, "fn_facturar_pedido", {
            p_pedido: idPedido,
            p_datos_facturacion: idDatosFacturacion,
            p_punto_emision: idPuntoEmision,
            p_usuario: idUsuario,
            p_tipo_comprobante: "01",
        });
    });
}

export function cambiarEstado(idPedido, { estado, observacion }, idUsuario) {
    return conUsuario(idUsuario, (t) =>
        procedimiento(t, "fn_cambiar_estado_pedido", {
            p_pedido: idPedido,
            p_estado: estado,
            p_usuario: idUsuario,
            p_observacion: observacion ?? null,
        })
    );
}

/** Presentaciones vendibles para el formulario de venta (precio final con IVA y disponible). */
export function presentacionesVendibles(q) {
    return consulta(
        `SELECT c.id_presentacion, c.prd_codigo, c.prd_nombre, c.var_sku, c.caracteristicas, c.presentacion,
                c.precio_final_con_iva, c.disponible, c.cantidad_minima, c.incremento, c.venta_por_pieza
         FROM ${ESQUEMA}.v_catalogo c
         WHERE (:q IS NULL OR INSTR(LOWER(c.prd_nombre || ' ' || c.var_sku), :q) > 0)
         ORDER BY c.prd_codigo, c.var_sku, c.id_presentacion
         FETCH FIRST 60 ROWS ONLY`,
        { q: q ? q.toLowerCase() : null }
    );
}

/**
 * Venta de mostrador, paso 1: los PRODUCTOS que coinciden (uno por fila, no
 * una fila por talla x color x forma de venta), con lo que ayuda a elegir:
 * precio desde, cuantas variantes y formas de venta tiene y si hay stock.
 */
export function productosVendibles(q) {
    return consulta(
        `SELECT c.id_producto, c.prd_codigo, c.prd_nombre, c.categoria, MAX(c.imagen_url) AS imagen_url, MAX(c.unidad) AS unidad,
                MIN(c.precio_final_con_iva) AS precio_desde, MAX(c.precio_final_con_iva) AS precio_hasta,
                COUNT(DISTINCT c.id_variante) AS variantes, COUNT(DISTINCT c.presentacion) AS formas,
                COUNT(DISTINCT CASE WHEN c.disponible > 0 THEN c.id_variante END) AS variantes_con_stock,
                MAX(c.venta_por_pieza) AS venta_por_pieza
         FROM ${ESQUEMA}.v_catalogo c
         WHERE (:q IS NULL OR INSTR(LOWER(c.prd_nombre || ' ' || c.prd_codigo || ' ' || c.var_sku || ' ' || c.categoria), :q) > 0)
         GROUP BY c.id_producto, c.prd_codigo, c.prd_nombre, c.categoria
         ORDER BY c.prd_nombre
         FETCH FIRST 30 ROWS ONLY`,
        { q: q ? q.toLowerCase() : null }
    );
}

/** "Color: Negro, Talla: 35" -> { Color: "Negro", Talla: "35" } */
const caracteristicasDe = (texto) =>
    Object.fromEntries(
        String(texto ?? "")
            .split(/,\s*(?=[^,:]+:)/)
            .map((par) => par.split(/:\s*/))
            .filter((x) => x.length === 2)
    );

/**
 * Paso 2: el detalle para especificar la venta. Variantes con sus atributos
 * (para elegir Color, Talla...), sus formas de venta con precio y disponible,
 * y en productos por pieza las piezas libres (banda o plancha) con su medida.
 */
export async function productoVendible(idProducto) {
    const filas = await consulta(
        `SELECT c.id_producto, c.prd_codigo, c.prd_nombre, c.categoria, c.imagen_url, c.unidad, c.unidad_codigo,
                c.venta_por_pieza, c.cortes_estandar, c.id_variante, c.var_sku, c.caracteristicas,
                c.id_presentacion, c.presentacion, c.factor, c.precio_final_con_iva, c.precio_con_iva, c.pct_oferta,
                c.disponible, c.cantidad_minima, c.incremento
         FROM ${ESQUEMA}.v_catalogo c
         WHERE c.id_producto = :id
         ORDER BY c.var_sku, c.factor DESC, c.id_presentacion`,
        { id: idProducto }
    );
    if (filas.length === 0) return null;
    const f0 = filas[0];
    const variantes = new Map();
    for (const f of filas) {
        if (!variantes.has(f.id_variante)) {
            variantes.set(f.id_variante, { idVariante: f.id_variante, sku: f.var_sku, caracteristicas: caracteristicasDe(f.caracteristicas), formas: [], piezas: [] });
        }
        variantes.get(f.id_variante).formas.push({
            idPresentacion: f.id_presentacion,
            descripcion: f.presentacion,
            factor: f.factor,
            precio: f.precio_final_con_iva, // con IVA y con la oferta vigente
            precioSinOferta: f.pct_oferta ? f.precio_con_iva : null,
            pctOferta: f.pct_oferta ?? null,
            disponible: f.disponible,
            cantidadMinima: f.cantidad_minima,
            incremento: f.incremento,
        });
    }
    // bandas: se puede elegir la pieza (si no, la base toma la mas pequena que alcanza)
    if (f0.venta_por_pieza === 1 && f0.cortes_estandar !== 1) {
        const piezas = await consulta(
            `SELECT pl.id_variante, pl.id_lote, pl.lot_codigo_proveedor AS codigo, pl.libre
             FROM ${ESQUEMA}.v_pieza_libre pl
             JOIN ${ESQUEMA}.variante v ON v.id_variante = pl.id_variante
             WHERE v.id_producto = :id AND pl.libre > 0
             ORDER BY pl.libre, pl.id_lote`,
            { id: idProducto }
        );
        for (const x of piezas) variantes.get(x.id_variante)?.piezas.push({ idLote: x.id_lote, codigo: x.codigo, libre: x.libre });
    }
    const lista = [...variantes.values()];
    // atributos en el orden en que aparecen, con sus valores ordenados (tallas numericas)
    const atributos = [...new Set(lista.flatMap((v) => Object.keys(v.caracteristicas)))].map((nombre) => ({
        nombre,
        valores: [...new Set(lista.map((v) => v.caracteristicas[nombre]).filter(Boolean))].sort((a, b) => a.localeCompare(b, "es", { numeric: true })),
    }));
    return {
        idProducto: f0.id_producto,
        codigo: f0.prd_codigo,
        nombre: f0.prd_nombre,
        categoria: f0.categoria,
        imagenUrl: f0.imagen_url,
        unidad: f0.unidad,
        ventaPorPieza: f0.venta_por_pieza === 1,
        cortesEstandar: f0.cortes_estandar === 1,
        atributos,
        variantes: lista,
    };
}

export function cuentasPorCobrar() {
    return consulta(
        `SELECT id_cuenta_por_cobrar, cliente, id_pedido, comprobante_venta, tipo, concepto, fecha, vencimiento,
                monto, abonado, saldo, estado, dias_vencida
         FROM ${ESQUEMA}.v_cuentas_por_cobrar WHERE saldo > 0 ORDER BY vencimiento FETCH FIRST 200 ROWS ONLY`
    );
}

export function abonar({ idCliente, monto, idMetodoPago, referencia }, idUsuario) {
    return conUsuario(idUsuario, (t) =>
        llamar(t, "fn_abonar_cliente", {
            p_cliente: idCliente,
            p_monto: monto,
            p_metodo: idMetodoPago,
            p_usuario: idUsuario,
            p_referencia: referencia ?? null,
        })
    );
}
