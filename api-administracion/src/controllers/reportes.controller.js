// src/controllers/reportes.controller.js
// Reportes, indicadores y tableros. Todas las respuestas tienen la misma forma
// para que un tablero las pinte sin conocer cada reporte:
//   GET /reportes                 catalogo: [{ id, titulo, pregunta, categoria, parametros, visual, columnas }]
//   GET /reportes/indicadores     KPI del periodo con su variacion frente al periodo anterior
//   GET /reportes/tableros        configuracion de tableros (widgets)
//   GET /reportes/:id             data: filas · meta: { reporte, parametros, totales, totalItems, generado }
// Periodo: ?desde=AAAA-MM-DD&hasta=AAAA-MM-DD (por defecto, los ultimos 30 dias) · ?agrupar=dia|semana|mes
import { matchedData } from "express-validator";
import { RespuestaFactory } from "../factories/respuesta.factory.js";
import { CATEGORIAS, REPORTES, TABLEROS, ejecutar, indicadores as kpis, metaReporte, resumen as resumenHoy } from "../repositories/reporte.repository.js";
import { AppError } from "../utils/AppError.js";

const accion = (fn) => async (req, res, next) => {
    try {
        await fn(req, res);
    } catch (err) {
        next(err);
    }
};

const DIA = 24 * 60 * 60 * 1000;
const iso = (d) => d.toISOString().slice(0, 10);
/** Hoy en Ecuador (UTC-5), como fecha de calendario. */
const hoy = () => new Date(Date.now() - 5 * 60 * 60 * 1000);

/** Periodo pedido (validado en la ruta) o los ultimos 30 dias; y el anterior de igual largo. */
export function periodoDe(req) {
    const q = matchedData(req, { locations: ["query"] });
    const hasta = q.hasta ?? iso(hoy());
    const desde = q.desde ?? iso(new Date(Date.parse(`${hasta}T00:00:00Z`) - 29 * DIA));
    if (desde > hasta) throw new AppError("La fecha inicial es posterior a la final", 422, [{ campo: "desde", mensaje: "«Desde» debe ser anterior o igual a «Hasta»" }]);
    const dias = Math.round((Date.parse(`${hasta}T00:00:00Z`) - Date.parse(`${desde}T00:00:00Z`)) / DIA) + 1;
    if (dias > 3 * 366) throw new AppError("El período máximo es de 3 años", 422, [{ campo: "desde", mensaje: "Elige un período de hasta 3 años" }]);
    const anteriorHasta = iso(new Date(Date.parse(`${desde}T00:00:00Z`) - DIA));
    const anteriorDesde = iso(new Date(Date.parse(`${anteriorHasta}T00:00:00Z`) - (dias - 1) * DIA));
    return { desde, hasta, dias, anteriorDesde, anteriorHasta, agrupar: q.agrupar ?? (dias > 120 ? "mes" : dias > 31 ? "semana" : "dia") };
}

const puede = (usuario, r) => !r.permiso || usuario.permisos.includes(r.permiso);

export const catalogo = accion(async (req, res) => {
    const lista = Object.entries(REPORTES).filter(([, r]) => puede(req.usuario, r)).map(([id, r]) => metaReporte(id, r));
    res.status(200).json(RespuestaFactory.exito(lista, { categorias: CATEGORIAS, totalItems: lista.length }));
});

export const tableros = accion(async (req, res) => {
    // un widget de un reporte que el usuario no puede ver no se envia
    const lista = TABLEROS.map((t) => ({
        ...t,
        widgets: t.widgets.filter((w) => w.tipo !== "reporte" || puede(req.usuario, REPORTES[w.reporte])),
    }));
    res.status(200).json(RespuestaFactory.exito(lista));
});

export const indicadores = accion(async (req, res) => {
    const periodo = periodoDe(req);
    res.status(200).json(RespuestaFactory.exito(await kpis(periodo, req.usuario.permisos), { periodo }));
});

export const resumen = accion(async (_req, res) => {
    res.status(200).json(RespuestaFactory.exito(await resumenHoy()));
});

export const reporte = accion(async (req, res) => {
    const id = req.params.id;
    const r = Object.hasOwn(REPORTES, id) ? REPORTES[id] : null;
    if (!r) throw new AppError(`No existe el reporte ${id}`, 404);
    if (!puede(req.usuario, r)) throw new AppError(`No tienes permiso para este reporte (requiere ${r.permiso})`, 403);
    const { filas, totales, parametros } = await ejecutar(id, periodoDe(req));
    res.status(200).json(RespuestaFactory.exito(filas, {
        reporte: metaReporte(id, r),
        parametros,
        totales,
        totalItems: filas.length,
        generado: new Date().toISOString(),
    }));
});
