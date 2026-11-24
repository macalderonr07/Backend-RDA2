// src/routes/v1/usuarios.routes.js — montado en /api/v1/seguridad (permiso USUARIO_GESTIONAR)
//   GET   /usuarios              lista paginada (?q por correo)
//   GET   /usuarios/:id          un usuario con roles y empleado
//   POST  /usuarios              {nombres, apellidos, idTipoIdentificacion, identificacion, fechaIngreso?, clave, roles[]}
//                                 (el correo lo forma el servidor: 2 letras del nombre + primer apellido)
//   PATCH /usuarios/:id          {activo?, roles[]?}  (no hay DELETE: se desactiva;
//                                 la auditoria referencia al usuario)
//   PUT   /usuarios/:id/clave    {clave} restablece la clave
//   GET   /roles                 roles con sus permisos | POST /roles | PUT/DELETE /roles/:codigo | GET /permisos
import { Router } from "express";
import { body, param, query } from "express-validator";
import * as c from "../../controllers/usuarios.controller.js";
import { autenticar, exigirPermiso } from "../../middlewares/autenticacion.js";
import { paginacion, reglasPaginacion } from "../../middlewares/paginacion.js";
import { manejarValidacion } from "../../middlewares/validacion.js";
import { PATRONES, identificacionValida, regex } from "../../utils/patrones.js";

const router = Router();
router.use(autenticar);

const id = param("id").isInt({ min: 1 }).withMessage("Identificador no válido").toInt();
const roles = (opcional) => {
    let r = body("roles");
    if (opcional) r = r.optional();
    return [
        r.isArray({ min: 1, max: 5 }).withMessage("Elige al menos un rol"),
        body("roles.*").isString().matches(/^[A-Z_]{2,20}$/).withMessage("Rol no válido"),
    ];
};
const activo = body("activo").optional().isIn([0, 1, true, false]).withMessage("activo: sí o no")
    .customSanitizer((v) => (v === true || v === 1 ? 1 : 0));

router.get("/roles", c.roles);
router.get("/permisos", exigirPermiso("USUARIO_GESTIONAR"), c.permisos);
const reglasRol = (parcial) => [
    (parcial ? body("nombre").optional() : body("nombre")).isString().trim().isLength({ min: 3, max: 60 }).withMessage("Nombre del rol: de 3 a 60 caracteres")
        .matches(regex("nombre")).withMessage(`Nombre del rol: ${PATRONES.nombre.mensaje}`),
    (parcial ? body("permisos").optional() : body("permisos")).isArray({ min: 1, max: 60 }).withMessage("Marca al menos un permiso"),
    body("permisos.*").isString().matches(/^[A-Z_]{2,40}$/).withMessage("Permiso no válido"),
];
const codigoRol = param("codigo").matches(/^[A-Z_0-9]{2,20}$/).withMessage("Rol no válido");
router.post("/roles", exigirPermiso("USUARIO_GESTIONAR"), ...reglasRol(false), manejarValidacion, c.crearRol);
router.put("/roles/:codigo", exigirPermiso("USUARIO_GESTIONAR"), codigoRol, ...reglasRol(true), manejarValidacion, c.actualizarRol);
router.delete("/roles/:codigo", exigirPermiso("USUARIO_GESTIONAR"), codigoRol, manejarValidacion, c.eliminarRol);
router.get("/usuarios/correo-sugerido", exigirPermiso("USUARIO_GESTIONAR"),
    query("nombres").optional().isString().trim().isLength({ max: 100 }), query("apellidos").optional().isString().trim().isLength({ max: 100 }),
    manejarValidacion, c.correoSugerido);
router.get("/usuarios", exigirPermiso("USUARIO_GESTIONAR"), reglasPaginacion,
    query("q").optional().isString().trim().isLength({ max: 80 }), manejarValidacion, paginacion, c.listar);
router.get("/usuarios/:id", exigirPermiso("USUARIO_GESTIONAR"), id, manejarValidacion, c.obtener);
router.post(
    "/usuarios",
    exigirPermiso("USUARIO_GESTIONAR"),
    // el correo no se escribe: lo forma el servidor (2 letras del nombre + primer apellido)
    body("nombres").isString().trim().matches(regex("nombrePersona")).withMessage(`Nombres: ${PATRONES.nombrePersona.mensaje}`),
    body("apellidos").isString().trim().matches(regex("nombrePersona")).withMessage(`Apellidos: ${PATRONES.nombrePersona.mensaje}`),
    body("idTipoIdentificacion").isIn(["05", "06"]).withMessage("Tipo: cédula o pasaporte"),
    body("identificacion").isString().trim().toUpperCase().custom((v, { req }) => {
        const error = identificacionValida(String(req.body.idTipoIdentificacion ?? ""), v);
        if (error) throw new Error(error);
        return true;
    }),
    body("fechaIngreso").optional({ values: "falsy" }).isISO8601().withMessage("Fecha de ingreso no válida").toDate(),
    body("clave").isString().matches(regex("clave")).withMessage(PATRONES.clave.mensaje),
    ...roles(false),
    activo,
    manejarValidacion,
    c.crear
);
router.patch("/usuarios/:id", exigirPermiso("USUARIO_GESTIONAR"), id, ...roles(true), activo, manejarValidacion, c.actualizar);
router.put(
    "/usuarios/:id/clave",
    exigirPermiso("USUARIO_GESTIONAR"),
    id,
    body("clave").isString().matches(regex("clave")).withMessage(PATRONES.clave.mensaje),
    manejarValidacion,
    c.restablecerClave
);

export default router;
