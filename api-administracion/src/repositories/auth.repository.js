// src/repositories/auth.repository.js
// Repository de seguridad: usuarios internos (produccion.usuario), sus roles y
// los permisos que esos roles otorgan. La clave nunca sale de aqui: solo el
// hash, para que el controlador la verifique.
import { createHash } from "node:crypto";
import { conUsuario, consulta, llamar, sequelize } from "../config/db.js";
import { m } from "../models/index.js";

/** Usuario por correo, con el hash (para verificar la clave). null si no existe. */
export async function usuarioParaIngreso(correo) {
    const u = await m.Usuario.findOne({ where: { correo } });
    return u ? { idUsuario: u.idUsuario, correo: u.correo, activo: u.activo === 1, hashClave: u.hashClave } : null;
}

/** Usuario activo con roles, permisos y ficha de empleado (si la tiene). null si no existe o esta inactivo. */
export async function perfil(idUsuario) {
    const u = await m.Usuario.findOne({
        where: { idUsuario, activo: 1 },
        include: [
            { model: m.Rol, as: "roles", through: { attributes: [] } },
            { model: m.Empleado, as: "empleado" },
        ],
    });
    if (!u) return null;
    const permisos = await consulta(
        `SELECT DISTINCT p.per_codigo AS codigo
         FROM produccion.usuario_rol ur
         JOIN produccion.rol_permiso rp ON rp.id_rol = ur.id_rol
         JOIN produccion.permiso p      ON p.id_permiso = rp.id_permiso
         WHERE ur.id_usuario = :usuario
         ORDER BY 1`,
        { usuario: idUsuario }
    );
    const datos = {
        idUsuario: u.idUsuario,
        correo: u.correo,
        nombre: u.empleado ? `${u.empleado.nombres} ${u.empleado.apellidos}` : u.correo,
        esEmpleado: Boolean(u.empleado),
        roles: u.roles.map((r) => ({ codigo: r.codigo, nombre: r.nombre })),
        permisos: permisos.map((p) => p.codigo),
        ultimoAcceso: u.ultimoAcceso,
    };
    // Huella de la clave vigente (no la clave ni el hash): va en el token y se
    // compara en cada peticion. Al cambiar la clave cambia la huella y TODAS las
    // sesiones abiertas (otro equipo, un token robado) dejan de valer.
    // No enumerable: nunca viaja en una respuesta JSON.
    Object.defineProperty(datos, "huellaClave", {
        value: createHash("sha256").update(String(u.hashClave)).digest("base64url").slice(0, 22),
        enumerable: false,
    });
    return datos;
}

/**
 * Bitacora de acceso de la base (fn_registrar_acceso: LOGIN_OK / LOGIN_FALLIDO
 * / LOGIN_BLOQUEADO en log_evento y ultimo acceso). Devuelve el id si fue
 * exitoso. Hace DML: va en su propia transaccion.
 */
export function registrarAcceso(correo, exito, ip) {
    return sequelize.transaction((t) =>
        llamar(t, "fn_registrar_acceso", { p_correo: correo, p_exito: exito ? 1 : 0, p_ip: ip ?? null })
    );
}

/** Cambio de la propia clave (el hash lo calcula el controlador). */
export function cambiarClave(idUsuario, hashClave) {
    return conUsuario(idUsuario, (transaction) =>
        m.Usuario.update({ hashClave }, { where: { idUsuario }, transaction })
    );
}
