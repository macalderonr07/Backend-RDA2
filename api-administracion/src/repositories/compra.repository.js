// src/repositories/compra.repository.js
// Compras: la orden de compra (cabecera + lineas) se escribe con el ORM; sus
// cambios de estado, la recepcion en bodega y los comprobantes del proveedor
// van por las funciones de la base (fn_cambiar_estado_oc,
// fn_recepcionar_compra, fn_registrar_comprobante_compra), que validan
// cantidades pendientes, crean lotes y movimientos de kardex.
import { conUsuario, consulta, llamar, procedimiento, ESQUEMA } from "../config/db.js";
import { m } from "../models/index.js";
import { AppError } from "../utils/AppError.js";
import { ordenSql } from "../middlewares/paginacion.js";

const ORDEN_OC = { id_orden_compra: "id_orden_compra", proveedor: "proveedor", oc_fecha: "oc_fecha", oc_fecha_entrega_esperada: "oc_fecha_entrega_esperada", valor_pactado: "valor_pactado", oc_estado: "oc_estado" };
const ORDEN_COMPROBANTES = { numero: "numero", proveedor: "proveedor", emision: "emision", vencimiento: "vencimiento", total: "total", saldo: "saldo" };

export async function listarOrdenes({ estado = null, limit, offset, orden, dir }) {
    const where = estado ? "WHERE oc_estado = :estado" : "";
    const binds = estado ? { estado } : {};
    const [{ total }] = await consulta(`SELECT COUNT(*) AS total FROM ${ESQUEMA}.v_orden_compra_estado ${where}`, binds);
    const filas = await consulta(
        `SELECT id_orden_compra, proveedor, oc_fecha, oc_fecha_entrega_esperada, oc_estado, valor_pactado,
                estado_recepcion, atrasada
         FROM ${ESQUEMA}.v_orden_compra_estado ${where}
         ORDER BY ${ordenSql({ orden, dir }, ORDEN_OC, "id_orden_compra DESC", "id_orden_compra DESC")}
         OFFSET :offset ROWS FETCH NEXT :limit ROWS ONLY`,
        { ...binds, offset, limit }
    );
    return { filas: filas.map((f) => ({ ...f, id: f.id_orden_compra })), total };
}

export async function detalleOrden(idOrdenCompra) {
    const oc = await m.OrdenCompra.findByPk(idOrdenCompra, {
        include: [{ model: m.Proveedor, as: "proveedor", attributes: ["idProveedor", "razonSocial", "nombreComercial"] }],
    });
    if (!oc) return null;
    const lineas = await consulta(
        `SELECT d.id_detalle_orden_compra, d.id_variante, d.var_sku, p.prd_nombre, p.id_unidad_medida AS unidad,
                p.prd_venta_por_pieza AS por_pieza, p.prd_cortes_estandar AS cortes_estandar,
                p.prd_compra_descripcion AS compra_descripcion, p.prd_compra_factor AS compra_factor,
                d.cantidad_pedida, d.costo_pactado, d.cantidad_recibida, d.cantidad_pendiente,
                -- paso del selector al recibir en la unidad del inventario: enteros si
                -- todas sus formas de venta son enteras; si no, cualquier decimal
                CASE WHEN (SELECT NVL(MAX(MOD(pr.pre_incremento, 1) + MOD(pr.pre_factor, 1)), 0) FROM ${ESQUEMA}.presentacion pr
                           WHERE pr.id_variante = d.id_variante AND pr.pre_activa = 1) = 0 THEN 1 ELSE 0.01 END AS paso
         FROM ${ESQUEMA}.v_orden_compra_detalle d
         JOIN ${ESQUEMA}.variante v ON v.id_variante = d.id_variante
         JOIN ${ESQUEMA}.producto p ON p.id_producto = v.id_producto
         WHERE d.id_orden_compra = :oc
         ORDER BY d.id_detalle_orden_compra`,
        { oc: idOrdenCompra }
    );
    return {
        id: oc.idOrdenCompra,
        idOrdenCompra: oc.idOrdenCompra,
        estado: oc.estado,
        fecha: oc.fecha,
        fechaEntregaEsperada: oc.fechaEntregaEsperada,
        observacion: oc.observacion,
        proveedor: oc.proveedor ? { id: oc.proveedor.idProveedor, nombre: oc.proveedor.nombreComercial ?? oc.proveedor.razonSocial } : null,
        lineas,
        total: Math.round(lineas.reduce((s, l) => s + l.cantidad_pedida * l.costo_pactado, 0) * 100) / 100,
    };
}

/** Orden nueva en BORRADOR con sus lineas (cantidad en unidad base, costo por unidad base). */
export function crearOrden({ idProveedor, fechaEntregaEsperada, observacion, lineas }, idUsuario) {
    return conUsuario(idUsuario, async (transaction) => {
        const oc = await m.OrdenCompra.create(
            { idProveedor, idUsuarioCrea: idUsuario, fechaEntregaEsperada: fechaEntregaEsperada ?? null, observacion: observacion ?? null },
            { transaction }
        );
        // un producto sin costo por variante lleva el MISMO costo en todas sus lineas
        const variantes = await m.Variante.findAll({ where: { idVariante: lineas.map((l) => l.idVariante) }, include: [{ model: m.Producto, as: "producto" }], transaction });
        const porProducto = new Map();
        for (const l of lineas) {
            const v = variantes.find((x) => x.idVariante === l.idVariante);
            if (!v || v.producto?.precioPorVariante === 1) continue;
            const costos = porProducto.get(v.idProducto) ?? { nombre: v.producto.nombre, costos: new Set() };
            costos.costos.add(Number(l.costoUnitario));
            porProducto.set(v.idProducto, costos);
        }
        for (const { nombre, costos } of porProducto.values()) {
            if (costos.size > 1) throw new AppError(`${nombre} tiene un solo costo para todos sus colores y tallas: usa el mismo en todas las líneas`, 422);
        }
        for (const l of lineas) {
            await m.DetalleOrdenCompra.create(
                { idOrdenCompra: oc.idOrdenCompra, idVariante: l.idVariante, cantidad: l.cantidad, costoUnitario: l.costoUnitario },
                { transaction }
            );
        }
        return oc.idOrdenCompra;
    });
}

/** EMITIDA (se envia al proveedor), ANULADA o CERRADA: la base valida la transicion. */
export function cambiarEstado(idOrdenCompra, estado, idUsuario) {
    return conUsuario(idUsuario, (t) =>
        procedimiento(t, "fn_cambiar_estado_oc", { p_orden: idOrdenCompra, p_estado: estado, p_usuario: idUsuario })
    );
}

/**
 * Recepcion en bodega: cada linea recibida entra como lote con su costo (por
 * defecto el pactado). Para cuero, una linea por banda con su area y su codigo.
 */
export function recepcionar(idOrdenCompra, { lineas, idComprobanteCompra }, idUsuario) {
    return conUsuario(idUsuario, (t) =>
        llamar(t, "fn_recepcionar_compra", {
            p_orden: idOrdenCompra,
            p_usuario: idUsuario,
            p_lineas: JSON.stringify(
                lineas.map((l) => ({
                    id_detalle_orden_compra: l.idDetalleOrdenCompra,
                    cantidad: l.cantidad,
                    ...(l.costoUnitario != null ? { costo_unitario: l.costoUnitario } : {}),
                    ...(l.codigoLote ? { codigo_lote: l.codigoLote } : {}),
                    ...(l.fechaVencimiento ? { fecha_vencimiento: l.fechaVencimiento } : {}),
                }))
            ),
            p_comprobante_compra: idComprobanteCompra ?? null,
        })
    );
}

export async function comprobantes({ limit, offset, orden, dir }) {
    const [{ total }] = await consulta(`SELECT COUNT(*) AS total FROM ${ESQUEMA}.v_cuentas_por_pagar`);
    const filas = await consulta(
        `SELECT id_comprobante_compra, proveedor, tipo_comprobante, numero, emision, vencimiento, total,
                notas_credito, pagado, saldo, vencida
         FROM ${ESQUEMA}.v_cuentas_por_pagar
         ORDER BY ${ordenSql({ orden, dir }, ORDEN_COMPROBANTES, "emision DESC, id_comprobante_compra DESC", "id_comprobante_compra DESC")}
         OFFSET :offset ROWS FETCH NEXT :limit ROWS ONLY`,
        { offset, limit }
    );
    return { filas: filas.map((f) => ({ ...f, id: f.id_comprobante_compra })), total };
}

/** Siguiente numero de recibo: REC-000001, REC-000002... (la base lo hace unico). */
async function siguienteRecibo(t) {
    const [f] = await consulta(
        `SELECT NVL(MAX(TO_NUMBER(SUBSTR(cco_numero, 5))), 0) + 1 AS n
         FROM ${ESQUEMA}.comprobante_compra
         WHERE id_tipo_comprobante = '00' AND REGEXP_LIKE(cco_numero, '^REC-[0-9]{1,15}$')`,
        {},
        t
    );
    return `REC-${String(f.n).padStart(6, "0")}`;
}

/** Factura (01), nota de venta (02) o recibo (00, numero automatico y sin IVA). */
export function registrarComprobante(d, idUsuario) {
    return conUsuario(idUsuario, async (t) =>
        llamar(t, "fn_registrar_comprobante_compra", {
            p_proveedor: d.idProveedor,
            p_tipo: d.tipo,
            p_numero: d.tipo === "00" ? await siguienteRecibo(t) : d.numero,
            p_fecha_emision: d.fechaEmision,
            p_fecha_vencimiento: d.fechaVencimiento,
            p_subtotal_0: d.subtotal0 ?? 0,
            p_subtotal_gravado: d.subtotalGravado ?? 0,
            p_iva: d.iva ?? 0,
            p_usuario: idUsuario,
            p_clave_acceso: d.claveAcceso ?? null,
        })
    );
}

export function recepcionesPorFacturar() {
    return consulta(
        `SELECT id_movimiento, proveedor, id_orden_compra, fecha, valor, iva_estimado, total_estimado, dias_sin_factura
         FROM ${ESQUEMA}.v_recepciones_por_facturar ORDER BY fecha DESC FETCH FIRST 200 ROWS ONLY`
    );
}

// ------------------------------------------------------------------ Productos para la orden de compra
/** Paso 1: productos (uno por fila, publicados o no) con cuanto hay que reponer. */
/**
 * Productos para la orden de compra. Con idProveedor, primero los de ese
 * proveedor (del_proveedor = 1) y despues los demas.
 */
export function productosCompra(q, idProveedor = null) {
    return consulta(
        `SELECT p.id_producto, p.prd_codigo, p.prd_nombre, c.cat_nombre AS categoria, p.prd_imagen_url AS imagen_url, p.id_unidad_medida AS unidad,
                p.prd_compra_descripcion AS compra_descripcion,
                CASE WHEN EXISTS (SELECT 1 FROM ${ESQUEMA}.producto_proveedor pp WHERE pp.id_producto = p.id_producto AND pp.id_proveedor = :prov)
                     THEN 1 ELSE 0 END AS del_proveedor,
                COUNT(*) AS variantes, SUM(s.requiere_compra) AS a_reponer
         FROM ${ESQUEMA}.producto p
         JOIN ${ESQUEMA}.categoria c ON c.id_categoria = p.id_categoria
         JOIN ${ESQUEMA}.variante v ON v.id_producto = p.id_producto AND v.var_activa = 1
         JOIN ${ESQUEMA}.v_stock_variante s ON s.id_variante = v.id_variante
         WHERE (:q IS NULL OR INSTR(LOWER(p.prd_nombre || ' ' || p.prd_codigo || ' ' || c.cat_nombre), :q) > 0)
         GROUP BY p.id_producto, p.prd_codigo, p.prd_nombre, c.cat_nombre, p.prd_imagen_url, p.id_unidad_medida, p.prd_compra_descripcion
         ORDER BY del_proveedor DESC, SUM(s.requiere_compra) DESC, p.prd_nombre
         FETCH FIRST 30 ROWS ONLY`,
        { q: q ? q.toLowerCase() : null, prov: idProveedor ?? null }
    );
}

/** "Color: Negro, Talla: 35" -> { Color: "Negro", Talla: "35" } */
const caracteristicasDe = (texto) =>
    Object.fromEntries(String(texto ?? "").split(/,\s*(?=[^,:]+:)/).map((x) => x.split(/:\s*/)).filter((x) => x.length === 2));

/**
 * Paso 2: variantes del producto para pedir al proveedor: stock, minimo, en
 * camino, lo sugerido (lo que falta para el minimo) y el ultimo costo pagado.
 * entero: si el producto se cuenta en unidades enteras (pares, unidades) o en
 * medidas decimales (pie2, metros, litros).
 */
export async function productoCompra(idProducto) {
    const filas = await consulta(
        `SELECT p.id_producto, p.prd_codigo, p.prd_nombre, p.id_unidad_medida AS unidad, p.prd_venta_por_pieza, p.prd_precio_por_variante, p.prd_compra_descripcion, p.prd_compra_factor,
                v.id_variante, v.var_sku, s.stock_fisico, s.disponible, s.en_camino, s.stock_minimo, s.requiere_compra,
                GREATEST(s.stock_minimo - s.disponible - s.en_camino, 0) AS sugerido,
                (SELECT MAX(l.lot_costo_unitario) KEEP (DENSE_RANK LAST ORDER BY l.id_lote)
                 FROM ${ESQUEMA}.lote l WHERE l.id_variante = v.id_variante AND l.id_lote_origen IS NULL) AS ultimo_costo,
                (SELECT MIN(MOD(pr.pre_incremento, 1) + MOD(pr.pre_factor, 1)) FROM ${ESQUEMA}.presentacion pr WHERE pr.id_variante = v.id_variante) AS decimales,
                (SELECT LISTAGG(a.atr_nombre || ': ' || va.val_valor, ', ') WITHIN GROUP (ORDER BY a.atr_nombre)
                 FROM ${ESQUEMA}.variante_valor vv
                 JOIN ${ESQUEMA}.valor_atributo va ON va.id_valor_atributo = vv.id_valor_atributo
                 JOIN ${ESQUEMA}.atributo a ON a.id_atributo = vv.id_atributo
                 WHERE vv.id_variante = v.id_variante) AS caracteristicas
         FROM ${ESQUEMA}.producto p
         JOIN ${ESQUEMA}.variante v ON v.id_producto = p.id_producto AND v.var_activa = 1
         JOIN ${ESQUEMA}.v_stock_variante s ON s.id_variante = v.id_variante
         WHERE p.id_producto = :id
         ORDER BY v.var_sku`,
        { id: idProducto }
    );
    if (filas.length === 0) return null;
    const f0 = filas[0];
    const variantes = filas.map((f) => ({
        idVariante: f.id_variante,
        sku: f.var_sku,
        caracteristicas: caracteristicasDe(f.caracteristicas),
        stockFisico: f.stock_fisico,
        disponible: f.disponible,
        enCamino: f.en_camino,
        stockMinimo: f.stock_minimo,
        requiereCompra: f.requiere_compra === 1,
        sugerido: f.sugerido,
        ultimoCosto: f.ultimo_costo,
    }));
    const atributos = [...new Set(variantes.flatMap((v) => Object.keys(v.caracteristicas)))].map((nombre) => ({
        nombre,
        valores: [...new Set(variantes.map((v) => v.caracteristicas[nombre]).filter(Boolean))].sort((a, b) => a.localeCompare(b, "es", { numeric: true })),
    }));
    return {
        idProducto: f0.id_producto,
        codigo: f0.prd_codigo,
        nombre: f0.prd_nombre,
        unidad: f0.unidad,
        ventaPorPieza: f0.prd_venta_por_pieza === 1,
        // como se compra: { descripcion: "Rollo × 30 m", factor: 30 } | { descripcion: "Paquete de bandas", factor: null } (se miden) | null (unidad base)
        compra: f0.prd_compra_descripcion ? { descripcion: f0.prd_compra_descripcion, factor: f0.prd_compra_factor ?? null } : null,
        // con 0, el costo es UNO para todo el producto (el cuero cuesta igual en todo color)
        costoPorVariante: f0.prd_precio_por_variante === 1,
        // en una COMPRA manda la unidad: pares y unidades llegan enteros; lo medido
        // (pie2, metros, litros, gramos...) puede llegar con decimales (un rollo de 25,5 m)
        entero: ["u", "par", "doc"].includes(String(f0.unidad).toLowerCase()) && filas.every((f) => !f.decimales),
        atributos,
        variantes,
    };
}
