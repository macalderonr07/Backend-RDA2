// src/middlewares/autenticacion.js
// Autenticacion con JWT (Authorization: Bearer <token>) y autorizacion por
// permisos del modelo de la base (rol -> permiso). La API sigue siendo sin
// estado: el token solo dice QUIEN es; en cada peticion se recargan de la base
// el usuario y sus permisos, asi un usuario desactivado o al que se le quita un
// rol pierde el acceso de inmediato, sin esperar a que venza el token.
// Doble barrera: la base vuelve a exigir el permiso en cada funcion de negocio
// (fn_exigir_permiso), aunque un endpoint olvidara pedirlo.
import jwt from "jsonwebtoken";
import { config } from "../config/env.js";
import { perfil } from "../repositories/auth.repository.js";
import { AppError } from "../utils/AppError.js";

export function emitirToken(usuario) {
    return jwt.sign({ sub: String(usuario.idUsuario), correo: usuario.correo, hc: usuario.huellaClave }, config.jwt.secreto, {
        expiresIn: config.jwt.duracion,
        algorithm: "HS256",
    });
}

export async function autenticar(req, _res, next) {
    try {
        const cabecera = req.get("authorization") ?? "";
        const [esquema, token] = cabecera.split(" ");
        if (esquema !== "Bearer" || !token) throw new AppError("Inicia sesión para continuar", 401);
        let datos;
        try {
            datos = jwt.verify(token, config.jwt.secreto, { algorithms: ["HS256"] });
        } catch (e) {
            throw new AppError(
                e.name === "TokenExpiredError" ? "Tu sesión venció: vuelve a iniciar sesión" : "Sesión no válida",
                401
            );
        }
        const usuario = await perfil(Number(datos.sub));
        if (!usuario) throw new AppError("Tu usuario está desactivado o ya no existe", 401);
        // la clave cambio despues de emitir este token: la sesion ya no vale
        if (datos.hc !== usuario.huellaClave) throw new AppError("Tu clave cambió: vuelve a iniciar sesión", 401);
        req.usuario = usuario;
        next();
    } catch (err) {
        next(err);
    }
}

/** Exige al menos UNO de los permisos indicados (codigos de produccion.permiso). */
export function exigirPermiso(...permisos) {
    return (req, _res, next) => {
        const tiene = req.usuario?.permisos ?? [];
        if (permisos.some((p) => tiene.includes(p))) return next();
        next(new AppError(`No tienes permiso para esta acción (requiere ${permisos.join(" o ")})`, 403));
    };
}
