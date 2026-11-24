// src/middlewares/validarRecurso.js
// Validacion + sanitizacion de un recurso generico, construida a partir de su
// descripcion en src/recursos/registro.js (la MISMA que ve el frontend).
//  - POST y PUT: los campos requeridos deben venir; PATCH: todo es opcional.
//  - Texto: trim + patron (regex con "u"). No se usa escape(): los datos se
//    muestran en el frontend con textContent (nunca innerHTML) y el patron ya
//    rechaza < y >. escape() guardaria "&amp;" en la base.
//  - Las claves foraneas se convierten a entero; la existencia la garantiza la
//    base (ORA-02291 -> 422 en el errorHandler).
import { body, param, query } from "express-validator";
import { RECURSO_POR_RUTA } from "../recursos/registro.js";
import { PATRONES, identificacionValida, regex } from "../utils/patrones.js";

const PATRON_POR_TIPO = {
    correo: "correo",
    telefono: "telefono",
    url: "url",
    entero: "entero",
    cantidad: "cantidad",
    dinero: "dinero",
    porcentaje: "porcentaje",
    fecha: "fecha",
};

function regla(campo, parcial) {
    let r = body(campo.nombre);
    const opcional = parcial || !campo.requerido;
    r = opcional ? r.optional({ values: "null" }) : r.exists({ values: "falsy" }).withMessage(`${campo.etiqueta} es obligatorio`).bail();

    switch (campo.tipo) {
        case "booleano":
            return r.isIn([0, 1, "0", "1", true, false]).withMessage(`${campo.etiqueta}: sí o no`).customSanitizer((v) => (v === true || v === "1" || v === 1 ? 1 : 0));
        case "seleccion": {
            // El tipo de la clave lo dice el recurso al que apunta: los ids son
            // enteros, pero algunos catalogos usan codigos de texto ("05" del
            // SRI, "pie2"), que deben seguir siendo texto.
            const destino = RECURSO_POR_RUTA.get(campo.recurso);
            const claveNumerica = destino?.modelo.rawAttributes[destino.pk]?.type?.key === "INTEGER";
            return r
                .custom((v) => {
                    const texto = String(v ?? "").trim();
                    if (texto === "") throw new Error(`Elige ${campo.etiqueta.toLowerCase()}`);
                    if (claveNumerica ? !/^\d{1,10}$/.test(texto) : !/^[A-Za-z0-9-]{1,20}$/.test(texto)) {
                        throw new Error(`${campo.etiqueta}: opción no válida`);
                    }
                    return true;
                })
                .customSanitizer((v) => (claveNumerica ? Number(v) : String(v).trim()));
        }
        case "opciones":
            return r.isIn(campo.opciones.map((o) => o.valor)).withMessage(`${campo.etiqueta}: opción no válida`);
        case "identificacion":
            return r
                .isString()
                .trim()
                .toUpperCase()
                .custom((valor, { req }) => {
                    const tipo = req.body[campo.campoTipo];
                    if (!tipo) return true; // en PATCH sin tipo, lo valida la base
                    const error = identificacionValida(String(tipo), valor);
                    if (error) throw new Error(error);
                    return true;
                });
        default: {
            const patron = campo.patron ?? PATRON_POR_TIPO[campo.tipo] ?? "texto";
            const numerico = ["entero", "cantidad", "dinero", "porcentaje"].includes(campo.tipo);
            // un numero en el JSON se valida igual que el texto del formulario
            if (numerico) r = r.customSanitizer((v) => (typeof v === "number" ? String(v) : v));
            r = r.isString().withMessage(`${campo.etiqueta}: texto no válido`).trim();
            if (campo.tipo === "correo") r = r.toLowerCase();
            if (campo.tipo === "telefono") r = r.customSanitizer((v) => String(v).replace(/[\s()-]/g, ""));
            if (campo.max) r = r.isLength({ max: campo.max }).withMessage(`${campo.etiqueta}: hasta ${campo.max} caracteres`);
            r = r.matches(regex(patron)).withMessage(`${campo.etiqueta}: ${PATRONES[patron].mensaje}`);
            if (numerico) r = r.toFloat();
            return r;
        }
    }
}

/** Reglas del body para crear (parcial=false) o actualizar parcialmente (parcial=true). */
export function reglasRecurso(recurso, { parcial = false, conPk = false } = {}) {
    const campos = recurso.campos.filter((c) => !c.soloLectura && (conPk || c.nombre !== recurso.pk || !recurso.pkEditable));
    // Campos desconocidos: se rechazan (no se puede escribir una columna que el
    // recurso no expone, como un hash de clave o un id interno)
    const permitidos = new Set(campos.map((c) => c.nombre));
    const desconocidos = body().custom((cuerpo) => {
        const extra = Object.keys(cuerpo ?? {}).filter((k) => !permitidos.has(k));
        if (extra.length > 0) throw new Error(`Campos no permitidos: ${extra.join(", ")}`);
        return true;
    });
    return [desconocidos, ...campos.map((c) => regla(c, parcial))];
}

export const reglasId = [
    param("id").isString().trim().isLength({ min: 1, max: 30 }).matches(/^[A-Za-z0-9-]+$/u).withMessage("Identificador no válido"),
];

export const reglasListado = [
    query("q").optional().isString().trim().isLength({ max: 80 }).withMessage("La búsqueda admite hasta 80 caracteres"),
];
