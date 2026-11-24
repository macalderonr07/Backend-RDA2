// src/repositories/inventario.repository.js
// Inventario: lecturas de las vistas de la base (stock, lotes/piezas, kardex)
// y movimientos SOLO por sus funciones de negocio (fn_registrar_ajuste,
// fn_fraccionar_lote, fn_devolver_a_proveedor): el kardex es inmutable y la
// base valida existencias, permisos y costos.
import oracledb from "oracledb";
import { conUsuario, consulta, llamar, ESQUEMA } from "../config/db.js";
import { ordenSql } from "../middlewares/paginacion.js";

const ORDEN_STOCK = {
    var_sku: "s.var_sku", prd_nombre: "s.prd_nombre", stock_fisico: "s.stock_fisico", reservado: "s.reservado",
    disponible: "s.disponible", en_camino: "s.en_camino", stock_minimo: "s.stock_minimo", requiere_compra: "s.requiere_compra",
};

export async function stock({ q = null, requiereCompra = false, idVariante = null, idProducto = null, limit, offset, orden, dir }) {
    const filtros = [];
    const binds = {};
    if (q) {
        filtros.push("(INSTR(LOWER(s.var_sku), :q) > 0 OR INSTR(LOWER(s.prd_nombre), :q) > 0)");
        binds.q = q.toLowerCase();
    }
    if (requiereCompra) filtros.push("s.requiere_compra = 1");
    if (idVariante) {
        filtros.push("s.id_variante = :variante");
        binds.variante = idVariante;
    }
    if (idProducto) {
        // todas las variantes de un producto (ficha de inventario por producto)
        filtros.push(`s.id_variante IN (SELECT vp.id_variante FROM ${ESQUEMA}.variante vp WHERE vp.id_producto = :producto)`);
        binds.producto = idProducto;
    }
    const where = filtros.length ? `WHERE ${filtros.join(" AND ")}` : "";
    const [{ total }] = await consulta(`SELECT COUNT(*) AS total FROM ${ESQUEMA}.v_stock_variante s ${where}`, binds);
    const filas = await consulta(
        `SELECT s.id_variante, p.id_producto, s.var_sku, s.prd_nombre, s.unidad, s.stock_fisico, s.reservado, s.disponible,
                s.en_camino, s.stock_minimo, s.requiere_compra, ROUND(s.valor_inventario, 2) AS valor_inventario,
                s.antiguedad_maxima_dias, s.ultimo_movimiento,
                p.prd_compra_descripcion AS compra_descripcion, p.prd_compra_factor AS compra_factor, p.prd_venta_por_pieza AS venta_por_pieza,
                (SELECT COUNT(*) FROM ${ESQUEMA}.v_lote_saldo ls WHERE ls.id_variante = s.id_variante AND ls.saldo > 0) AS piezas,
                (SELECT LISTAGG(a.atr_nombre || ': ' || va.val_valor, ', ') WITHIN GROUP (ORDER BY a.atr_nombre)
                 FROM ${ESQUEMA}.variante_valor vv
                 JOIN ${ESQUEMA}.valor_atributo va ON va.id_valor_atributo = vv.id_valor_atributo
                 JOIN ${ESQUEMA}.atributo a ON a.id_atributo = vv.id_atributo
                 WHERE vv.id_variante = s.id_variante) AS caracteristicas
         FROM ${ESQUEMA}.v_stock_variante s
         JOIN ${ESQUEMA}.variante v ON v.id_variante = s.id_variante AND v.var_activa = 1
         JOIN ${ESQUEMA}.producto p ON p.id_producto = v.id_producto
         ${where}
         ORDER BY ${ordenSql({ orden, dir }, ORDEN_STOCK, "s.requiere_compra DESC, s.var_sku", "s.id_variante")}
         OFFSET :offset ROWS FETCH NEXT :limit ROWS ONLY`,
        { ...binds, offset, limit }
    );
    return { filas: filas.map((f) => ({ ...f, id: f.id_variante })), total };
}

/** Lotes (o piezas, en productos por pieza) con saldo, reservado y libre. */
export function lotes(idVariante) {
    return consulta(
        `SELECT ls.id_lote, ls.lot_codigo_proveedor AS codigo, ls.lot_costo_unitario AS costo_unitario,
                ls.lot_fecha_vencimiento AS vencimiento, ls.fecha_ingreso, ls.saldo, ls.id_lote_origen,
                ls.dias_en_inventario, NVL(pl.reservado, 0) AS reservado, NVL(pl.libre, ls.saldo) AS libre
         FROM ${ESQUEMA}.v_lote_saldo ls
         LEFT JOIN ${ESQUEMA}.v_pieza_libre pl ON pl.id_lote = ls.id_lote
         WHERE ls.id_variante = :variante AND ls.saldo > 0
         ORDER BY ls.saldo DESC, ls.fecha_ingreso`,
        { variante: idVariante }
    );
}

export function kardex(idVariante) {
    return consulta(
        `SELECT fecha, tipo, movimiento, documento, id_lote, costo_unitario, entrada, salida, saldo,
                ROUND(saldo_valorizado, 2) AS saldo_valorizado, usuario
         FROM ${ESQUEMA}.v_kardex
         WHERE id_variante = :variante
         ORDER BY fecha DESC, id_movimiento DESC
         FETCH FIRST 300 ROWS ONLY`,
        { variante: idVariante }
    );
}

/** Ajuste de inventario: INI (inicial), AJP (positivo), AJN (negativo), MER (merma). */
export function ajustar({ idVariante, tipo, cantidad, motivo, costoUnitario, idLote, fechaVencimiento }, idUsuario) {
    return conUsuario(idUsuario, (t) =>
        llamar(t, "fn_registrar_ajuste", {
            p_variante: idVariante,
            p_tipo: tipo,
            p_cantidad: cantidad,
            p_motivo: motivo,
            p_usuario: idUsuario,
            p_costo_unitario: costoUnitario ?? null,
            p_fecha_vencimiento: fechaVencimiento ?? null,
            p_lote: idLote ?? null,
        })
    );
}

/**
 * Cortar una pieza (banda) en paquetes medidos: [11.2, 11.2]. Lo cortado sale
 * de la pieza (FRS) y entra cada paquete como lote nuevo (FRE); el sobrante
 * queda en la pieza. Devuelve los ids de los paquetes.
 */
export function fraccionar(idLote, piezas, motivo, idUsuario) {
    return conUsuario(idUsuario, async (t) => {
        // fn_fraccionar_lote devuelve SYS.ODCINUMBERLIST: se convierte a texto en PL/SQL
        const r = await t.connection.execute(
            `DECLARE
                 v_lotes SYS.ODCINUMBERLIST;
                 v_texto VARCHAR2(4000);
             BEGIN
                 v_lotes := ${ESQUEMA}.fn_fraccionar_lote(p_lote => :lote, p_piezas => :piezas,
                                                         p_usuario => :usuario, p_motivo => :motivo);
                 FOR i IN 1 .. v_lotes.COUNT LOOP
                     v_texto := v_texto || CASE WHEN i > 1 THEN ',' END || v_lotes(i);
                 END LOOP;
                 :ids := v_texto;
             END;`,
            {
                lote: idLote,
                piezas: JSON.stringify(piezas),
                usuario: idUsuario,
                motivo: motivo ?? null,
                ids: { dir: oracledb.BIND_OUT, type: oracledb.STRING, maxSize: 4000 },
            }
        );
        return String(r.outBinds.ids ?? "").split(",").filter(Boolean).map(Number);
    });
}

export function devolverAProveedor(idLote, { cantidad, motivo }, idUsuario) {
    return conUsuario(idUsuario, (t) =>
        llamar(t, "fn_devolver_a_proveedor", { p_lote: idLote, p_cantidad: cantidad, p_motivo: motivo, p_usuario: idUsuario })
    );
}

export function tiposMovimiento() {
    return consulta(`SELECT id_tipo_movimiento AS codigo, tmv_nombre AS nombre, tmv_signo AS signo FROM ${ESQUEMA}.tipo_movimiento ORDER BY 1`);
}
