// src/repositories/cotizacion.repository.js
// Cotizaciones (ventas por confirmar) que llegan de la tienda. No reservan
// stock. El personal las edita y las CONFIRMA (fn_confirmar_cotizacion crea el
// pedido y reserva el stock; si falta, la base dice que falta) o vencen a los
// 14 dias (un job de la base las elimina).
import { conUsuario, consulta, ESQUEMA, llamar } from "../config/db.js";
import { AppError } from "../utils/AppError.js";

const numero = (id) => `COT-${String(id).padStart(6, "0")}`;
// INSERT / UPDATE / DELETE dentro de la transaccion (consulta() es para SELECT)
const ejecutar = (t, sql, binds) => t.connection.execute(sql, binds);

/** Pendientes primero (las que vencen antes), luego las confirmadas recientes. */
export async function listar({ estado = "PENDIENTE", q = null, limit, offset }) {
    const binds = { estado, offset, limit };
    let filtro = "co.cot_estado = :estado";
    if (q) {
        filtro += " AND (INSTR(LOWER(c.cli_nombres || ' ' || c.cli_apellidos), :q) > 0 OR TO_CHAR(co.id_cotizacion) = LTRIM(REPLACE(UPPER(:q), 'COT-'), '0'))";
        binds.q = q.toLowerCase();
    }
    const desde = `FROM ${ESQUEMA}.cotizacion co JOIN ${ESQUEMA}.cliente c ON c.id_cliente = co.id_cliente WHERE ${filtro}`;
    const { offset: _o, limit: _l, ...bindsTotal } = binds;
    const [{ total }] = await consulta(`SELECT COUNT(*) AS total ${desde}`, bindsTotal);
    const filas = await consulta(
        `SELECT co.id_cotizacion, co.cot_fecha AS fecha, co.cot_vence AS vence, co.cot_estado AS estado, co.id_pedido,
                co.id_canal_venta AS canal, c.cli_nombres || NVL2(c.cli_apellidos, ' ' || c.cli_apellidos, '') AS cliente,
                (SELECT COUNT(*) FROM ${ESQUEMA}.cotizacion_linea l WHERE l.id_cotizacion = co.id_cotizacion) AS lineas,
                (SELECT SUM(l.col_cantidad * NVL(ca.precio_final_con_iva, 0)) FROM ${ESQUEMA}.cotizacion_linea l
                 LEFT JOIN ${ESQUEMA}.v_catalogo ca ON ca.id_presentacion = l.id_presentacion
                 WHERE l.id_cotizacion = co.id_cotizacion) AS total_estimado
         ${desde}
         ORDER BY ${estado === "PENDIENTE" ? "co.cot_vence ASC" : "co.cot_confirmada DESC"}, co.id_cotizacion DESC
         OFFSET :offset ROWS FETCH NEXT :limit ROWS ONLY`,
        binds
    );
    return { filas: filas.map((f) => ({ ...f, id: f.id_cotizacion, numero: numero(f.id_cotizacion) })), total };
}

/** Cotizacion con sus lineas, precio actual con IVA y disponible de cada una. */
export async function detalle(idCotizacion) {
    const [co] = await consulta(
        `SELECT co.id_cotizacion, co.id_cliente, co.cot_fecha AS fecha, co.cot_vence AS vence, co.cot_estado AS estado,
                co.id_pedido, co.cot_observacion AS observacion, co.id_canal_venta AS canal,
                c.cli_nombres || NVL2(c.cli_apellidos, ' ' || c.cli_apellidos, '') AS cliente, c.cli_correo AS correo,
                (SELECT MIN(t.tel_numero) FROM ${ESQUEMA}.telefono t WHERE t.id_cliente = c.id_cliente) AS telefono
         FROM ${ESQUEMA}.cotizacion co JOIN ${ESQUEMA}.cliente c ON c.id_cliente = co.id_cliente
         WHERE co.id_cotizacion = :id`,
        { id: idCotizacion }
    );
    if (!co) return null;
    const lineas = await consulta(
        `SELECT l.id_cotizacion_linea, l.id_presentacion, l.col_cantidad AS cantidad, l.id_lote,
                p.prd_codigo, p.prd_nombre, v.var_sku, pr.pre_descripcion AS presentacion, pr.pre_incremento AS incremento,
                pr.pre_cantidad_minima AS cantidad_minima, p.id_unidad_medida AS unidad,
                ca.precio_final_con_iva AS precio, ca.disponible, lo.lot_codigo_proveedor AS pieza
         FROM ${ESQUEMA}.cotizacion_linea l
         JOIN ${ESQUEMA}.presentacion pr ON pr.id_presentacion = l.id_presentacion
         JOIN ${ESQUEMA}.variante v ON v.id_variante = pr.id_variante
         JOIN ${ESQUEMA}.producto p ON p.id_producto = v.id_producto
         LEFT JOIN ${ESQUEMA}.v_catalogo ca ON ca.id_presentacion = l.id_presentacion
         LEFT JOIN ${ESQUEMA}.lote lo ON lo.id_lote = l.id_lote
         WHERE l.id_cotizacion = :id
         ORDER BY l.id_cotizacion_linea`,
        { id: idCotizacion }
    );
    const conPrecio = lineas.map((l) => ({ ...l, subtotal: l.precio != null ? Math.round(l.precio * l.cantidad * 100) / 100 : null, falta: l.disponible != null && l.cantidad > l.disponible }));
    return {
        ...co,
        id: co.id_cotizacion,
        numero: numero(co.id_cotizacion),
        lineas: conPrecio,
        totalEstimado: Math.round(conPrecio.reduce((s, l) => s + (l.subtotal ?? 0), 0) * 100) / 100,
        editable: co.estado === "PENDIENTE",
    };
}

async function pendiente(t, idCotizacion) {
    const [co] = await consulta(`SELECT cot_estado FROM ${ESQUEMA}.cotizacion WHERE id_cotizacion = :id FOR UPDATE`, { id: idCotizacion }, t);
    if (!co) return false;
    if (co.cot_estado !== "PENDIENTE") throw new AppError("La cotización ya se confirmó como pedido: no se puede modificar", 409);
    return true;
}

export function cambiarCantidad(idCotizacion, idLinea, cantidad, idUsuario) {
    return conUsuario(idUsuario, async (t) => {
        if (!(await pendiente(t, idCotizacion))) return null;
        await ejecutar(t, `UPDATE ${ESQUEMA}.cotizacion_linea SET col_cantidad = :cantidad WHERE id_cotizacion_linea = :linea AND id_cotizacion = :id`,
            { cantidad, linea: idLinea, id: idCotizacion });
        return true;
    }).then((ok) => (ok ? detalle(idCotizacion) : null));
}

export function quitarLinea(idCotizacion, idLinea, idUsuario) {
    return conUsuario(idUsuario, async (t) => {
        if (!(await pendiente(t, idCotizacion))) return null;
        const [{ n }] = await consulta(`SELECT COUNT(*) AS n FROM ${ESQUEMA}.cotizacion_linea WHERE id_cotizacion = :id`, { id: idCotizacion }, t);
        if (n <= 1) throw new AppError("Es el último producto: si ya no se quiere, descarta la cotización", 409);
        await ejecutar(t, `DELETE FROM ${ESQUEMA}.cotizacion_linea WHERE id_cotizacion_linea = :linea AND id_cotizacion = :id`, { linea: idLinea, id: idCotizacion });
        return true;
    }).then((ok) => (ok ? detalle(idCotizacion) : null));
}

export function agregarLinea(idCotizacion, { idPresentacion, cantidad }, idUsuario) {
    return conUsuario(idUsuario, async (t) => {
        if (!(await pendiente(t, idCotizacion))) return null;
        const [pr] = await consulta(`SELECT pre_activa FROM ${ESQUEMA}.presentacion WHERE id_presentacion = :p`, { p: idPresentacion }, t);
        if (!pr || pr.pre_activa !== 1) throw new AppError("Esa forma de venta no existe o ya no se ofrece", 422, [{ campo: "idPresentacion", mensaje: "Elige una forma de venta activa" }]);
        await ejecutar(t, `INSERT INTO ${ESQUEMA}.cotizacion_linea (id_cotizacion, id_presentacion, col_cantidad) VALUES (:id, :p, :cantidad)`,
            { id: idCotizacion, p: idPresentacion, cantidad });
        return true;
    }).then((ok) => (ok ? detalle(idCotizacion) : null));
}

/** Confirma: la base crea el pedido (valida y reserva el stock). Devuelve el id del pedido. */
export function confirmar(idCotizacion, idUsuario) {
    return conUsuario(idUsuario, (t) => llamar(t, "fn_confirmar_cotizacion", { p_cotizacion: idCotizacion, p_usuario: idUsuario, p_vendedor: idUsuario }));
}

/** Descarta una cotizacion pendiente (el cliente ya no la quiere). */
export function descartar(idCotizacion, idUsuario) {
    return conUsuario(idUsuario, async (t) => {
        if (!(await pendiente(t, idCotizacion))) return false;
        await ejecutar(t, `DELETE FROM ${ESQUEMA}.cotizacion WHERE id_cotizacion = :id`, { id: idCotizacion });
        return true;
    });
}
