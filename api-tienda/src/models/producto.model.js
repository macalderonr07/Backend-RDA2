// src/models/producto.model.js
// Repository de productos (solo lectura). Lee v_catalogo_web, la vista que el
// nodo produccion le ofrece al e-commerce: una fila por presentacion con precio
// vigente, IVA, oferta y disponibilidad ya calculados por la base (3FN: aqui no
// se recalcula ningun precio). Este archivo agrupa esas filas en productos.
import { db } from "../config/db.js";
import { caracteristicasDe, colorDe } from "../utils/caracteristicas.js";

const COLUMNAS = `
    c.id_producto, c.prd_codigo, c.prd_nombre, c.categoria, c.categoria_codigo,
    c.linea_codigo, c.linea, c.uso, c.imagen_url, c.es_novedad,
    -- TIMESTAMP sin zona: se entrega como fecha de calendario, no como instante UTC
    TO_CHAR(c.fecha_creacion, 'YYYY-MM-DD') AS fecha_ingreso,
    c.unidad_codigo, c.unidad,
    c.var_sku, c.caracteristicas, c.id_presentacion, c.presentacion, c.cantidad_minima,
    c.precio_con_iva, c.pct_oferta, c.oferta_hasta, c.precio_final_con_iva, c.disponible,
    c.venta_por_pieza, c.cortes_estandar, c.corte_de, c.marca, c.incremento, c.factor`;

// Filtro comun de listar/contar. :q llega ya convertido en patron LIKE.
// La busqueda es SOLO por nombre del producto (el codigo se consulta con
// GET /productos/:codigo). COLLATE BINARY_AI: sin distinguir mayusculas ni
// tildes ("sintetico" = "Sintético").
const FILTRO = `
    WHERE (:linea IS NULL OR c.linea_codigo = :linea)
      AND (:marca IS NULL OR c.marca = :marca)
      AND (:patron IS NULL OR c.prd_nombre COLLATE BINARY_AI LIKE :patron ESCAPE '\\')`;

// El texto del usuario se busca literal: % y _ dejan de ser comodines.
function patronBusqueda(q) {
    if (!q) return null;
    return `%${q.replace(/[\\%_]/g, (c) => `\\${c}`)}%`;
}

/** Agrupa filas de v_catalogo_web (ordenadas por producto) en objetos producto. */
function agruparProductos(filas) {
    const porId = new Map();
    for (const f of filas) {
        let producto = porId.get(f.ID_PRODUCTO);
        if (!producto) {
            producto = {
                codigo: f.PRD_CODIGO,
                nombre: f.PRD_NOMBRE,
                linea: { codigo: f.LINEA_CODIGO, nombre: f.LINEA },
                subcategoria: f.CATEGORIA,
                unidad: { codigo: f.UNIDAD_CODIGO, nombre: f.UNIDAD },
                uso: f.USO,
                imagenUrl: f.IMAGEN_URL,
                novedad: f.ES_NOVEDAD === 1,
                fechaIngreso: f.FECHA_INGRESO,
                // venta por pieza: cada lote es una pieza fisica (banda de cuero)
                // y una linea de venta sale de una sola pieza
                porPieza: f.VENTA_POR_PIEZA === 1,
                // cortes estandar (fibra de caucho en planchas): cada unidad es una
                // pieza de medida fija; la base la corta de la plancha al pedir
                cortesEstandar: f.CORTES_ESTANDAR === 1,
                marca: f.MARCA ?? null, // opcional: no todo producto tiene marca
                presentaciones: [],
            };
            porId.set(f.ID_PRODUCTO, producto);
        }
        producto.presentaciones.push({
            idPresentacion: f.ID_PRESENTACION,
            sku: f.VAR_SKU,
            color: colorDe(f.CARACTERISTICAS),
            caracteristicas: caracteristicasDe(f.CARACTERISTICAS),
            descripcion: f.PRESENTACION,
            cantidadMinima: f.CANTIDAD_MINIMA,
            precio: f.PRECIO_CON_IVA,
            precioFinal: f.PRECIO_FINAL_CON_IVA,
            oferta: f.PCT_OFERTA ? { porcentaje: f.PCT_OFERTA, hasta: f.OFERTA_HASTA } : null,
            disponible: f.DISPONIBLE,
            // la cantidad debe ser multiplo (cuero por pie2: 0.25; lo demas: 1)
            incremento: f.INCREMENTO,
            factor: f.FACTOR, // unidades base que trae la presentacion
            corteDe: f.CORTE_DE ?? null, // cortes estandar: medida de la pieza de la que sale (arbol de cortes)
        });
    }

    // Resumen a nivel producto (lo que pinta una tarjeta del catalogo)
    return [...porId.values()].map((p) => {
        // El precio de la tarjeta sale de lo que se puede comprar; si todo esta
        // agotado, de cualquier presentacion (solo para mostrarlo).
        const conStock = p.presentaciones.filter((x) => x.disponible > 0);
        const masBarata = (conStock.length > 0 ? conStock : p.presentaciones).reduce((a, b) =>
            b.precioFinal < a.precioFinal ? b : a
        );
        return {
            ...p,
            presentacion: masBarata.descripcion,
            precio: masBarata.precioFinal, // con IVA y con la oferta vigente aplicada
            precioSinOferta: masBarata.oferta ? masBarata.precio : null,
            colores: [...new Set(p.presentaciones.map((x) => x.color).filter(Boolean))],
            stockTotal: p.presentaciones.reduce((s, x) => s + x.disponible, 0),
            agotado: conStock.length === 0,
        };
    });
}

export async function listarProductos({ linea = null, marca = null, q = null, limit, offset }) {
    // Se pagina por PRODUCTO (no por fila de presentacion) y luego se traen
    // todas las presentaciones de los productos de esa pagina.
    const { rows } = await db.ejecutar(
        `WITH pagina AS (
             SELECT c.id_producto, MIN(c.prd_codigo) AS codigo
             FROM v_catalogo_web c
             ${FILTRO}
             GROUP BY c.id_producto
             ORDER BY codigo
             OFFSET :offset ROWS FETCH NEXT :limit ROWS ONLY)
         SELECT ${COLUMNAS}
         FROM v_catalogo_web c
         JOIN pagina p ON p.id_producto = c.id_producto
         ORDER BY c.prd_codigo, c.var_sku, c.id_presentacion`,
        { linea, marca, patron: patronBusqueda(q), offset, limit }
    );
    return conDescuentos(agruparProductos(rows));
}

export async function contarProductos({ linea = null, marca = null, q = null }) {
    const { rows } = await db.ejecutar(
        `SELECT COUNT(DISTINCT c.id_producto) AS total FROM v_catalogo_web c ${FILTRO}`,
        { linea, marca, patron: patronBusqueda(q) }
    );
    return rows[0].TOTAL;
}

export async function buscarProductoPorCodigo(codigo) {
    const { rows } = await db.ejecutar(
        `SELECT ${COLUMNAS}
         FROM v_catalogo_web c
         WHERE c.prd_codigo = :codigo
         ORDER BY c.var_sku, c.id_presentacion`,
        { codigo }
    );
    const producto = (await conDescuentos(agruparProductos(rows)))[0] ?? null;
    if (producto?.porPieza && !producto.cortesEstandar) producto.piezas = await piezasPorSku(codigo);
    return producto;
}

/**
 * Documentos COMPLETOS (como el detalle: con piezas y descuentos) de varios
 * productos a la vez, por id. Lo usa el worker de la cache para reconstruir
 * solo lo que cambio. Devuelve [{ id, producto }] (el id es interno: no va en
 * la respuesta de la API). Los que no aparecen ya no se publican.
 */
export async function productosPorIds(ids) {
    const salida = [];
    for (let i = 0; i < ids.length; i += 500) {
        const lote = ids.slice(i, i + 500);
        const binds = Object.fromEntries(lote.map((id, k) => [`i${k}`, id]));
        const { rows } = await db.ejecutar(
            `SELECT ${COLUMNAS}
             FROM v_catalogo_web c
             WHERE c.id_producto IN (${lote.map((_, k) => `:i${k}`).join(", ")})
             ORDER BY c.prd_codigo, c.var_sku, c.id_presentacion`,
            binds
        );
        const idPorCodigo = new Map(rows.map((f) => [f.PRD_CODIGO, f.ID_PRODUCTO]));
        const productos = await conDescuentos(agruparProductos(rows));
        for (const producto of productos) {
            if (producto.porPieza && !producto.cortesEstandar) producto.piezas = await piezasPorSku(producto.codigo);
            salida.push({ id: idPorCodigo.get(producto.codigo), producto });
        }
    }
    return salida;
}

/** Ids de todos los productos publicados (carga completa de la cache). */
export async function idsPublicados() {
    const { rows } = await db.ejecutar("SELECT DISTINCT id_producto FROM v_catalogo_web ORDER BY id_producto");
    return rows.map((f) => f.ID_PRODUCTO);
}

/**
 * Piezas fisicas con saldo de un producto por pieza (v_pieza_web), agrupadas
 * por SKU y de menor a mayor: el mismo orden con el que la base escoge la
 * pieza mas pequena que alcanza al despachar. Sin costos: la vista no los trae.
 */
async function piezasPorSku(codigo) {
    const { rows } = await db.ejecutar(
        `SELECT p.var_sku, p.id_lote, p.codigo, p.saldo
         FROM v_pieza_web p
         WHERE p.prd_codigo = :codigo
         ORDER BY p.var_sku, p.saldo`,
        { codigo }
    );
    const porSku = {};
    for (const f of rows) {
        // saldo = lo LIBRE de la banda (sin lo reservado por pedidos pendientes)
        (porSku[f.VAR_SKU] ??= []).push({ idLote: f.ID_LOTE, codigo: f.CODIGO, saldo: f.SALDO });
    }
    return porSku;
}

/**
 * Reglas de descuento por volumen vigentes (v_descuento_volumen_web), por
 * codigo de producto y de menor a mayor umbral. La base las aplica al crear
 * el pedido; aqui solo se informan.
 */
export async function descuentosVolumen(codigos) {
    if (codigos.length === 0) return new Map();
    const binds = Object.fromEntries(codigos.map((c, i) => [`c${i}`, c]));
    const { rows } = await db.ejecutar(
        `SELECT prd_codigo, cantidad_minima, porcentaje, unidad
         FROM v_descuento_volumen_web
         WHERE prd_codigo IN (${codigos.map((_, i) => `:c${i}`).join(", ")})
         ORDER BY prd_codigo, cantidad_minima`,
        binds
    );
    const porCodigo = new Map();
    for (const f of rows) {
        if (!porCodigo.has(f.PRD_CODIGO)) porCodigo.set(f.PRD_CODIGO, []);
        porCodigo.get(f.PRD_CODIGO).push({ desde: f.CANTIDAD_MINIMA, porcentaje: f.PORCENTAJE, unidad: f.UNIDAD });
    }
    return porCodigo;
}

async function conDescuentos(productos) {
    const reglas = await descuentosVolumen(productos.map((p) => p.codigo));
    return productos.map((p) => ({ ...p, descuentosVolumen: reglas.get(p.codigo) ?? [] }));
}
