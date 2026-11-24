// src/controllers/meta.controller.js
// GET /api/v1/meta: lo que el frontend necesita para construir formularios y
// tablas sin duplicar reglas — los patrones de validacion (regex) y la
// descripcion de cada recurso del registro (campos, tipos, permiso). Las
// funciones (modelo, etiqueta) no viajan: solo datos.
import { RespuestaFactory } from "../factories/respuesta.factory.js";
import { RECURSOS } from "../recursos/registro.js";
import { PATRONES } from "../utils/patrones.js";

const recursosPublicos = RECURSOS.filter((r) => !r.soloOpciones).map((r) => ({
    ruta: r.ruta,
    titulo: r.titulo,
    singular: r.singular,
    grupo: r.grupo,
    pk: r.pk,
    pkEditable: Boolean(r.pkEditable),
    soloLectura: Boolean(r.soloLectura),
    sinEliminar: Boolean(r.sinEliminar),
    permiso: r.permiso ?? null,
    ayuda: r.ayuda ?? null,
    filtros: r.filtros ?? [],
    buscable: Boolean(r.buscar?.length),
    campos: r.campos.map(({ nombre, etiqueta, tipo, requerido, patron, max, ayuda, recurso, opciones, campoTipo, soloLectura, automatico }) => ({
        nombre,
        etiqueta,
        tipo,
        requerido: Boolean(requerido),
        patron: patron ?? null,
        max: max ?? null,
        ayuda: ayuda ?? null,
        recurso: recurso ?? null,
        opciones: opciones ?? null,
        campoTipo: campoTipo ?? null,
        soloLectura: Boolean(soloLectura),
        automatico: Boolean(automatico),
    })),
}));

export function meta(_req, res) {
    res.status(200).json(RespuestaFactory.exito({ patrones: PATRONES, recursos: recursosPublicos }));
}
