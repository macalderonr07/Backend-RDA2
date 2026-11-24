// src/controllers/recursos.controller.js
// Controlador GENERICO de los recursos del registro: decide el status HTTP y
// arma la respuesta con el Factory; no conoce Sequelize (solo el Repository).
import { matchedData } from "express-validator";
import { RespuestaFactory } from "../factories/respuesta.factory.js";
import * as repo from "../repositories/recurso.repository.js";
import { AppError } from "../utils/AppError.js";

const noExiste = (recurso, id) => new AppError(`No existe ${recurso.singular} con identificador ${id}`, 404);

/** Filtros ?campo=valor permitidos por el recurso (claves foraneas). */
function filtrosDe(recurso, query) {
    const filtros = {};
    for (const campo of recurso.filtros ?? []) {
        const valor = query[campo];
        if (valor === undefined || valor === "") continue;
        if (!/^[A-Za-z0-9-]{1,20}$/.test(String(valor))) throw new AppError(`Filtro ${campo} no válido`, 422);
        const numerico = recurso.modelo.rawAttributes[campo]?.type?.key === "INTEGER";
        filtros[campo] = numerico ? Number(valor) : String(valor);
    }
    return filtros;
}

function idDe(recurso, crudo) {
    return recurso.modelo.rawAttributes[recurso.pk].type.key === "INTEGER" ? Number(crudo) : String(crudo);
}

export function controladorRecurso(recurso) {
    return {
        async listar(req, res, next) {
            try {
                const { q = null } = matchedData(req, { locations: ["query"] });
                const { filas, total } = await repo.listar(recurso, {
                    q,
                    filtros: filtrosDe(recurso, req.query),
                    limit: req.paginacion.limit,
                    offset: req.paginacion.offset,
                    orden: req.paginacion.orden,
                    dir: req.paginacion.dir,
                });
                res.status(200).json(RespuestaFactory.exito(filas, RespuestaFactory.paginacion(req.paginacion, total)));
            } catch (err) {
                next(err);
            }
        },

        async opciones(req, res, next) {
            try {
                const lista = await repo.opciones(recurso, { filtros: filtrosDe(recurso, req.query) });
                res.status(200).json(RespuestaFactory.exito(lista, { totalItems: lista.length }));
            } catch (err) {
                next(err);
            }
        },

        async obtener(req, res, next) {
            try {
                const fila = await repo.obtener(recurso, idDe(recurso, req.params.id));
                if (!fila) throw noExiste(recurso, req.params.id);
                res.status(200).json(RespuestaFactory.exito(fila));
            } catch (err) {
                next(err);
            }
        },

        async crear(req, res, next) {
            try {
                const datos = matchedData(req, { locations: ["body"] });
                const fila = await repo.crear(recurso, datos, req.usuario.idUsuario);
                res.status(201).location(`/api/v1/${recurso.ruta}/${fila.id}`).json(RespuestaFactory.exito(fila));
            } catch (err) {
                next(err);
            }
        },

        // PUT reemplaza (validado con todos los requeridos) y PATCH actualiza
        // solo lo que viene: el Repository es el mismo, cambia la validacion.
        async actualizar(req, res, next) {
            try {
                const datos = matchedData(req, { locations: ["body"] });
                const fila = await repo.actualizar(recurso, idDe(recurso, req.params.id), datos, req.usuario.idUsuario);
                if (!fila) throw noExiste(recurso, req.params.id);
                res.status(200).json(RespuestaFactory.exito(fila));
            } catch (err) {
                next(err);
            }
        },

        async eliminar(req, res, next) {
            try {
                const borrado = await repo.eliminar(recurso, idDe(recurso, req.params.id), req.usuario.idUsuario);
                if (!borrado) throw noExiste(recurso, req.params.id);
                res.status(204).send();
            } catch (err) {
                next(err);
            }
        },
    };
}
