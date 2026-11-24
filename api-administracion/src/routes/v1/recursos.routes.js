// src/routes/v1/recursos.routes.js
// Un router REST por cada recurso del registro, montado en /api/v1/<ruta>:
//   GET    /            lista paginada (?q= busqueda, ?page, ?limit, ?<filtro>=)
//   GET    /opciones    [{ valor, etiqueta }] para listas de seleccion
//   GET    /:id         un registro
//   POST   /            crea         (permiso del recurso)
//   PUT    /:id         reemplaza    (permiso del recurso; requeridos obligatorios)
//   PATCH  /:id         actualiza    (permiso del recurso; solo lo que viene)
//   DELETE /:id         elimina      (permiso del recurso; si esta en uso -> 409)
// Leer solo exige estar autenticado; escribir exige el permiso del recurso.
import { Router } from "express";
import { controladorRecurso } from "../../controllers/recursos.controller.js";
import { autenticar, exigirPermiso } from "../../middlewares/autenticacion.js";
import { paginacion, reglasPaginacion } from "../../middlewares/paginacion.js";
import { manejarValidacion } from "../../middlewares/validacion.js";
import { reglasId, reglasListado, reglasRecurso } from "../../middlewares/validarRecurso.js";
import { RECURSOS } from "../../recursos/registro.js";

export function montarRecursos(app) {
    for (const recurso of RECURSOS) {
        const c = controladorRecurso(recurso);
        const router = Router();
        router.use(autenticar);
        router.get("/opciones", c.opciones);
        if (!recurso.soloOpciones) {
            router.get("/", reglasPaginacion, reglasListado, manejarValidacion, paginacion, c.listar);
            router.get("/:id", reglasId, manejarValidacion, c.obtener);
        }
        if (!recurso.soloLectura) {
            const permiso = exigirPermiso(recurso.permiso);
            router.post("/", permiso, reglasRecurso(recurso, { conPk: true }), manejarValidacion, c.crear);
            router.put("/:id", permiso, reglasId, reglasRecurso(recurso), manejarValidacion, c.actualizar);
            router.patch("/:id", permiso, reglasId, reglasRecurso(recurso, { parcial: true }), manejarValidacion, c.actualizar);
            if (!recurso.sinEliminar) router.delete("/:id", permiso, reglasId, manejarValidacion, c.eliminar);
        }
        app.use(`/api/v1/${recurso.ruta}`, router);
    }
}
