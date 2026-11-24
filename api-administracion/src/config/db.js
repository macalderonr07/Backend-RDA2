// src/config/db.js
// Singleton (ARQUITECTURA.md 3.2) de la conexion: UNA instancia de Sequelize
// (con su pool) para todo el proceso, con instancia privada y acceso por
// obtenerInstancia(). Los modelos del ORM se definen sobre ella.
//
// Ayudantes que usan los Repository:
//  - conUsuario(idUsuario, fn): transaccion que primero fija el usuario de la
//    sesion en la base (fn_usuario_sesion). La auditoria y los disparadores
//    lo usan; como las conexiones del pool se reutilizan entre peticiones, se
//    fija SIEMPRE al empezar, nunca se asume.
//  - llamar(t, nombre, args): funcion de negocio de la base (produccion.fn_*)
//    dentro de la transaccion, con binds reales de oracledb. Las reglas
//    (stock, precios, permisos por usuario) viven en la base: no se duplican.
//  - consulta(sql, binds): lectura de vistas de reporte con binds reales.
import oracledb from "oracledb";
import { Sequelize, QueryTypes } from "sequelize";
import { config } from "./env.js";

class ConexionDB {
    static #instancia;

    static obtenerInstancia() {
        if (!ConexionDB.#instancia) {
            ConexionDB.#instancia = new Sequelize({
                dialect: "oracle",
                username: config.oracle.user,
                password: config.oracle.password,
                dialectOptions: { connectString: config.oracle.connectString },
                pool: { min: 1, max: config.oracle.poolMax, idle: 10000 },
                logging: false,
                define: { schema: config.oracle.schema, timestamps: false, freezeTableName: true },
            });
        }
        return ConexionDB.#instancia;
    }
}

export const sequelize = ConexionDB.obtenerInstancia();
export const ESQUEMA = config.oracle.schema;

const NOMBRE_VALIDO = /^(fn|pr)_[a-z_]+$/;

function lista(args) {
    return Object.keys(args)
        .map((k) => `${k} => :${k}`)
        .join(", ");
}

/** Transaccion a nombre de un usuario de la administracion. */
export function conUsuario(idUsuario, fn) {
    return sequelize.transaction(async (t) => {
        await t.connection.execute(`BEGIN ${ESQUEMA}.fn_usuario_sesion(:usuario); END;`, { usuario: idUsuario });
        return fn(t);
    });
}

/**
 * Funcion de negocio que devuelve un NUMBER (casi todas: el id creado), dentro
 * de la transaccion t:  await llamar(t, "fn_registrar_precio", { p_presentacion, p_precio, p_usuario })
 * Se llama en un bloque PL/SQL (las que hacen DML no pueden ir en un SELECT) y
 * el resultado vuelve por un bind de salida.
 */
export async function llamar(t, nombre, args) {
    if (!NOMBRE_VALIDO.test(nombre)) throw new Error(`Nombre de funcion no permitido: ${nombre}`);
    const binds = { ...args, resultado: { dir: oracledb.BIND_OUT, type: oracledb.NUMBER } };
    const r = await t.connection.execute(`BEGIN :resultado := ${ESQUEMA}.${nombre}(${lista(args)}); END;`, binds);
    return r.outBinds.resultado;
}

/** Procedimiento (sin valor de retorno) dentro de la transaccion t. */
export async function procedimiento(t, nombre, args) {
    if (!NOMBRE_VALIDO.test(nombre)) throw new Error(`Nombre de procedimiento no permitido: ${nombre}`);
    await t.connection.execute(`BEGIN ${ESQUEMA}.${nombre}(${lista(args)}); END;`, args);
}

/**
 * Lectura con binds reales (vistas de reporte, consultas con agregados que no
 * vale la pena modelar en el ORM). Devuelve filas con claves en minuscula.
 */
export async function consulta(sql, binds = {}, transaction = undefined) {
    const minusculas = (filas) =>
        filas.map((f) => Object.fromEntries(Object.entries(f).map(([k, v]) => [k.toLowerCase(), v])));
    const opciones = { outFormat: oracledb.OUT_FORMAT_OBJECT };
    if (transaction) return minusculas((await transaction.connection.execute(sql, binds, opciones)).rows);
    // Conexion del mismo pool de Sequelize, con binds :nombre nativos de oracledb
    const conexion = await sequelize.connectionManager.getConnection({ type: "read" });
    try {
        return minusculas((await conexion.execute(sql, binds, opciones)).rows);
    } finally {
        await sequelize.connectionManager.releaseConnection(conexion);
    }
}

export { QueryTypes };
