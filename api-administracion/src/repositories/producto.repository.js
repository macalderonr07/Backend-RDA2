// src/repositories/producto.repository.js
// Productos con su logica (modelo de la base, 3FN):
//   producto -> variantes (una por combinacion de atributos: color x talla)
//            -> presentaciones (formas de venta de cada variante: factor en
//               unidad base, minimo e incremento) -> precio (historial_precio)
// Los precios se registran SIEMPRE con fn_registrar_precio (historial
// inmutable, permiso PRECIO_GESTIONAR); las ofertas con fn_registrar_oferta.
import { Op, literal } from "sequelize";
import { conUsuario, consulta, ESQUEMA, llamar, procedimiento } from "../config/db.js";
import { m } from "../models/index.js";
import { AppError } from "../utils/AppError.js";
import { codigoCombo, codigoProducto } from "../utils/codigos.js";

const enLista = (ids) => (ids.length > 0 ? ids : [-1]);
// EPSILON: 0.015 en binario es 0.01499...; sin el, ROUND de Oracle (0.02) y JS (0.01) discreparian
const redondear2 = (n) => Math.round((n + Number.EPSILON) * 100) / 100;

/**
 * Los precios se ESCRIBEN con IVA (lo que paga el cliente), pero la base guarda
 * el precio sin IVA (historial_precio, 2 decimales): la factura desglosa el IVA
 * sobre esa base. La conversion la hace la base con fn_base_desde_final, la
 * misma que usa el mostrador para un valor pactado: elige la base de 2
 * decimales cuyo total con IVA queda lo mas cerca posible SIN pasarse.
 */
async function baseDesdeConIva(t, idProducto, precioConIva) {
    const [fila] = await consulta(
        `SELECT produccion.fn_base_desde_final(:final, ti.tiv_porcentaje, 1) AS base
         FROM produccion.producto p JOIN produccion.tarifa_iva ti ON ti.id_tarifa_iva = p.id_tarifa_iva
         WHERE p.id_producto = :id`,
        { final: precioConIva, id: idProducto },
        t
    );
    if (!fila) throw new AppError(`No existe el producto ${idProducto}`, 404);
    return fila.base;
}

/** El precio con IVA que resulta de una base (misma formula que la factura). */
const conIva = (base, porcentaje) => (base === null || base === undefined ? null : redondear2(base + redondear2((base * porcentaje) / 100)));

function binds(ids, prefijo) {
    return {
        sql: ids.map((_, i) => `:${prefijo}${i}`).join(", "),
        valores: Object.fromEntries(ids.map((v, i) => [`${prefijo}${i}`, v])),
    };
}

/** Orden del listado (lista blanca); categoria y marca por su NOMBRE. */
function ordenProductos(orden, dir) {
    const d = dir === "desc" ? "DESC" : "ASC";
    const mapa = {
        codigo: [["codigo", d]],
        nombre: [["nombre", d]],
        publicado: [["publicado", d]],
        categoria: [[{ model: m.Categoria, as: "categoria" }, "nombre", d]],
        marca: [[{ model: m.Marca, as: "marca" }, "nombre", `${d} NULLS LAST`]],
        // columnas calculadas: subconsultas fijas (nada del cliente entra al SQL)
        variantes: [[literal(`(SELECT COUNT(*) FROM produccion.variante v WHERE v.id_producto = "Producto"."ID_PRODUCTO" AND v.var_activa = 1)`), d]],
        formasDeVenta: [[literal(`(SELECT COUNT(DISTINCT pr.pre_descripcion) FROM produccion.presentacion pr JOIN produccion.variante v ON v.id_variante = pr.id_variante
                                   WHERE v.id_producto = "Producto"."ID_PRODUCTO" AND v.var_activa = 1 AND pr.pre_activa = 1)`), d]],
        disponible: [[literal(`(SELECT NVL(SUM(s.disponible), 0) FROM produccion.v_stock_variante s JOIN produccion.variante v ON v.id_variante = s.id_variante
                                WHERE v.id_producto = "Producto"."ID_PRODUCTO" AND v.var_activa = 1)`), d]],
    };
    return [...(mapa[orden] ?? [["codigo", "ASC"]]), ["idProducto", "ASC"]];
}

export async function listar({ q = null, idCategoria = null, publicado = null, requiereCompra = false, limit, offset, orden, dir }) {
    const where = {};
    // solo productos con alguna variante activa bajo su minimo (inventario: "hay que reponer")
    if (requiereCompra) {
        where[Op.and] = [literal(`EXISTS (SELECT 1 FROM produccion.v_stock_variante s JOIN produccion.variante v ON v.id_variante = s.id_variante
                                          WHERE v.id_producto = "Producto"."ID_PRODUCTO" AND v.var_activa = 1 AND s.requiere_compra = 1)`)];
    }
    if (idCategoria) where.idCategoria = idCategoria;
    if (publicado !== null) where.publicado = publicado;
    if (q) {
        const texto = q.toLowerCase();
        where[Op.or] = ["PRD_CODIGO", "PRD_NOMBRE"].map((col) =>
            m.Producto.sequelize.where(
                m.Producto.sequelize.fn("INSTR", m.Producto.sequelize.fn("LOWER", m.Producto.sequelize.col(col)), texto),
                Op.gt,
                0
            )
        );
    }
    const { rows, count } = await m.Producto.findAndCountAll({
        where,
        include: [
            { model: m.Categoria, as: "categoria", attributes: ["nombre", "codigo"] },
            { model: m.Marca, as: "marca", attributes: ["nombre"] },
            { model: m.UnidadMedida, as: "unidad", attributes: ["nombre"] },
        ],
        order: ordenProductos(orden, dir),
        limit,
        offset,
    });
    const ids = rows.map((p) => p.idProducto);
    const b = binds(enLista(ids), "p");
    const conteos = await consulta(
        `SELECT v.id_producto,
                COUNT(DISTINCT CASE WHEN v.var_activa = 1 THEN v.id_variante END) AS variantes,
                COUNT(DISTINCT CASE WHEN pr.pre_activa = 1 AND v.var_activa = 1 THEN pr.pre_descripcion END) AS formas
         FROM produccion.variante v
         LEFT JOIN produccion.presentacion pr ON pr.id_variante = v.id_variante
         WHERE v.id_producto IN (${b.sql})
         GROUP BY v.id_producto`,
        b.valores
    );
    const stock = await consulta(
        `SELECT v.id_producto, SUM(s.disponible) AS disponible, MAX(s.requiere_compra) AS requiere_compra, MAX(s.unidad) AS unidad
         FROM produccion.v_stock_variante s
         JOIN produccion.variante v ON v.id_variante = s.id_variante
         WHERE v.id_producto IN (${b.sql}) AND v.var_activa = 1
         GROUP BY v.id_producto`,
        b.valores
    );
    const c = new Map(conteos.map((x) => [x.id_producto, x]));
    const s = new Map(stock.map((x) => [x.id_producto, x]));
    return {
        total: count,
        filas: rows.map((p) => ({
            id: p.idProducto,
            idProducto: p.idProducto,
            codigo: p.codigo,
            nombre: p.nombre,
            categoria: p.categoria?.nombre ?? null,
            marca: p.marca?.nombre ?? null,
            unidad: p.unidad?.nombre ?? null,
            publicado: p.publicado === 1,
            ventaPorPieza: p.ventaPorPieza === 1,
            cortesEstandar: p.cortesEstandar === 1,
            variantes: c.get(p.idProducto)?.variantes ?? 0,
            formasDeVenta: c.get(p.idProducto)?.formas ?? 0,
            disponible: s.get(p.idProducto)?.disponible ?? 0,
            requiereCompra: s.get(p.idProducto)?.requiere_compra === 1,
        })),
    };
}

const planoAtributo = (a) => ({
    idAtributo: a.idAtributo,
    nombre: a.nombre,
    valores: a.valores.map((v) => ({ idValorAtributo: v.idValorAtributo, valor: v.valor })).sort((x, y) => x.valor.localeCompare(y.valor, "es", { numeric: true })),
});

/**
 * Atributos de una categoria: "propios" (definidos para ella o para su linea:
 * los atributos de la linea aplican a sus subcategorias) y "otros" (los demas;
 * si se usan en un producto, se agregan a la categoria al crearlo). null si no existe.
 */
export async function atributosDeCategoria(idCategoria) {
    const categoria = await m.Categoria.findByPk(idCategoria);
    if (!categoria) return null;
    const ids = [idCategoria, categoria.idCategoriaPadre].filter(Boolean);
    const definidos = new Set((await m.CategoriaAtributo.findAll({ where: { idCategoria: ids } })).map((x) => x.idAtributo));
    const todos = await m.Atributo.findAll({ include: [{ model: m.ValorAtributo, as: "valores" }], order: [["nombre", "ASC"]] });
    return {
        propios: todos.filter((a) => definidos.has(a.idAtributo)).map(planoAtributo),
        otros: todos.filter((a) => !definidos.has(a.idAtributo)).map(planoAtributo),
    };
}

/** Producto completo para editar: variantes, presentaciones, precio vigente, stock, ofertas y descuentos. */
export async function detalle(idProducto) {
    const p = await m.Producto.findByPk(idProducto, {
        include: [
            { model: m.Categoria, as: "categoria" },
            { model: m.Marca, as: "marca" },
            { model: m.UnidadMedida, as: "unidad" },
            { model: m.TarifaIva, as: "tarifaIva" },
            {
                model: m.Variante,
                as: "variantes",
                include: [
                    { model: m.VarianteValor, as: "valores", include: [{ model: m.ValorAtributo, as: "valor" }, { model: m.Atributo, as: "atributo" }] },
                    { model: m.Presentacion, as: "presentaciones" },
                ],
            },
        ],
        order: [
            [{ model: m.Variante, as: "variantes" }, "sku", "ASC"],
            [{ model: m.Variante, as: "variantes" }, { model: m.Presentacion, as: "presentaciones" }, "factor", "ASC"],
        ],
    });
    if (!p) return null;
    const idsPres = p.variantes.flatMap((v) => v.presentaciones.map((x) => x.idPresentacion));
    const idsVar = p.variantes.map((v) => v.idVariante);
    const bp = binds(enLista(idsPres), "p");
    const bv = binds(enLista(idsVar), "v");
    const precios = new Map(
        (await consulta(`SELECT id_presentacion, precio FROM produccion.v_precio_vigente WHERE id_presentacion IN (${bp.sql})`, bp.valores))
            .map((x) => [x.id_presentacion, x.precio])
    );
    const stock = new Map(
        (await consulta(
            `SELECT id_variante, stock_fisico, reservado, disponible, en_camino, requiere_compra
             FROM produccion.v_stock_variante WHERE id_variante IN (${bv.sql})`,
            bv.valores
        )).map((x) => [x.id_variante, x])
    );
    const ofertas = await consulta(
        `SELECT id_oferta, porcentaje, descripcion, desde, hasta, estado, lineas_vendidas
         FROM produccion.v_oferta WHERE prd_codigo = :codigo ORDER BY desde DESC`,
        { codigo: p.codigo }
    );
    const descuentos = await m.DescuentoVolumen.findAll({ where: { idProducto }, order: [["cantidadMinima", "ASC"]] });
    const atributos = (await atributosDeCategoria(p.idCategoria)).propios;

    return {
        id: p.idProducto,
        idProducto: p.idProducto,
        codigo: p.codigo,
        nombre: p.nombre,
        descripcion: p.descripcion,
        uso: p.uso,
        imagenUrl: p.imagenUrl,
        publicado: p.publicado === 1,
        ventaPorPieza: p.ventaPorPieza === 1,
        cortesEstandar: p.cortesEstandar === 1,
        precioPorVariante: p.precioPorVariante === 1,
        compraDescripcion: p.compraDescripcion ?? null,
        compraFactor: p.compraFactor ?? null,
        porcentajeIva: p.tarifaIva?.porcentaje ?? 0,
        fechaCreacion: p.fechaCreacion,
        idCategoria: p.idCategoria,
        categoria: p.categoria?.nombre,
        idMarca: p.idMarca,
        marca: p.marca?.nombre ?? null,
        idUnidadMedida: p.idUnidadMedida,
        unidad: p.unidad?.nombre,
        idTarifaIva: p.idTarifaIva,
        tarifaIva: p.tarifaIva ? `${p.tarifaIva.descripcion} (${p.tarifaIva.porcentaje} %)` : null,
        atributosDisponibles: atributos,
        variantes: p.variantes.map((v) => ({
            idVariante: v.idVariante,
            sku: v.sku,
            activa: v.activa === 1,
            stockMinimo: v.stockMinimo,
            caracteristicas: Object.fromEntries(v.valores.map((x) => [x.atributo.nombre, x.valor.valor])),
            stock: stock.get(v.idVariante) ?? { stock_fisico: 0, reservado: 0, disponible: 0, en_camino: 0, requiere_compra: 0 },
            presentaciones: v.presentaciones.map((x) => ({
                idPresentacion: x.idPresentacion,
                descripcion: x.descripcion,
                factor: x.factor,
                cantidadMinima: x.cantidadMinima,
                incremento: x.incremento,
                activa: x.activa === 1,
                precio: precios.get(x.idPresentacion) ?? null, // sin IVA (lo que guarda la base)
                precioConIva: conIva(precios.get(x.idPresentacion), p.tarifaIva?.porcentaje ?? 0),
            })),
        })),
        ofertas,
        proveedores: await proveedoresDe(idProducto),
        descuentosVolumen: descuentos.map((d) => ({
            idDescuentoVolumen: d.idDescuentoVolumen,
            cantidadMinima: d.cantidadMinima,
            porcentaje: d.porcentaje,
            activo: d.activo === 1,
        })),
    };
}

/**
 * Alta de un producto con su logica completa, en UNA transaccion:
 *   datos generales + variantes (combinaciones de valores de atributo) +
 *   presentaciones (las mismas formas de venta para cada variante) + precios.
 * Sin atributos se crea una sola variante. El SKU es CODIGO-01, -02...
 * El CODIGO lo genera el servidor (utils/codigos.js), y los precios llegan CON IVA.
 */
export function crear(datos, idUsuario) {
    return conUsuario(idUsuario, async (t) => {
        const producto = await m.Producto.create(
            {
                codigo: await codigoProducto(t, datos.idCategoria),
                nombre: datos.nombre,
                idCategoria: datos.idCategoria,
                idUnidadMedida: datos.idUnidadMedida,
                idTarifaIva: datos.idTarifaIva,
                idMarca: datos.idMarca ?? null,
                descripcion: datos.descripcion ?? null,
                uso: datos.uso ?? null,
                imagenUrl: datos.imagenUrl ?? null,
                publicado: datos.publicado ? 1 : 0,
                // cortes estandar (fibra en planchas) exige venta por pieza
                ventaPorPieza: datos.ventaPorPieza || datos.cortesEstandar ? 1 : 0,
                cortesEstandar: datos.cortesEstandar ? 1 : 0,
                precioPorVariante: datos.precioPorVariante ? 1 : 0,
                // como se compra: "Rollo × 30 m" (30) o piezas que se miden al recibir (factor vacio)
                compraDescripcion: datos.compraDescripcion || null,
                compraFactor: datos.compraDescripcion && datos.compraFactor ? datos.compraFactor : null,
            },
            { transaction: t }
        );
        // un producto se relaciona con al menos un proveedor (puede tener varios)
        for (const idProveedor of [...new Set(datos.idsProveedores ?? [])]) await vincularProveedor(t, producto.idProducto, idProveedor);
        await vincularAtributos(t, producto.idCategoria, datos.variantes ?? []);
        const presentaciones = [];
        for (const x of datos.presentaciones) {
            presentaciones.push({ ...x, precioBase: await baseDesdeConIva(t, producto.idProducto, x.precioConIva) });
        }
        const variantes = datos.variantes?.length ? datos.variantes : [{ valores: [], stockMinimo: 0 }];
        for (const [i, v] of variantes.entries()) {
            await crearVariante(t, producto, v, i + 1, presentaciones, idUsuario);
        }
        return producto.idProducto;
    });
}

/**
 * Los atributos que distinguen las variantes deben estar definidos para la
 * categoria (o su linea): la base lo exige con un disparador. Si el asistente
 * uso un atributo que la categoria aun no tenia, se le agrega aqui, en la
 * misma transaccion (el asistente lo avisa antes de crear).
 */
async function vincularAtributos(t, idCategoria, variantes) {
    const idsValor = [...new Set(variantes.flatMap((v) => v.valores ?? []))];
    if (idsValor.length === 0) return;
    const valores = await m.ValorAtributo.findAll({ where: { idValorAtributo: idsValor }, transaction: t });
    if (valores.length !== idsValor.length) throw new AppError("Algún valor de atributo no existe", 422);
    const idsAtributo = [...new Set(valores.map((v) => v.idAtributo))];
    const categoria = await m.Categoria.findByPk(idCategoria, { transaction: t });
    const definidos = new Set(
        (await m.CategoriaAtributo.findAll({
            where: { idCategoria: [idCategoria, categoria?.idCategoriaPadre].filter(Boolean) },
            transaction: t,
        })).map((x) => x.idAtributo)
    );
    for (const idAtributo of idsAtributo) {
        if (!definidos.has(idAtributo)) await m.CategoriaAtributo.create({ idCategoria, idAtributo }, { transaction: t });
    }
}

async function crearVariante(t, producto, v, numero, presentaciones, idUsuario) {
    const variante = await m.Variante.create(
        {
            idProducto: producto.idProducto,
            sku: v.sku ?? `${producto.codigo}-${String(numero).padStart(2, "0")}`,
            stockMinimo: v.stockMinimo ?? 0,
        },
        { transaction: t }
    );
    for (const idValorAtributo of v.valores ?? []) {
        const valor = await m.ValorAtributo.findByPk(idValorAtributo, { transaction: t });
        if (!valor) throw new AppError(`El valor de atributo ${idValorAtributo} no existe`, 422);
        await m.VarianteValor.create(
            { idVariante: variante.idVariante, idAtributo: valor.idAtributo, idValorAtributo },
            { transaction: t }
        );
    }
    for (const p of presentaciones) {
        const pres = await m.Presentacion.create(
            {
                idVariante: variante.idVariante,
                descripcion: p.descripcion,
                factor: p.factor,
                cantidadMinima: p.cantidadMinima ?? 1,
                incremento: p.incremento ?? 1,
            },
            { transaction: t }
        );
        await llamar(t, "fn_registrar_precio", { p_presentacion: pres.idPresentacion, p_precio: p.precioBase, p_usuario: idUsuario });
    }
    return variante;
}

/** Datos generales (no la unidad: el inventario ya esta en esa unidad). null si no existe. */
export function actualizar(idProducto, datos, idUsuario) {
    return conUsuario(idUsuario, async (transaction) => {
        const p = await m.Producto.findByPk(idProducto, { transaction });
        if (!p) return null;
        const cambios = { ...datos };
        for (const flag of ["publicado", "ventaPorPieza", "precioPorVariante"]) if (flag in cambios) cambios[flag] = cambios[flag] ? 1 : 0;
        if ("compraDescripcion" in cambios) {
            cambios.compraDescripcion = cambios.compraDescripcion || null;
            cambios.compraFactor = cambios.compraDescripcion ? cambios.compraFactor || null : null;
        }
        await p.update(cambios, { transaction });
        return idProducto;
    });
}

/** Nueva variante con las mismas formas de venta (y precios vigentes) que la primera variante activa. */
export function agregarVariante(idProducto, { valores, stockMinimo }, idUsuario) {
    return conUsuario(idUsuario, async (t) => {
        const producto = await m.Producto.findByPk(idProducto, { transaction: t });
        if (!producto) return null;
        const modelo = await m.Variante.findOne({
            where: { idProducto, activa: 1 },
            include: [{ model: m.Presentacion, as: "presentaciones", where: { activa: 1 }, required: false }],
            order: [["idVariante", "ASC"]],
            transaction: t,
        });
        const presentaciones = [];
        for (const x of modelo?.presentaciones ?? []) {
            const [vigente] = await consulta(
                "SELECT precio FROM produccion.v_precio_vigente WHERE id_presentacion = :p",
                { p: x.idPresentacion },
                t
            );
            presentaciones.push({ descripcion: x.descripcion, factor: x.factor, cantidadMinima: x.cantidadMinima, incremento: x.incremento, precioBase: vigente?.precio ?? 0 });
        }
        await vincularAtributos(t, producto.idCategoria, [{ valores }]);
        const total = await m.Variante.count({ where: { idProducto }, transaction: t });
        const v = await crearVariante(t, producto, { valores, stockMinimo }, total + 1, presentaciones, idUsuario);
        return v.idVariante;
    });
}

/** Activa/desactiva una variante o cambia su stock minimo. null si no existe. */
export function actualizarVariante(idVariante, datos, idUsuario) {
    return conUsuario(idUsuario, async (transaction) => {
        const v = await m.Variante.findByPk(idVariante, { transaction });
        if (!v) return null;
        const cambios = {};
        if (datos.activa !== undefined) cambios.activa = datos.activa ? 1 : 0;
        if (datos.stockMinimo !== undefined) cambios.stockMinimo = datos.stockMinimo;
        await v.update(cambios, { transaction });
        return v.idProducto;
    });
}

/** Nueva forma de venta para todas las variantes activas del producto, con su precio. */
export function agregarPresentacion(idProducto, p, idUsuario) {
    return conUsuario(idUsuario, async (t) => {
        const variantes = await m.Variante.findAll({ where: { idProducto, activa: 1 }, transaction: t });
        if (variantes.length === 0) return null;
        const base = await baseDesdeConIva(t, idProducto, p.precioConIva);
        for (const v of variantes) {
            const pres = await m.Presentacion.create(
                {
                    idVariante: v.idVariante,
                    descripcion: p.descripcion,
                    factor: p.factor,
                    cantidadMinima: p.cantidadMinima ?? 1,
                    incremento: p.incremento ?? 1,
                },
                { transaction: t }
            );
            await llamar(t, "fn_registrar_precio", { p_presentacion: pres.idPresentacion, p_precio: base, p_usuario: idUsuario });
        }
        return variantes.length;
    });
}

/** Activa/desactiva una forma de venta en todas las variantes, o cambia minimo/incremento. */
export function actualizarFormaDeVenta(idProducto, descripcion, datos, idUsuario) {
    return conUsuario(idUsuario, async (transaction) => {
        const ids = (await m.Variante.findAll({ where: { idProducto }, attributes: ["idVariante"], transaction })).map((v) => v.idVariante);
        const cambios = {};
        if (datos.activa !== undefined) cambios.activa = datos.activa ? 1 : 0;
        if (datos.cantidadMinima !== undefined) cambios.cantidadMinima = datos.cantidadMinima;
        if (datos.incremento !== undefined) cambios.incremento = datos.incremento;
        const [filas] = await m.Presentacion.update(cambios, { where: { idVariante: enLista(ids), descripcion }, transaction });
        return filas;
    });
}

/**
 * Precio nuevo de una forma de venta para TODAS las variantes del producto (o
 * una sola presentacion si se indica). Queda en el historial; el anterior no
 * se borra (historial_precio es inmutable).
 */
export function registrarPrecio(idProducto, { descripcion, idPresentacion, precioConIva }, idUsuario) {
    return conUsuario(idUsuario, async (t) => {
        let presentaciones;
        // un precio por variante solo si el producto lo permite; si no, vale para todas
        const producto = await m.Producto.findByPk(idProducto, { transaction: t });
        if (idPresentacion && producto?.precioPorVariante !== 1) {
            const x = await m.Presentacion.findByPk(idPresentacion, { transaction: t });
            descripcion = x?.descripcion ?? descripcion;
            idPresentacion = null;
        }
        if (idPresentacion) {
            presentaciones = await m.Presentacion.findAll({
                where: { idPresentacion },
                include: [{ model: m.Variante, as: "variante", where: { idProducto }, attributes: [] }],
                transaction: t,
            });
        } else {
            presentaciones = await m.Presentacion.findAll({
                where: { descripcion },
                include: [{ model: m.Variante, as: "variante", where: { idProducto }, attributes: [] }],
                transaction: t,
            });
        }
        const precio = await baseDesdeConIva(t, idProducto, precioConIva);
        for (const x of presentaciones) {
            await llamar(t, "fn_registrar_precio", { p_presentacion: x.idPresentacion, p_precio: precio, p_usuario: idUsuario });
        }
        return presentaciones.length;
    });
}

export async function historialPrecios(codigo) {
    return consulta(
        `SELECT h.var_sku, h.presentacion, h.precio, h.precio_con_iva, h.vigente_desde, h.vigente_hasta, h.vigente, h.registrado_por
         FROM produccion.v_historial_precio_venta h
         JOIN produccion.variante v ON v.var_sku = h.var_sku
         JOIN produccion.producto p ON p.id_producto = v.id_producto
         WHERE p.prd_codigo = :codigo
         ORDER BY h.vigente_desde DESC
         FETCH FIRST 200 ROWS ONLY`,
        { codigo }
    );
}

// ---------------------------------------------------------------- Ofertas
export function listarOfertas() {
    return consulta(
        `SELECT id_oferta, prd_codigo, prd_nombre, porcentaje, descripcion, desde, hasta, estado, lineas_vendidas, descuento_otorgado, registrada_por
         FROM produccion.v_oferta ORDER BY desde DESC FETCH FIRST 200 ROWS ONLY`
    );
}

export function crearOferta({ idProducto, porcentaje, desde, hasta, descripcion }, idUsuario) {
    return conUsuario(idUsuario, (t) =>
        llamar(t, "fn_registrar_oferta", {
            p_producto: idProducto,
            p_porcentaje: porcentaje,
            p_usuario: idUsuario,
            p_desde: desde ?? new Date(),
            p_hasta: hasta ?? null,
            p_descripcion: descripcion ?? null,
        })
    );
}

export function cambiarEstadoOferta(idOferta, { activa, hasta }, idUsuario) {
    return conUsuario(idUsuario, (t) =>
        procedimiento(t, "fn_cambiar_estado_oferta", {
            p_oferta: idOferta,
            p_activa: activa ? 1 : 0,
            p_usuario: idUsuario,
            p_hasta: hasta ?? null,
        })
    );
}

// ---------------------------------------------------------------- Combos
export async function listarCombos() {
    const combos = await m.Combo.findAll({
        include: [{ model: m.ComboComponente, as: "componentes", include: [{ model: m.Producto, as: "producto", attributes: ["codigo", "nombre"] }] }],
        order: [["codigo", "ASC"]],
    });
    return combos.map((c) => ({
        id: c.idCombo,
        idCombo: c.idCombo,
        codigo: c.codigo,
        nombre: c.nombre,
        descripcion: c.descripcion,
        publicado: c.publicado === 1,
        componentes: c.componentes.map((x) => ({
            idProducto: x.idProducto,
            producto: `${x.producto.codigo} · ${x.producto.nombre}`,
            presentacion: x.presentacion,
            cantidad: x.cantidad,
        })),
    }));
}

/** Crea o reemplaza un combo con sus componentes (producto + forma de venta + cantidad). */
export function guardarCombo(idCombo, { nombre, descripcion, publicado, componentes }, idUsuario) {
    return conUsuario(idUsuario, async (transaction) => {
        let combo;
        if (idCombo) {
            combo = await m.Combo.findByPk(idCombo, { transaction });
            if (!combo) return null;
            // el codigo no cambia nunca (se genero al crear)
            await combo.update({ nombre, descripcion: descripcion ?? null, publicado: publicado ? 1 : 0 }, { transaction });
            await m.ComboComponente.destroy({ where: { idCombo }, transaction });
        } else {
            combo = await m.Combo.create({ codigo: await codigoCombo(transaction), nombre, descripcion: descripcion ?? null, publicado: publicado ? 1 : 0 }, { transaction });
        }
        for (const x of componentes) {
            const existe = await m.Presentacion.count({
                where: { descripcion: x.presentacion, activa: 1 },
                include: [{ model: m.Variante, as: "variante", where: { idProducto: x.idProducto, activa: 1 }, attributes: [] }],
                transaction,
            });
            if (existe === 0) {
                throw new AppError(`El producto ${x.idProducto} no tiene la forma de venta "${x.presentacion}"`, 422);
            }
            await m.ComboComponente.create({ idCombo: combo.idCombo, idProducto: x.idProducto, presentacion: x.presentacion, cantidad: x.cantidad }, { transaction });
        }
        return combo.idCombo;
    });
}

export function eliminarCombo(idCombo, idUsuario) {
    return conUsuario(idUsuario, async (transaction) => {
        await m.ComboComponente.destroy({ where: { idCombo }, transaction });
        return (await m.Combo.destroy({ where: { idCombo }, transaction })) > 0;
    });
}

// ------------------------------------------------------------------ Proveedores del producto
/** Proveedores de un producto (un producto puede tener varios). */
export async function proveedoresDe(idProducto, transaction) {
    const filas = await consulta(
        `SELECT pv.id_proveedor, NVL(pv.prv_nombre_comercial, pv.prv_razon_social) AS nombre,
                pv.prv_razon_social, pp.ppv_codigo_proveedor, pv.prv_activo
         FROM ${ESQUEMA}.producto_proveedor pp
         JOIN ${ESQUEMA}.proveedor pv ON pv.id_proveedor = pp.id_proveedor
         WHERE pp.id_producto = :p ORDER BY nombre`,
        { p: idProducto },
        transaction
    );
    return filas.map((f) => ({ idProveedor: f.id_proveedor, nombre: f.nombre, razonSocial: f.prv_razon_social, codigoProveedor: f.ppv_codigo_proveedor, activo: f.prv_activo === 1 }));
}

async function vincularProveedor(t, idProducto, idProveedor, codigoProveedor = null) {
    const existe = await m.ProductoProveedor.findOne({ where: { idProducto, idProveedor }, transaction: t });
    if (existe) {
        if (codigoProveedor !== undefined) await existe.update({ codigoProveedor: codigoProveedor || null }, { transaction: t });
        return;
    }
    await m.ProductoProveedor.create({ idProducto, idProveedor, codigoProveedor: codigoProveedor || null }, { transaction: t });
}

export function agregarProveedor(idProducto, { idProveedor, codigoProveedor }, idUsuario) {
    return conUsuario(idUsuario, async (t) => {
        if (!(await m.Producto.findByPk(idProducto, { transaction: t }))) return null;
        await vincularProveedor(t, idProducto, idProveedor, codigoProveedor);
        return proveedoresDe(idProducto, t);
    });
}

/** Quita un proveedor; el producto debe quedar con al menos uno. */
export function quitarProveedor(idProducto, idProveedor, idUsuario) {
    return conUsuario(idUsuario, async (t) => {
        const total = await m.ProductoProveedor.count({ where: { idProducto }, transaction: t });
        if (total <= 1) throw new AppError("El producto debe tener al menos un proveedor: agrega otro antes de quitar este", 409);
        const n = await m.ProductoProveedor.destroy({ where: { idProducto, idProveedor }, transaction: t });
        if (!n) return null;
        return proveedoresDe(idProducto, t);
    });
}
