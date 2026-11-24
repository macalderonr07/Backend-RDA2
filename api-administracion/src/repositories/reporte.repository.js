// src/repositories/reporte.repository.js
// Reportes con un CONTRATO ESTABLE, pensado para que los tableros (dashboards)
// futuros los consuman sin tocar SQL:
//   - cada reporte declara la pregunta que responde, su categoria, sus
//     parametros (periodo, agrupacion), sus columnas con TIPO (texto, fecha,
//     dinero, numero, porcentaje) y una sugerencia de grafico (visual);
//   - la respuesta trae filas + metadatos + totales, siempre con la misma forma;
//   - los INDICADORES (KPI) comparan el periodo con el anterior de igual largo;
//   - los TABLEROS son configuracion (widgets que apuntan a reportes), no codigo.
// Seguridad: el id del reporte se busca en esta lista (nunca llega al SQL), las
// fechas van como binds y la agrupacion sale de un mapa fijo.
import { consulta, ESQUEMA as E } from "../config/db.js";

const AGRUPACIONES = { dia: "DD", semana: "IW", mes: "MM" };
const RANGO = (col) => `${col} >= TO_DATE(:desde, 'YYYY-MM-DD') AND ${col} < TO_DATE(:hasta, 'YYYY-MM-DD') + 1`;
// Una VENTA es un pedido que no esta cancelado (incluye los pendientes de pago)
const VENTAS = `FROM ${E}.pedido p
    JOIN ${E}.v_pedido_estado_actual ea ON ea.id_pedido = p.id_pedido AND ea.id_estado_pedido <> 'CAN'
    LEFT JOIN ${E}.v_pedido_totales t ON t.id_pedido = p.id_pedido`;
const LINEA = (alias) => `NVL((SELECT cp.cat_nombre FROM ${E}.categoria c JOIN ${E}.categoria cp ON cp.id_categoria = c.id_categoria_padre
                                WHERE c.id_categoria = ${alias}.id_categoria),
                               (SELECT c.cat_nombre FROM ${E}.categoria c WHERE c.id_categoria = ${alias}.id_categoria))`;

const col = (clave, titulo, tipo = "texto", extra = {}) => ({ clave, titulo, tipo, ...extra });

export const CATEGORIAS = ["Ventas", "Clientes", "Inventario", "Compras", "Finanzas", "Seguridad"];

export const REPORTES = Object.freeze({
    // ------------------------------------------------------------------ Ventas
    "ventas-por-periodo": {
        titulo: "Ventas por período",
        pregunta: "¿Cuánto se vendió cada día, semana o mes?",
        categoria: "Ventas",
        parametros: ["periodo", "agrupar"],
        visual: { tipo: "linea", x: "periodo", y: ["total"] },
        columnas: [col("periodo", "Período", "fecha"), col("pedidos", "Pedidos", "numero", { sumar: true }),
            col("total", "Vendido", "dinero", { sumar: true }), col("ticket", "Ticket promedio", "dinero")],
        sql: ({ agrupar }) => `SELECT TRUNC(p.ped_fechahora, '${AGRUPACIONES[agrupar] ?? "DD"}') AS periodo, COUNT(*) AS pedidos,
                NVL(SUM(t.total), 0) AS total, ROUND(NVL(SUM(t.total), 0) / COUNT(*), 2) AS ticket
            ${VENTAS} WHERE ${RANGO("p.ped_fechahora")}
            GROUP BY TRUNC(p.ped_fechahora, '${AGRUPACIONES[agrupar] ?? "DD"}') ORDER BY 1`,
    },
    "ventas-por-canal": {
        titulo: "Ventas por canal",
        pregunta: "¿Por dónde compran más: tienda, WhatsApp o la web?",
        categoria: "Ventas",
        parametros: ["periodo"],
        visual: { tipo: "barras", x: "canal", y: ["total"] },
        columnas: [col("canal", "Canal"), col("pedidos", "Pedidos", "numero", { sumar: true }),
            col("total", "Vendido", "dinero", { sumar: true }), col("participacion", "Participación", "porcentaje")],
        sql: () => `SELECT cv.cav_nombre AS canal, COUNT(*) AS pedidos, NVL(SUM(t.total), 0) AS total,
                ROUND(100 * NVL(SUM(t.total), 0) / NULLIF(SUM(NVL(SUM(t.total), 0)) OVER (), 0), 1) AS participacion
            ${VENTAS} JOIN ${E}.canal_venta cv ON cv.id_canal_venta = p.id_canal_venta
            WHERE ${RANGO("p.ped_fechahora")} GROUP BY cv.cav_nombre ORDER BY total DESC`,
    },
    "productos-mas-vendidos": {
        titulo: "Productos más vendidos",
        pregunta: "¿Qué productos dejan más dinero?",
        categoria: "Ventas",
        parametros: ["periodo"],
        visual: { tipo: "barras", x: "producto", y: ["monto"] },
        columnas: [col("producto", "Producto"), col("prd_codigo", "Código"), col("cantidad", "Cantidad", "numero"), col("unidad", "Unidad"),
            col("pedidos", "Pedidos", "numero"), col("monto", "Vendido con IVA", "dinero", { sumar: true })],
        sql: () => `SELECT pr.prd_nombre AS producto, pr.prd_codigo, SUM(dv.cantidad_base) AS cantidad, pr.id_unidad_medida AS unidad,
                COUNT(DISTINCT p.id_pedido) AS pedidos, SUM(dv.base_imponible + dv.iva) AS monto
            ${VENTAS}
            JOIN ${E}.v_detalle_pedido_valor dv ON dv.id_pedido = p.id_pedido
            JOIN ${E}.variante v ON v.id_variante = dv.id_variante
            JOIN ${E}.producto pr ON pr.id_producto = v.id_producto
            WHERE ${RANGO("p.ped_fechahora")}
            GROUP BY pr.prd_nombre, pr.prd_codigo, pr.id_unidad_medida ORDER BY monto DESC FETCH FIRST 20 ROWS ONLY`,
    },
    "ventas-por-linea": {
        titulo: "Ventas por línea",
        pregunta: "¿Qué líneas (cueros, suelas, herrajes…) venden más?",
        categoria: "Ventas",
        parametros: ["periodo"],
        visual: { tipo: "barras", x: "linea", y: ["monto"] },
        columnas: [col("linea", "Línea"), col("pedidos", "Pedidos", "numero"), col("monto", "Vendido con IVA", "dinero", { sumar: true }),
            col("participacion", "Participación", "porcentaje")],
        sql: () => `SELECT linea, COUNT(DISTINCT id_pedido) AS pedidos, SUM(monto) AS monto,
                ROUND(100 * SUM(monto) / NULLIF(SUM(SUM(monto)) OVER (), 0), 1) AS participacion
            FROM (SELECT ${LINEA("pr")} AS linea, p.id_pedido, dv.base_imponible + dv.iva AS monto
                  ${VENTAS}
                  JOIN ${E}.v_detalle_pedido_valor dv ON dv.id_pedido = p.id_pedido
                  JOIN ${E}.variante v ON v.id_variante = dv.id_variante
                  JOIN ${E}.producto pr ON pr.id_producto = v.id_producto
                  WHERE ${RANGO("p.ped_fechahora")})
            GROUP BY linea ORDER BY monto DESC`,
    },
    "ventas-facturadas": {
        titulo: "Ventas facturadas por presentación",
        pregunta: "¿Qué se facturó, de qué forma de venta y quién lo vendió?",
        categoria: "Ventas",
        parametros: ["periodo"],
        visual: { tipo: "tabla" },
        columnas: [col("fecha", "Fecha", "fecha"), col("vendedor", "Vendedor"), col("var_sku", "SKU"), col("presentacion", "Forma de venta"),
            col("cantidad", "Cantidad", "numero"), col("subtotal", "Subtotal sin IVA", "dinero", { sumar: true })],
        sql: () => `SELECT fecha, vendedor, var_sku, presentacion, cantidad, subtotal FROM ${E}.v_ventas_por_presentacion
            WHERE ${RANGO("fecha")} ORDER BY fecha DESC`,
    },
    // ------------------------------------------------------------------ Clientes
    "clientes-frecuentes": {
        titulo: "Clientes frecuentes",
        pregunta: "¿Quiénes compran más y quiénes dejaron de comprar?",
        categoria: "Clientes",
        parametros: [],
        visual: { tipo: "barras", x: "cliente", y: ["monto_neto"] },
        columnas: [col("cliente", "Cliente"), col("segmento", "Segmento"), col("compras", "Compras", "numero"),
            col("monto_neto", "Monto neto", "dinero", { sumar: true }), col("ultima_compra", "Última compra", "fecha"),
            col("dias_sin_comprar", "Días sin comprar", "numero"), col("canal_preferido", "Canal preferido")],
        sql: () => `SELECT cliente, segmento, compras, monto_neto, ultima_compra, dias_sin_comprar, canal_preferido
            FROM ${E}.v_frecuencia_cliente ORDER BY monto_neto DESC FETCH FIRST 50 ROWS ONLY`,
    },
    // ------------------------------------------------------------------ Inventario
    "inventario-por-linea": {
        titulo: "Inventario valorizado por línea",
        pregunta: "¿Cuánto dinero hay en bodega y en qué líneas?",
        categoria: "Inventario",
        parametros: [],
        visual: { tipo: "barras", x: "linea", y: ["valor"] },
        columnas: [col("linea", "Línea"), col("variantes", "Variantes", "numero", { sumar: true }), col("a_reponer", "Por reponer", "numero", { sumar: true }),
            col("valor", "Valor al costo", "dinero", { sumar: true })],
        // la linea se calcula en una subconsulta: Oracle no admite subconsultas en GROUP BY
        sql: () => `SELECT linea, COUNT(*) AS variantes, SUM(requiere_compra) AS a_reponer, ROUND(SUM(NVL(valor_inventario, 0)), 2) AS valor
            FROM (SELECT ${LINEA("pr")} AS linea, s.requiere_compra, s.valor_inventario
                  FROM ${E}.v_stock_variante s
                  JOIN ${E}.variante v ON v.id_variante = s.id_variante AND v.var_activa = 1
                  JOIN ${E}.producto pr ON pr.id_producto = v.id_producto)
            GROUP BY linea ORDER BY valor DESC`,
    },
    "productos-a-reponer": {
        titulo: "Productos por reponer",
        pregunta: "¿Qué hay que comprar ya, y cuánto falta?",
        categoria: "Inventario",
        parametros: [],
        visual: { tipo: "tabla" },
        columnas: [col("var_sku", "SKU"), col("prd_nombre", "Producto"), col("disponible", "Disponible", "numero"), col("stock_minimo", "Mínimo", "numero"),
            col("en_camino", "En camino", "numero"), col("faltante", "Faltante", "numero"), col("unidad", "Unidad")],
        sql: () => `SELECT s.var_sku, s.prd_nombre, s.disponible, s.stock_minimo, s.en_camino,
                GREATEST(s.stock_minimo - s.disponible - s.en_camino, 0) AS faltante, s.unidad
            FROM ${E}.v_stock_variante s JOIN ${E}.variante v ON v.id_variante = s.id_variante AND v.var_activa = 1
            WHERE s.requiere_compra = 1 ORDER BY faltante DESC, s.var_sku`,
    },
    "inventario-antiguo": {
        titulo: "Mercadería con más tiempo en bodega",
        pregunta: "¿Qué lotes llevan más tiempo sin venderse?",
        categoria: "Inventario",
        parametros: [],
        visual: { tipo: "tabla" },
        columnas: [col("codigo", "Lote o pieza"), col("var_sku", "SKU"), col("prd_nombre", "Producto"), col("saldo", "Saldo", "numero"),
            col("dias", "Días en bodega", "numero"), col("valor", "Valor al costo", "dinero", { sumar: true })],
        sql: () => `SELECT NVL(ls.lot_codigo_proveedor, 'Lote ' || ls.id_lote) AS codigo, v.var_sku, pr.prd_nombre, ls.saldo,
                ls.dias_en_inventario AS dias, ROUND(ls.saldo * ls.lot_costo_unitario, 2) AS valor
            FROM ${E}.v_lote_saldo_total ls -- recorre todos los lotes: la vista agrupada es la rapida aqui
            JOIN ${E}.variante v ON v.id_variante = ls.id_variante
            JOIN ${E}.producto pr ON pr.id_producto = v.id_producto
            WHERE ls.saldo > 0 ORDER BY ls.dias_en_inventario DESC FETCH FIRST 50 ROWS ONLY`,
    },
    // ------------------------------------------------------------------ Compras
    "compras-por-proveedor": {
        titulo: "Compras por proveedor",
        pregunta: "¿A quién se le compra más?",
        categoria: "Compras",
        permiso: "COMPRA_GESTIONAR",
        parametros: ["periodo"],
        visual: { tipo: "barras", x: "proveedor", y: ["monto"] },
        columnas: [col("proveedor", "Proveedor"), col("ordenes", "Órdenes", "numero", { sumar: true }), col("lotes", "Lotes recibidos", "numero", { sumar: true }),
            col("monto", "Recibido sin IVA", "dinero", { sumar: true })],
        sql: () => `SELECT proveedor, COUNT(DISTINCT id_orden_compra) AS ordenes, COUNT(*) AS lotes, ROUND(SUM(cantidad * costo_unitario), 2) AS monto
            FROM ${E}.v_historial_costo_compra WHERE ${RANGO("fecha")} GROUP BY proveedor ORDER BY monto DESC`,
    },
    "historial-costos": {
        titulo: "Variación de costos de compra",
        pregunta: "¿Qué subió de precio con los proveedores?",
        categoria: "Compras",
        permiso: "COMPRA_GESTIONAR",
        parametros: ["periodo"],
        visual: { tipo: "tabla" },
        columnas: [col("fecha", "Fecha", "fecha"), col("var_sku", "SKU"), col("prd_nombre", "Producto"), col("proveedor", "Proveedor"),
            col("cantidad", "Cantidad", "numero"), col("costo_unitario", "Costo", "dinero"), col("costo_anterior", "Costo anterior", "dinero"),
            col("variacion_pct", "Variación", "porcentaje")],
        sql: () => `SELECT fecha, var_sku, prd_nombre, proveedor, cantidad, costo_unitario, costo_anterior, variacion_pct
            FROM ${E}.v_historial_costo_compra WHERE ${RANGO("fecha")} ORDER BY fecha DESC`,
    },
    "proveedores-por-marca": {
        titulo: "Proveedores por marca",
        pregunta: "¿Qué proveedor trae cada marca?",
        categoria: "Compras",
        permiso: "COMPRA_GESTIONAR",
        parametros: [],
        visual: { tipo: "tabla" },
        columnas: [col("marca", "Marca"), col("proveedor", "Proveedor"), col("prd_codigo", "Código"), col("prd_nombre", "Producto"),
            col("ordenes", "Órdenes", "numero"), col("cantidad_base", "Cantidad", "numero"), col("ultima_compra", "Última compra", "fecha")],
        sql: () => `SELECT marca, proveedor, prd_codigo, prd_nombre, ordenes, cantidad_base, ultima_compra FROM ${E}.v_proveedor_marca ORDER BY marca, proveedor`,
    },
    // ------------------------------------------------------------------ Finanzas
    "cartera-por-antiguedad": {
        titulo: "Cartera por antigüedad",
        pregunta: "¿Cuánto nos deben y hace cuánto venció?",
        categoria: "Finanzas",
        parametros: [],
        visual: { tipo: "barras", x: "tramo", y: ["saldo"] },
        columnas: [col("tramo", "Tramo"), col("cuentas", "Cuentas", "numero", { sumar: true }), col("saldo", "Saldo", "dinero", { sumar: true })],
        sql: () => `SELECT tramo, COUNT(*) AS cuentas, SUM(saldo) AS saldo FROM (
                SELECT saldo, CASE WHEN NVL(dias_vencida, 0) <= 0 THEN '1. Al día' WHEN dias_vencida <= 30 THEN '2. Vencida 1 a 30 días'
                                   WHEN dias_vencida <= 60 THEN '3. Vencida 31 a 60 días' WHEN dias_vencida <= 90 THEN '4. Vencida 61 a 90 días'
                                   ELSE '5. Vencida más de 90 días' END AS tramo
                FROM ${E}.v_cuentas_por_cobrar WHERE saldo > 0)
            GROUP BY tramo ORDER BY tramo`,
    },
    "cuentas-por-cobrar": {
        titulo: "Cuentas por cobrar",
        pregunta: "¿Quién nos debe y cuándo vence?",
        categoria: "Finanzas",
        parametros: [],
        visual: { tipo: "tabla" },
        columnas: [col("cliente", "Cliente"), col("id_pedido", "Pedido", "numero"), col("concepto", "Concepto"), col("vencimiento", "Vence", "fecha"),
            col("monto", "Monto", "dinero", { sumar: true }), col("abonado", "Abonado", "dinero", { sumar: true }), col("saldo", "Saldo", "dinero", { sumar: true }),
            col("dias_vencida", "Días vencida", "numero")],
        sql: () => `SELECT cliente, id_pedido, concepto, vencimiento, monto, abonado, saldo, dias_vencida
            FROM ${E}.v_cuentas_por_cobrar WHERE saldo > 0 ORDER BY vencimiento`,
    },
    "cuentas-por-pagar": {
        titulo: "Cuentas por pagar",
        pregunta: "¿A quién le debemos y cuándo vence?",
        categoria: "Finanzas",
        permiso: "COMPRA_GESTIONAR",
        parametros: [],
        visual: { tipo: "tabla" },
        columnas: [col("proveedor", "Proveedor"), col("tipo_comprobante", "Comprobante"), col("numero", "Número"), col("emision", "Emisión", "fecha"),
            col("vencimiento", "Vence", "fecha"), col("total", "Total", "dinero", { sumar: true }), col("pagado", "Pagado", "dinero", { sumar: true }),
            col("saldo", "Saldo", "dinero", { sumar: true })],
        sql: () => `SELECT proveedor, tipo_comprobante, numero, emision, vencimiento, total, pagado, saldo
            FROM ${E}.v_cuentas_por_pagar WHERE saldo > 0 ORDER BY vencimiento`,
    },
    "estado-proveedores": {
        titulo: "Estado de cuenta de proveedores",
        pregunta: "¿Cuánto se le debe a cada proveedor, incluida mercadería sin factura?",
        categoria: "Finanzas",
        permiso: "COMPRA_GESTIONAR",
        parametros: [],
        visual: { tipo: "barras", x: "proveedor", y: ["deuda_estimada"] },
        columnas: [col("proveedor", "Proveedor"), col("mercaderia_recibida", "Recibido", "dinero"), col("facturado", "Facturado", "dinero"),
            col("pagado", "Pagado", "dinero"), col("saldo_vencido", "Vencido", "dinero", { sumar: true }), col("deuda_estimada", "Deuda estimada", "dinero", { sumar: true })],
        sql: () => `SELECT proveedor, mercaderia_recibida, facturado, pagado, saldo_vencido, deuda_estimada
            FROM ${E}.v_estado_cuenta_proveedor ORDER BY deuda_estimada DESC`,
    },
    // ------------------------------------------------------------------ Seguridad
    "auditoria": {
        titulo: "Bitácora de eventos",
        pregunta: "¿Quién entró y qué pasó en el sistema?",
        categoria: "Seguridad",
        permiso: "AUDITORIA_CONSULTAR",
        parametros: ["periodo"],
        visual: { tipo: "tabla" },
        columnas: [col("fecha", "Fecha", "fecha"), col("nivel", "Nivel"), col("origen", "Origen"), col("evento", "Evento"), col("mensaje", "Mensaje")],
        sql: () => `SELECT l.lev_fechahora AS fecha, l.lev_nivel AS nivel, l.lev_origen AS origen, l.lev_evento AS evento, l.lev_mensaje AS mensaje
            FROM ${E}.log_evento l WHERE ${RANGO("l.lev_fechahora")} ORDER BY l.lev_fechahora DESC`,
    },
});

/** Metadatos publicos de un reporte (sin SQL). */
export const metaReporte = (id, r) => ({
    id,
    titulo: r.titulo,
    pregunta: r.pregunta,
    categoria: r.categoria,
    parametros: r.parametros,
    visual: r.visual,
    columnas: r.columnas,
});

export async function ejecutar(id, { desde, hasta, agrupar = "dia" }) {
    const r = REPORTES[id];
    const usaPeriodo = r.parametros.includes("periodo");
    const filas = await consulta(`${r.sql({ agrupar })}${/FETCH FIRST/.test(r.sql({ agrupar })) ? "" : " FETCH FIRST 1000 ROWS ONLY"}`, usaPeriodo ? { desde, hasta } : {});
    const totales = Object.fromEntries(
        r.columnas.filter((c) => c.sumar).map((c) => [c.clave, Math.round(filas.reduce((s, f) => s + (Number(f[c.clave]) || 0), 0) * 100) / 100])
    );
    return { filas, totales, parametros: usaPeriodo ? { desde, hasta, ...(r.parametros.includes("agrupar") ? { agrupar } : {}) } : {} };
}

// ------------------------------------------------------------------ Indicadores (KPI)
/** Indicadores del periodo y del periodo anterior de igual largo (para la variacion). */
export async function indicadores({ desde, hasta, anteriorDesde, anteriorHasta }, permisos) {
    const ventas = async (d, h) => {
        const [r] = await consulta(
            `SELECT COUNT(*) AS pedidos, NVL(SUM(t.total), 0) AS vendido ${VENTAS} WHERE ${RANGO("p.ped_fechahora")}`,
            { desde: d, hasta: h }
        );
        return { ...r, ticket: r.pedidos ? Math.round((r.vendido / r.pedidos) * 100) / 100 : 0 };
    };
    const [actual, anterior] = await Promise.all([ventas(desde, hasta), ventas(anteriorDesde, anteriorHasta)]);
    const [cobros] = await consulta(
        `SELECT NVL(SUM(pa.pag_monto), 0) AS cobrado FROM ${E}.pago pa WHERE ${RANGO("pa.pag_fechahora")}`,
        { desde, hasta }
    );
    const [cobrosAntes] = await consulta(
        `SELECT NVL(SUM(pa.pag_monto), 0) AS cobrado FROM ${E}.pago pa WHERE ${RANGO("pa.pag_fechahora")}`,
        { desde: anteriorDesde, hasta: anteriorHasta }
    );
    const [foto] = await consulta(
        `SELECT
            (SELECT NVL(SUM(saldo), 0) FROM ${E}.v_cuentas_por_cobrar WHERE saldo > 0) AS por_cobrar,
            (SELECT NVL(SUM(saldo), 0) FROM ${E}.v_cuentas_por_cobrar WHERE saldo > 0 AND dias_vencida > 0) AS por_cobrar_vencido,
            (SELECT NVL(SUM(saldo), 0) FROM ${E}.v_cuentas_por_pagar WHERE saldo > 0) AS por_pagar,
            (SELECT ROUND(NVL(SUM(s.valor_inventario), 0), 2) FROM ${E}.v_stock_variante s) AS valor_inventario,
            (SELECT COUNT(*) FROM ${E}.v_stock_variante s JOIN ${E}.variante v ON v.id_variante = s.id_variante
              WHERE s.requiere_compra = 1 AND v.var_activa = 1) AS a_reponer,
            (SELECT COUNT(*) FROM ${E}.v_pedido_estado_actual WHERE id_estado_pedido = 'PEN') AS pendientes
         FROM dual`
    );
    const variacion = (a, b) => (b ? Math.round(((a - b) / b) * 1000) / 10 : null);
    const kpi = (clave, titulo, valor, tipo, { anterior = null, ayuda = null, enlace = null, mejorSi = "sube" } = {}) => ({
        clave, titulo, valor, tipo, anterior, variacion: anterior === null ? null : variacion(valor, anterior), mejorSi, ayuda, enlace,
    });
    return [
        kpi("vendido", "Vendido", actual.vendido, "dinero", { anterior: anterior.vendido, ayuda: "Pedidos no cancelados, con IVA", enlace: "/reportes/ventas-por-periodo" }),
        kpi("pedidos", "Pedidos", actual.pedidos, "numero", { anterior: anterior.pedidos, enlace: "/ventas" }),
        kpi("ticket", "Ticket promedio", actual.ticket, "dinero", { anterior: anterior.ticket, ayuda: "Vendido ÷ pedidos" }),
        kpi("cobrado", "Cobrado", cobros.cobrado, "dinero", { anterior: cobrosAntes.cobrado, ayuda: "Pagos registrados en el período", enlace: "/ventas/cobros" }),
        kpi("por_cobrar", "Por cobrar hoy", foto.por_cobrar, "dinero", { ayuda: `${foto.por_cobrar_vencido ? `Vencido: $${foto.por_cobrar_vencido.toFixed(2)}` : "Nada vencido"}`, enlace: "/reportes/cartera-por-antiguedad", mejorSi: "baja" }),
        ...(permisos.includes("COMPRA_GESTIONAR")
            ? [kpi("por_pagar", "Por pagar hoy", foto.por_pagar, "dinero", { enlace: "/reportes/cuentas-por-pagar", mejorSi: "baja" })]
            : []),
        kpi("valor_inventario", "Inventario al costo", foto.valor_inventario, "dinero", { enlace: "/reportes/inventario-por-linea" }),
        kpi("a_reponer", "Variantes por reponer", foto.a_reponer, "numero", { enlace: "/reportes/productos-a-reponer", mejorSi: "baja" }),
        kpi("pendientes", "Pedidos pendientes de pago", foto.pendientes, "numero", { enlace: "/ventas", mejorSi: "baja" }),
    ];
}

// ------------------------------------------------------------------ Tableros
// Configuracion de tableros: una lista de widgets que apuntan a indicadores o a
// reportes con su visual. Un tablero nuevo = una entrada aqui (o, mas adelante,
// una tabla en la base), sin programar pantallas.
export const TABLEROS = Object.freeze([
    {
        id: "general",
        titulo: "Tablero general",
        descripcion: "Cómo va el negocio en el período elegido.",
        widgets: [
            { tipo: "indicadores" },
            { tipo: "reporte", reporte: "ventas-por-periodo", ancho: "completo" },
            { tipo: "reporte", reporte: "ventas-por-linea", ancho: "medio", limite: 8 },
            { tipo: "reporte", reporte: "ventas-por-canal", ancho: "medio" },
            { tipo: "reporte", reporte: "productos-mas-vendidos", ancho: "medio", limite: 8 },
            { tipo: "reporte", reporte: "cartera-por-antiguedad", ancho: "medio" },
        ],
    },
]);

/** Indicadores de "Inicio": lo que conviene atender hoy. */
export async function resumen() {
    const [r] = await consulta(
        `SELECT
            (SELECT COUNT(*) FROM ${E}.v_pedido_estado_actual WHERE id_estado_pedido = 'PEN') AS pedidos_pendientes,
            (SELECT COUNT(*) FROM ${E}.v_pedido_estado_actual WHERE id_estado_pedido IN ('PAG', 'FAC')) AS pedidos_por_despachar,
            (SELECT COUNT(*) FROM ${E}.v_stock_variante s JOIN ${E}.variante v ON v.id_variante = s.id_variante
              WHERE s.requiere_compra = 1 AND v.var_activa = 1) AS variantes_por_comprar,
            (SELECT COUNT(*) FROM ${E}.v_orden_compra_estado WHERE oc_estado = 'EMITIDA') AS ordenes_abiertas,
            (SELECT COUNT(*) FROM ${E}.v_orden_compra_estado WHERE atrasada = 1) AS ordenes_atrasadas,
            (SELECT NVL(SUM(t.total), 0) FROM ${E}.pedido p JOIN ${E}.v_pedido_totales t ON t.id_pedido = p.id_pedido
              JOIN ${E}.v_pedido_estado_actual ea ON ea.id_pedido = p.id_pedido
              WHERE p.ped_fechahora >= TRUNC(LOCALTIMESTAMP, 'MM') AND ea.id_estado_pedido <> 'CAN') AS vendido_mes,
            (SELECT NVL(SUM(saldo), 0) FROM ${E}.v_cuentas_por_cobrar WHERE saldo > 0) AS por_cobrar,
            (SELECT COUNT(*) FROM ${E}.producto WHERE prd_publicado = 1) AS productos_publicados
         FROM dual`
    );
    return r;
}
