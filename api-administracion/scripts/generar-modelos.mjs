// scripts/generar-modelos.mjs
// Genera src/models/tablas.generado.js a partir del diccionario de datos de
// Oracle (all_tab_columns + all_constraints del esquema PRODUCCION):
//
//   npm run modelos
//
// Por que generado: la base tiene ~60 tablas y el modelo de Sequelize debe ser
// EXACTAMENTE el de la base (tipos, longitudes, nulos, claves). Escribirlos a
// mano invita a que se desalineen; generarlos del diccionario no. Las
// asociaciones (que dan significado al modelo) se escriben a mano en
// src/models/index.js.
//
// Convencion de nombres: cada columna lleva un prefijo de 3 letras por tabla
// (PVC_NOMBRE, PRD_CODIGO); el atributo del modelo es el nombre sin prefijo en
// camelCase ("nombre", "codigo"). Las claves (ID_*) conservan su nombre:
// ID_PROVINCIA -> idProvincia.
import { writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { consulta, sequelize, ESQUEMA } from "../src/config/db.js";

const aqui = dirname(fileURLToPath(import.meta.url));
const destino = resolve(aqui, "../src/models/tablas.generado.js");

const columnas = await consulta(
    `SELECT c.table_name, c.column_name, c.data_type, c.char_length, c.data_precision, c.data_scale,
            c.nullable, c.identity_column, c.column_id, c.data_default
     FROM all_tab_columns c
     JOIN all_tables t ON t.owner = c.owner AND t.table_name = c.table_name
     WHERE c.owner = :esquema
     ORDER BY c.table_name, c.column_id`,
    { esquema: ESQUEMA }
);
const claves = await consulta(
    `SELECT cc.table_name, cc.column_name
     FROM all_constraints k
     JOIN all_cons_columns cc ON cc.owner = k.owner AND cc.constraint_name = k.constraint_name
     WHERE k.owner = :esquema AND k.constraint_type = 'P'`,
    { esquema: ESQUEMA }
);
const esClave = new Set(claves.map((k) => `${k.table_name}.${k.column_name}`));

const camel = (texto) => texto.toLowerCase().replace(/_([a-z0-9])/g, (_, c) => c.toUpperCase());
const pascal = (texto) => camel(texto).replace(/^./, (c) => c.toUpperCase());

function atributo(columna) {
    if (columna.startsWith("ID_")) return camel(columna);
    const sinPrefijo = columna.replace(/^[A-Z]{2,4}_/, "");
    return camel(sinPrefijo);
}

function tipo(c) {
    switch (c.data_type) {
        case "VARCHAR2":
        case "NVARCHAR2":
            return `DataTypes.STRING(${c.char_length})`;
        case "CHAR":
            return `DataTypes.CHAR(${c.char_length})`;
        case "CLOB":
            return "DataTypes.TEXT";
        case "DATE":
            return "DataTypes.DATE";
        case "NUMBER":
            if (c.data_scale > 0) return `DataTypes.DECIMAL(${c.data_precision}, ${c.data_scale})`;
            return "DataTypes.INTEGER";
        default:
            if (c.data_type.startsWith("TIMESTAMP")) return "DataTypes.DATE";
            return "DataTypes.STRING";
    }
}

const porTabla = new Map();
for (const c of columnas) {
    if (!porTabla.has(c.table_name)) porTabla.set(c.table_name, []);
    porTabla.get(c.table_name).push(c);
}

let salida = `// src/models/tablas.generado.js — GENERADO por scripts/generar-modelos.mjs (no editar a mano)
// Un modelo de Sequelize por tabla del esquema ${ESQUEMA}, con tipos, nulos y
// claves leidos del diccionario de datos de Oracle. Las asociaciones estan en
// src/models/index.js.
import { DataTypes } from "sequelize";

/** Define todos los modelos sobre la instancia de Sequelize y los devuelve por nombre. */
export function definirTablas(sequelize) {
    const m = {};
`;

for (const [tabla, cols] of porTabla) {
    const nombre = pascal(tabla);
    const usados = new Set();
    const lineas = cols.map((c) => {
        let attr = atributo(c.column_name);
        if (usados.has(attr)) attr = camel(c.column_name); // colision: nombre completo
        usados.add(attr);
        const partes = [`type: ${tipo(c)}`, `field: "${c.column_name}"`];
        if (esClave.has(`${tabla}.${c.column_name}`)) partes.push("primaryKey: true");
        if (c.identity_column === "YES") partes.push("autoIncrement: true");
        // DECIMAL llega como texto (".25"): la API devuelve numeros
        if (c.data_type === "NUMBER" && c.data_scale > 0) {
            partes.push(`get() { const v = this.getDataValue("${attr}"); return v == null ? null : Number(v); }`);
        }
        // Con DEFAULT en la base, el valor lo pone la base si no viene: Sequelize no
        // debe exigirlo (si no, rechazaria crear un producto sin "publicado").
        const tieneDefault = c.data_default != null && String(c.data_default).trim() !== "" && String(c.data_default).trim().toUpperCase() !== "NULL";
        if (c.nullable === "N" && c.identity_column !== "YES" && !tieneDefault) partes.push("allowNull: false");
        return `            ${attr}: { ${partes.join(", ")} },`;
    });
    salida += `
    m.${nombre} = sequelize.define(
        "${nombre}",
        {
${lineas.join("\n")}
        },
        { tableName: "${tabla}" }
    );
`;
}
salida += `
    return m;
}
`;
writeFileSync(destino, salida);
console.log(`${porTabla.size} modelos generados en src/models/tablas.generado.js`);
await sequelize.close();
