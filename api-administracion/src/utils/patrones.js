// src/utils/patrones.js
// Expresiones regulares de validacion: UNA sola fuente para el servidor
// (express-validator) y para el navegador (se publican en GET /api/v1/meta).
// Asi la regla que ve el usuario en el formulario es exactamente la que
// aplica el servidor. Todas con bandera "u" (letras con tilde, ñ).

export const PATRONES = Object.freeze({
    nombre: {
        fuente: "^[\\p{L}\\p{N}][\\p{L}\\p{N} .,'()&/°º#+-]{1,149}$",
        mensaje: "Usa letras, números y signos comunes (2 a 150 caracteres)",
    },
    nombrePersona: {
        fuente: "^[\\p{L}][\\p{L} .'-]{1,79}$",
        mensaje: "Solo letras, espacios, apóstrofo o guion (2 a 80)",
    },
    codigo: {
        fuente: "^[A-Z0-9][A-Z0-9-]{0,19}$",
        mensaje: "Mayúsculas, dígitos y guiones, hasta 20 (ej. CE-1042)",
    },
    slug: {
        fuente: "^[a-z0-9][a-z0-9-]{0,19}$",
        mensaje: "Minúsculas, dígitos y guiones, hasta 20 (ej. cueros-1)",
    },
    codigoCorto: {
        fuente: "^[A-Za-z0-9]{1,4}$",
        mensaje: "De 1 a 4 letras o dígitos (ej. pie2)",
    },
    correo: {
        fuente: "^[a-z0-9._%+-]+@[a-z0-9.-]+\\.[a-z]{2,}$",
        mensaje: "Correo en minúsculas, como nombre@dominio.ec",
    },
    telefono: {
        fuente: "^(?:\\+593|0)\\d{8,9}$",
        mensaje: "Teléfono de Ecuador: 0 + 8 o 9 dígitos, o +593 (sin espacios)",
    },
    cedula: {
        fuente: "^\\d{10}$",
        mensaje: "La cédula tiene 10 dígitos",
    },
    ruc: {
        fuente: "^\\d{10}001$",
        mensaje: "El RUC tiene 13 dígitos y termina en 001",
    },
    pasaporte: {
        fuente: "^[A-Z0-9]{5,20}$",
        mensaje: "De 5 a 20 letras mayúsculas o dígitos",
    },
    serieSri: {
        fuente: "^\\d{3}$",
        mensaje: "Tres dígitos (ej. 001)",
    },
    codigoSri: {
        fuente: "^\\d{2}$",
        mensaje: "Dos dígitos (ej. 01)",
    },
    entero: {
        fuente: "^\\d{1,9}$",
        mensaje: "Número entero positivo",
    },
    cantidad: {
        fuente: "^\\d{1,9}(?:\\.\\d{1,3})?$",
        mensaje: "Número positivo con hasta 3 decimales (ej. 23.5)",
    },
    dinero: {
        fuente: "^\\d{1,9}(?:\\.\\d{1,2})?$",
        mensaje: "Valor con hasta 2 decimales (ej. 12.50)",
    },
    porcentaje: {
        fuente: "^(?:[1-9]\\d?|0?\\.\\d{1,2}|[1-9]\\d?\\.\\d{1,2})$",
        mensaje: "Porcentaje mayor que 0 y menor que 100 (ej. 8 o 12.5)",
    },
    url: {
        fuente: "^https?://[^\\s]{3,490}$",
        mensaje: "Dirección web que empiece con http:// o https://",
    },
    // costo de compra: la base guarda 4 decimales (lote.lot_costo_unitario NUMBER(12,4))
    costo: {
        fuente: "^\\d{1,8}(\\.\\d{1,4})?$",
        mensaje: "Número positivo con hasta 4 decimales (ej. 1.1546)",
    },
    // recepcion por piezas: la medida de cada banda o plancha
    medidas: {
        fuente: "^\\d{1,6}(\\.\\d{1,3})?(\\s*,\\s*\\d{1,6}(\\.\\d{1,3})?){0,99}$",
        mensaje: "Medida de cada pieza separada por comas, ej. 24, 24, 23.5",
    },
    fecha: {
        fuente: "^\\d{4}-\\d{2}-\\d{2}$",
        mensaje: "Fecha en formato AAAA-MM-DD",
    },
    clave: {
        fuente: "^(?=.*[a-z])(?=.*[A-Z])(?=.*\\d)[^\\s]{10,64}$",
        mensaje: "De 10 a 64 caracteres, con mayúscula, minúscula y número, sin espacios",
    },
    texto: {
        fuente: "^[^<>]{0,300}$",
        mensaje: "Hasta 300 caracteres, sin < ni >",
    },
});

/** RegExp lista para usar en el servidor. */
export function regex(nombre) {
    const p = PATRONES[nombre];
    if (!p) throw new Error(`Patron desconocido: ${nombre}`);
    return new RegExp(p.fuente, "u");
}

/**
 * Cedula ecuatoriana: 10 digitos, provincia 01-24 (o 30 exterior), tercer
 * digito < 6 y digito verificador por modulo 10. El RUC de persona natural es
 * la cedula + "001".
 */
export function cedulaValida(cedula) {
    if (!/^\d{10}$/.test(cedula)) return false;
    const provincia = Number(cedula.slice(0, 2));
    if (!((provincia >= 1 && provincia <= 24) || provincia === 30)) return false;
    if (Number(cedula[2]) >= 6) return false;
    const suma = [...cedula.slice(0, 9)].reduce((s, d, i) => {
        let v = Number(d) * (i % 2 === 0 ? 2 : 1);
        if (v > 9) v -= 9;
        return s + v;
    }, 0);
    return (10 - (suma % 10)) % 10 === Number(cedula[9]);
}

/** Valida la identificacion segun el tipo SRI (04 RUC, 05 cedula, 06 pasaporte...). */
export function identificacionValida(tipo, valor) {
    switch (tipo) {
        case "05":
            return cedulaValida(valor) ? null : "La cédula no es válida (revisa el dígito verificador)";
        case "04":
            return regex("ruc").test(valor) ? null : PATRONES.ruc.mensaje;
        case "06":
            return regex("pasaporte").test(valor) ? null : PATRONES.pasaporte.mensaje;
        case "07":
            return valor === "9999999999999" ? null : "Consumidor final usa 9999999999999";
        default:
            return /^[A-Z0-9-]{3,20}$/.test(valor) ? null : "Identificación de 3 a 20 caracteres";
    }
}
