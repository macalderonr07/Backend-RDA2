// src/models/combo.model.js
// Repository de combos (solo lectura). Un combo es UNO solo (no uno por
// color): una receta de (producto, forma de venta, cantidad). v_combo_web
// trae una fila por combo x componente x variante publicada; aqui se agrupan
// por color y se ofrecen solo los colores presentes en TODOS los componentes.
// Se vende como sus lineas reales, asi que el precio de cada color es la suma
// de sus componentes y lo armable lo limita el componente mas escaso.
import { db } from "../config/db.js";
import { colorDe } from "../utils/caracteristicas.js";

const redondear = (n) => Math.round(n * 100) / 100;
const SIN_COLOR = "Único"; // productos sin atributo Color

function agruparCombos(filas) {
    const porCodigo = new Map();
    for (const f of filas) {
        let combo = porCodigo.get(f.CODIGO);
        if (!combo) {
            combo = {
                codigo: f.CODIGO,
                nombre: f.NOMBRE,
                descripcion: f.DESCRIPCION,
                totalComponentes: f.COMPONENTES,
                componentes: new Map(), // prd_codigo -> { producto, nombre, presentacion, cantidad }
                porColor: new Map(), // color -> Map(prd_codigo -> fila)
            };
            porCodigo.set(f.CODIGO, combo);
        }
        if (!combo.componentes.has(f.PRD_CODIGO)) {
            combo.componentes.set(f.PRD_CODIGO, {
                codigoProducto: f.PRD_CODIGO,
                nombre: f.PRD_NOMBRE,
                presentacion: f.PRESENTACION,
                cantidad: f.CANTIDAD,
                imagenUrl: f.IMAGEN_URL,
            });
        }
        const color = colorDe(f.CARACTERISTICAS) ?? SIN_COLOR;
        if (!combo.porColor.has(color)) combo.porColor.set(color, new Map());
        combo.porColor.get(color).set(f.PRD_CODIGO, f);
    }

    return (
        [...porCodigo.values()]
            // un componente despublicado deja el combo incompleto: no se ofrece
            .filter((c) => c.componentes.size === c.totalComponentes)
            .map((c) => {
                const colores = [...c.porColor.entries()]
                    // el color debe existir en todos los componentes
                    .filter(([, filas]) => filas.size === c.totalComponentes)
                    .map(([color, filas]) => {
                        const lineas = [...filas.values()].map((f) => ({
                            idPresentacion: f.ID_PRESENTACION,
                            cantidad: f.CANTIDAD,
                            precioUnitario: f.PRECIO_FINAL_CON_IVA,
                            disponible: f.DISPONIBLE,
                        }));
                        return {
                            color,
                            precio: redondear(lineas.reduce((s, l) => s + l.precioUnitario * l.cantidad, 0)),
                            disponible: Math.min(...lineas.map((l) => Math.floor(l.disponible / l.cantidad))),
                            lineas: lineas.map(({ idPresentacion, cantidad }) => ({ idPresentacion, cantidad })),
                        };
                    })
                    .sort((a, b) => a.color.localeCompare(b.color, "es"));
                return {
                    codigo: c.codigo,
                    nombre: c.nombre,
                    descripcion: c.descripcion,
                    componentes: [...c.componentes.values()],
                    colores,
                };
            })
            .filter((c) => c.colores.length > 0)
    );
}

const COLUMNAS = `codigo, nombre, descripcion, componentes, prd_codigo, prd_nombre, presentacion, cantidad,
                  id_presentacion, caracteristicas, precio_final_con_iva, disponible, imagen_url`;

/** Combos ofrecidos; con producto, solo los que lo incluyen. */
export async function listarCombos({ producto = null } = {}) {
    const { rows } = await db.ejecutar(
        `SELECT ${COLUMNAS}
         FROM v_combo_web c
         WHERE (:producto IS NULL
                OR c.codigo IN (SELECT x.codigo FROM v_combo_web x WHERE x.prd_codigo = :producto))
         ORDER BY c.codigo, c.prd_codigo`,
        { producto }
    );
    return agruparCombos(rows);
}

export async function buscarCombo(codigo) {
    const { rows } = await db.ejecutar(
        `SELECT ${COLUMNAS} FROM v_combo_web c WHERE c.codigo = :codigo ORDER BY c.prd_codigo`,
        { codigo }
    );
    return agruparCombos(rows)[0] ?? null;
}
