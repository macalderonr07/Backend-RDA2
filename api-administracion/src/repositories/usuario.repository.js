// src/repositories/usuario.repository.js
// Usuarios internos, sus roles y la relacion con la ficha de empleado. El hash
// de la clave nunca sale de este archivo.
import { Op } from "sequelize";
import { conUsuario, consulta } from "../config/db.js";
import { m } from "../models/index.js";

// Usuarios tecnicos de la base (sin clave utilizable): no se administran aqui
const TECNICO = { [Op.notLike]: "%@comercialelite.local" };

function aPlano(u) {
    return {
        idUsuario: u.idUsuario,
        id: u.idUsuario,
        correo: u.correo,
        activo: u.activo === 1,
        creado: u.creado,
        ultimoAcceso: u.ultimoAcceso,
        roles: (u.roles ?? []).map((r) => ({ codigo: r.codigo, nombre: r.nombre })),
        empleado: u.empleado ? `${u.empleado.nombres} ${u.empleado.apellidos}` : null,
    };
}

const INCLUIR = [
    { model: m.Rol, as: "roles", through: { attributes: [] } },
    { model: m.Empleado, as: "empleado" },
];

const ORDEN_USUARIOS = { correo: "correo", ultimoAcceso: "ultimoAcceso", activo: "activo" };

export async function listar({ q = null, limit, offset, orden, dir }) {
    if (orden === "roles") return listarPorRol({ q, limit, offset, dir });
    const where = { correo: q ? { [Op.and]: [TECNICO, { [Op.like]: `%${q.toLowerCase().replace(/[%_]/g, "")}%` }] } : TECNICO };
    const { rows, count } = await m.Usuario.findAndCountAll({
        where,
        include: INCLUIR,
        // lista blanca: una clave desconocida ordena por correo
        order: [
            orden === "empleado"
                ? [{ model: m.Empleado, as: "empleado" }, "nombres", `${dir === "desc" ? "DESC" : "ASC"} NULLS LAST`]

                : [ORDEN_USUARIOS[orden] ?? "correo", ORDEN_USUARIOS[orden] && dir === "desc" ? "DESC" : "ASC"],
            ["idUsuario", "ASC"],
        ],
        limit,
        offset,
        distinct: true,
    });
    return { filas: rows.map(aPlano), total: count };
}

export async function obtener(idUsuario) {
    const u = await m.Usuario.findOne({ where: { idUsuario, correo: TECNICO }, include: INCLUIR });
    return u ? aPlano(u) : null;
}

export async function rolesYPermisos() {
    const roles = await m.Rol.findAll({
        include: [{ model: m.Permiso, as: "permisos", through: { attributes: [] } }],
        order: [["codigo", "ASC"]],
    });
    return roles.map((r) => ({
        codigo: r.codigo,
        nombre: r.nombre,
        protegido: ROLES_PROTEGIDOS.has(r.codigo),
        permisos: r.permisos.map((p) => ({ codigo: p.codigo, descripcion: p.descripcion })),
    }));
}

async function asignarRoles(idUsuario, codigos, transaction) {
    const roles = await m.Rol.findAll({ where: { codigo: codigos }, transaction });
    if (roles.length !== new Set(codigos).size) return false;
    await m.UsuarioRol.destroy({ where: { idUsuario }, transaction });
    for (const r of roles) await m.UsuarioRol.create({ idUsuario, idRol: r.idRol }, { transaction });
    return true;
}

/** "José María", "Pérez Núñez" -> "joperez" (dos letras del primer nombre + primer apellido, sin tildes). */
export function usuarioEstandar(nombres, apellidos) {
    const limpio = (s) => String(s ?? "").normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/[^a-z\s]/g, "").trim().split(/\s+/).filter(Boolean);
    const n = limpio(nombres)[0] ?? "";
    const a = limpio(apellidos)[0] ?? "";
    return `${n.slice(0, 2)}${a}`;
}

/** Correo estandar libre: joperez@..., si ya existe joperez2@..., joperez3@... */
export async function correoEstandar(nombres, apellidos, transaction) {
    const base = usuarioEstandar(nombres, apellidos);
    if (base.length < 3) return null;
    for (let i = 1; i < 100; i++) {
        const correo = `${base}${i === 1 ? "" : i}@${DOMINIO}`;
        if (!(await m.Usuario.count({ where: { correo }, transaction }))) return correo;
    }
    return null;
}
export const DOMINIO = "comercialelite.ec";

/**
 * Alta de usuario con su ficha de empleado (el empleado se identifica por el
 * mismo id del usuario). El correo NO lo escribe nadie: sigue el estandar
 * (2 letras del nombre + primer apellido). { usuario } o { error }.
 */
export function crear({ nombres, apellidos, idTipoIdentificacion, identificacion, fechaIngreso, hashClave, roles, activo = 1 }, idAutor) {
    return conUsuario(idAutor, async (transaction) => {
        const correo = await correoEstandar(nombres, apellidos, transaction);
        if (!correo) return { error: "El nombre y el apellido deben tener letras para formar el usuario" };
        const u = await m.Usuario.create({ correo, hashClave, activo }, { transaction });
        if (!(await asignarRoles(u.idUsuario, roles, transaction))) return { error: "Rol desconocido" };
        await m.Empleado.create(
            { idUsuario: u.idUsuario, idTipoIdentificacion, identificacion, nombres, apellidos, fechaIngreso: fechaIngreso ?? new Date() },
            { transaction }
        );
        return { usuario: aPlano(await m.Usuario.findByPk(u.idUsuario, { include: INCLUIR, transaction })) };
    });
}

// ------------------------------------------------------------------ Roles y permisos (editables)
const ROLES_PROTEGIDOS = new Set(["SISTEMA"]); // usuario tecnico de la base: no se toca

export async function permisos() {
    const filas = await m.Permiso.findAll({ order: [["codigo", "ASC"]] });
    return filas.map((p) => ({ codigo: p.codigo, descripcion: p.descripcion }));
}

/** "Cajero de tienda" -> "CAJERO_DE_TIENDA" (20 caracteres max.), sin repetir. */
async function codigoRol(nombre, transaction) {
    const base = String(nombre).normalize("NFD").replace(/[̀-ͯ]/g, "").toUpperCase().replace(/[^A-Z]+/g, "_").replace(/^_|_$/g, "").slice(0, 18) || "ROL";
    for (let i = 1; i < 50; i++) {
        const codigo = i === 1 ? base : `${base.slice(0, 17)}_${i}`;
        if (!(await m.Rol.count({ where: { codigo }, transaction }))) return codigo;
    }
    return null;
}

async function fijarPermisos(rol, codigos, transaction) {
    const lista = await m.Permiso.findAll({ where: { codigo: codigos }, transaction });
    if (lista.length !== new Set(codigos).size) return "Hay un permiso desconocido";
    await m.RolPermiso.destroy({ where: { idRol: rol.idRol }, transaction });
    for (const p of lista) await m.RolPermiso.create({ idRol: rol.idRol, idPermiso: p.idPermiso }, { transaction });
    return null;
}

export function crearRol({ nombre, permisos: codigos }, idAutor) {
    return conUsuario(idAutor, async (transaction) => {
        const codigo = await codigoRol(nombre, transaction);
        const rol = await m.Rol.create({ codigo, nombre }, { transaction });
        const error = await fijarPermisos(rol, codigos, transaction);
        return error ? { error } : { codigo };
    });
}

/** null si no existe; { error } si no se puede. */
export function actualizarRol(codigo, { nombre, permisos: codigos }, idAutor) {
    return conUsuario(idAutor, async (transaction) => {
        const rol = await m.Rol.findOne({ where: { codigo }, transaction });
        if (!rol) return null;
        if (ROLES_PROTEGIDOS.has(codigo)) return { error: "El rol SISTEMA es el usuario técnico de la base: no se modifica" };
        // nadie se queda sin poder administrar usuarios: ADMIN conserva USUARIO_GESTIONAR
        if (codigo === "ADMIN" && codigos && !codigos.includes("USUARIO_GESTIONAR")) {
            return { error: "El rol ADMIN debe conservar el permiso para gestionar usuarios (si no, nadie podría corregirlo)" };
        }
        if (nombre) await rol.update({ nombre }, { transaction });
        if (codigos) {
            const error = await fijarPermisos(rol, codigos, transaction);
            if (error) return { error };
        }
        return { codigo };
    });
}

export function eliminarRol(codigo, idAutor) {
    return conUsuario(idAutor, async (transaction) => {
        const rol = await m.Rol.findOne({ where: { codigo }, transaction });
        if (!rol) return null;
        if (ROLES_PROTEGIDOS.has(codigo) || codigo === "ADMIN") return { error: `El rol ${codigo} no se puede eliminar` };
        const enUso = await m.UsuarioRol.count({ where: { idRol: rol.idRol }, transaction });
        if (enUso) return { error: `El rol lo tienen ${enUso} usuario(s): quítaselo antes de eliminarlo` };
        await m.RolPermiso.destroy({ where: { idRol: rol.idRol }, transaction });
        await rol.destroy({ transaction });
        return { codigo };
    });
}

/** Cambia activo y/o roles. null si no existe; { error } si no se puede. */
export function actualizar(idUsuario, { activo, roles }, idAutor) {
    return conUsuario(idAutor, async (transaction) => {
        const u = await m.Usuario.findOne({ where: { idUsuario, correo: TECNICO }, transaction });
        if (!u) return null;
        if (activo !== undefined) await u.update({ activo }, { transaction });
        if (roles !== undefined && !(await asignarRoles(idUsuario, roles, transaction))) {
            return { error: "Rol desconocido" };
        }
        return { usuario: aPlano(await m.Usuario.findByPk(idUsuario, { include: INCLUIR, transaction })) };
    });
}

export function restablecerClave(idUsuario, hashClave, idAutor) {
    return conUsuario(idAutor, async (transaction) => {
        const [filas] = await m.Usuario.update({ hashClave }, { where: { idUsuario, correo: TECNICO }, transaction });
        return filas > 0;
    });
}

/**
 * Orden por ROL (un usuario puede tener varios: se usa el primero por nombre).
 * Sequelize pagina con una subconsulta cuando hay roles incluidos, asi que la
 * pagina de ids se pide con SQL propio y despues se cargan esos usuarios.
 */
async function listarPorRol({ q, limit, offset, dir }) {
    const filtro = q ? "AND INSTR(LOWER(u.usu_correo), :q) > 0" : "";
    const binds = q ? { q: q.toLowerCase() } : {};
    const [{ total }] = await consulta(
        `SELECT COUNT(*) AS total FROM produccion.usuario u WHERE u.usu_correo NOT LIKE '%@comercialelite.local' ${filtro}`, binds);
    const ids = (await consulta(
        `SELECT u.id_usuario FROM produccion.usuario u
         WHERE u.usu_correo NOT LIKE '%@comercialelite.local' ${filtro}
         ORDER BY (SELECT MIN(r.rol_nombre) FROM produccion.usuario_rol ur JOIN produccion.rol r ON r.id_rol = ur.id_rol
                   WHERE ur.id_usuario = u.id_usuario) ${dir === "desc" ? "DESC" : "ASC"} NULLS LAST, u.id_usuario
         OFFSET :offset ROWS FETCH NEXT :limit ROWS ONLY`,
        { ...binds, offset, limit }
    )).map((f) => f.id_usuario);
    const filas = await m.Usuario.findAll({ where: { idUsuario: ids.length ? ids : [-1] }, include: INCLUIR });
    filas.sort((a, b) => ids.indexOf(a.idUsuario) - ids.indexOf(b.idUsuario));
    return { filas: filas.map(aPlano), total };
}
