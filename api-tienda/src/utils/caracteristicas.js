// src/utils/caracteristicas.js
// v_catalogo arma "caracteristicas" como "Atributo: valor, Atributo: valor"
// (LISTAGG ordenado por atributo, ver la vista). Estas funciones lo convierten
// en datos: el frontend arma sus filtros con cualquier atributo de la base
// (Color hoy; Grosor, Talla... si se agregan), sin cambiar el codigo.

/** "Color: Negro, Grosor: 1.2 mm" -> { Color: "Negro", Grosor: "1.2 mm" } */
export function caracteristicasDe(texto) {
    const resultado = {};
    for (const par of (texto ?? "").split(", ")) {
        const separador = par.indexOf(": ");
        if (separador > 0) resultado[par.slice(0, separador)] = par.slice(separador + 2);
    }
    return resultado;
}

/** Valor del atributo Color (o null). */
export function colorDe(texto) {
    return caracteristicasDe(texto).Color ?? null;
}

/** Valor del atributo Talla (o null): suelas y plantillas se manejan por talla. */
export function tallaDe(texto) {
    return caracteristicasDe(texto).Talla ?? null;
}
