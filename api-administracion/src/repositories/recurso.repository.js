// src/repositories/recurso.repository.js
// Repository GENERICO de los recursos del registro: listar con busqueda,
// filtros y paginacion; obtener; crear; actualizar; eliminar. Toda escritura
// va en una transaccion a nombre del usuario (auditoria de la base).
import { Op, Sequelize } from "sequelize";
import { conUsuario } from "../config/db.js";
import { RECURSO_POR_RUTA } from "../recursos/registro.js";

/** Atributos de un recurso que se devuelven (los del registro + la clave). */
function atributos(recurso) {
    const nombres = new Set([recurso.pk, ...recurso.campos.map((c) => c.nombre)]);
    return [...nombres].filter((n) => recurso.modelo.rawAttributes[n]);
}

export function aPlano(recurso, fila) {
    if (!fila) return null;
    const datos = fila.get({ plain: true });
    return { ...datos, id: datos[recurso.pk], etiqueta: recurso.etiqueta(datos) };
}

/**
 * Orden pedido: una columna propia del recurso, o una clave foranea ordenada
 * por el NOMBRE de lo que apunta (la provincia de una ciudad por su nombre,
 * no por su id). Nombres de tabla y columna salen de los modelos, nunca del
 * cliente. Si no, el orden del registro.
 */
function ordenDe(recurso, orden, dir) {
    const sentido = dir === "desc" ? "DESC" : "ASC";
    const campo = recurso.campos.find((c) => c.nombre === orden);
    if (campo?.tipo === "seleccion") {
        const destino = RECURSO_POR_RUTA.get(campo.recurso);
        const col = destino?.buscar?.[0];
        const attrFk = recurso.modelo.rawAttributes[orden];
        if (!destino || !col || !attrFk) return recurso.orden;
        const d = destino.modelo;
        const sql = `(SELECT x.${d.rawAttributes[col].field} FROM produccion.${d.tableName} x
                      WHERE x.${d.rawAttributes[destino.pk].field} = "${recurso.modelo.name}"."${attrFk.field}")`;
        return [[Sequelize.literal(sql), `${sentido} NULLS LAST`], [recurso.pk, "ASC"]];
    }
    const valido = (campo && recurso.modelo.rawAttributes[orden]) || orden === recurso.pk;
    if (!valido) return recurso.orden;
    return [[orden, sentido], [recurso.pk, "ASC"]];
}

export async function listar(recurso, { q = null, filtros = {}, limit, offset, orden, dir }) {
    const where = { ...filtros };
    if (q && recurso.buscar?.length) {
        // INSTR(LOWER(columna), texto) > 0: busqueda sin distinguir mayusculas y
        // sin comodines (un % o _ del usuario es texto). El valor va escapado
        // por Sequelize, nunca concatenado.
        const texto = q.toLowerCase();
        where[Op.or] = recurso.buscar.map((campo) =>
            Sequelize.where(
                Sequelize.fn("INSTR", Sequelize.fn("LOWER", Sequelize.col(recurso.modelo.rawAttributes[campo].field)), texto),
                Op.gt,
                0
            )
        );
    }
    const { rows, count } = await recurso.modelo.findAndCountAll({
        attributes: atributos(recurso),
        where,
        order: ordenDe(recurso, orden, dir),
        limit,
        offset,
    });
    return { filas: rows.map((f) => aPlano(recurso, f)), total: count };
}

export async function obtener(recurso, id) {
    return aPlano(recurso, await recurso.modelo.findByPk(id, { attributes: atributos(recurso) }));
}

/** Opciones para un <select>: [{ valor, etiqueta }], filtrables por los filtros del recurso. */
export async function opciones(recurso, { filtros = {}, limite = 500 } = {}) {
    const filas = await recurso.modelo.findAll({ where: filtros, order: recurso.orden, limit: limite });
    return filas.map((f) => {
        const d = f.get({ plain: true });
        return { valor: d[recurso.pk], etiqueta: recurso.etiqueta(d) };
    });
}

export function crear(recurso, datos, idUsuario) {
    return conUsuario(idUsuario, async (transaction) => {
        let valores = recurso.asignarUsuario ? { ...datos, [recurso.asignarUsuario]: idUsuario } : datos;
        // campos automaticos (codigos): los calcula el recurso dentro de la transaccion
        if (recurso.alCrear) valores = await recurso.alCrear(valores, transaction);
        const fila = await recurso.modelo.create(valores, { transaction });
        return aPlano(recurso, await recurso.modelo.findByPk(fila[recurso.pk], { attributes: atributos(recurso), transaction }));
    });
}

/** null si no existe. */
export function actualizar(recurso, id, datos, idUsuario) {
    return conUsuario(idUsuario, async (transaction) => {
        const fila = await recurso.modelo.findByPk(id, { transaction });
        if (!fila) return null;
        await fila.update(datos, { transaction });
        return aPlano(recurso, await recurso.modelo.findByPk(id, { attributes: atributos(recurso), transaction }));
    });
}

/** false si no existe. Si esta en uso, la base responde ORA-02292 (409 con mensaje claro). */
export function eliminar(recurso, id, idUsuario) {
    return conUsuario(idUsuario, async (transaction) => {
        const fila = await recurso.modelo.findByPk(id, { transaction });
        if (!fila) return false;
        await fila.destroy({ transaction });
        return true;
    });
}
