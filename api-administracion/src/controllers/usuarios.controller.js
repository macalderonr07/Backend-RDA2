// src/controllers/usuarios.controller.js
import { matchedData } from "express-validator";
import { RespuestaFactory } from "../factories/respuesta.factory.js";
import * as repo from "../repositories/usuario.repository.js";
import { AppError } from "../utils/AppError.js";
import { crearHashClave } from "../utils/clave.js";

const noExiste = (id) => new AppError(`No existe el usuario ${id}`, 404);

export async function listar(req, res, next) {
    try {
        const { q = null } = matchedData(req, { locations: ["query"] });
        const { filas, total } = await repo.listar({ q, ...req.paginacion });
        res.status(200).json(RespuestaFactory.exito(filas, RespuestaFactory.paginacion(req.paginacion, total)));
    } catch (err) {
        next(err);
    }
}

export async function obtener(req, res, next) {
    try {
        const u = await repo.obtener(Number(req.params.id));
        if (!u) throw noExiste(req.params.id);
        res.status(200).json(RespuestaFactory.exito(u));
    } catch (err) {
        next(err);
    }
}

export async function roles(_req, res, next) {
    try {
        res.status(200).json(RespuestaFactory.exito(await repo.rolesYPermisos()));
    } catch (err) {
        next(err);
    }
}

export async function crear(req, res, next) {
    try {
        const { clave, roles: codigos, activo, ...empleado } = matchedData(req, { locations: ["body"] });
        const r = await repo.crear(
            { ...empleado, hashClave: await crearHashClave(clave), roles: codigos, activo: activo ?? 1 },
            req.usuario.idUsuario
        );
        if (r.error) throw new AppError(r.error, 422);
        res.status(201).json(RespuestaFactory.exito(r.usuario));
    } catch (err) {
        next(err);
    }
}

export async function actualizar(req, res, next) {
    try {
        const id = Number(req.params.id);
        const { activo, roles: codigos } = matchedData(req, { locations: ["body"] });
        // Nadie se deja a si mismo fuera del sistema
        if (id === req.usuario.idUsuario) {
            if (activo === 0) throw new AppError("No puedes desactivar tu propio usuario", 409);
            if (codigos && !codigos.includes("ADMIN") && req.usuario.roles.some((r) => r.codigo === "ADMIN")) {
                throw new AppError("No puedes quitarte el rol de administrador a ti mismo", 409);
            }
        }
        const r = await repo.actualizar(id, { activo, roles: codigos }, req.usuario.idUsuario);
        if (!r) throw noExiste(id);
        if (r.error) throw new AppError(r.error, 422);
        res.status(200).json(RespuestaFactory.exito(r.usuario));
    } catch (err) {
        next(err);
    }
}

export async function restablecerClave(req, res, next) {
    try {
        const ok = await repo.restablecerClave(
            Number(req.params.id),
            await crearHashClave(req.body.clave),
            req.usuario.idUsuario
        );
        if (!ok) throw noExiste(req.params.id);
        res.status(204).send();
    } catch (err) {
        next(err);
    }
}

/** Vista previa del usuario estandar (2 letras del nombre + primer apellido) antes de crearlo. */
export async function correoSugerido(req, res, next) {
    try {
        const { nombres = "", apellidos = "" } = matchedData(req, { locations: ["query"] });
        res.status(200).json(RespuestaFactory.exito({ correo: await repo.correoEstandar(nombres, apellidos) }));
    } catch (err) {
        next(err);
    }
}

export async function permisos(_req, res, next) {
    try {
        res.status(200).json(RespuestaFactory.exito(await repo.permisos()));
    } catch (err) {
        next(err);
    }
}

const resultadoRol = (r, res, codigo, estado = 200) => {
    if (r === null) throw new AppError(`No existe el rol ${codigo}`, 404);
    if (r.error) throw new AppError(r.error, 409);
    res.status(estado).json(RespuestaFactory.exito(r));
};

export async function crearRol(req, res, next) {
    try {
        resultadoRol(await repo.crearRol(matchedData(req, { locations: ["body"] }), req.usuario.idUsuario), res, null, 201);
    } catch (err) {
        next(err);
    }
}

export async function actualizarRol(req, res, next) {
    try {
        resultadoRol(await repo.actualizarRol(req.params.codigo, matchedData(req, { locations: ["body"] }), req.usuario.idUsuario), res, req.params.codigo);
    } catch (err) {
        next(err);
    }
}

export async function eliminarRol(req, res, next) {
    try {
        const r = await repo.eliminarRol(req.params.codigo, req.usuario.idUsuario);
        if (r === null) throw new AppError(`No existe el rol ${req.params.codigo}`, 404);
        if (r.error) throw new AppError(r.error, 409);
        res.status(204).send();
    } catch (err) {
        next(err);
    }
}
