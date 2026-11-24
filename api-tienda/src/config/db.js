// src/config/db.js
// Singleton explicito (ARQUITECTURA.md 3.2): una sola instancia de ConexionDB y,
// dentro de ella, un solo pool de Oracle para todo el proceso. Los modelos nunca
// abren conexiones por su cuenta: piden una prestada con ejecutar()/transaccion()
// y el pool la recupera siempre (finally), aunque la consulta falle.
import oracledb from "oracledb";
import { config } from "./env.js";

// Filas como objetos { COLUMNA: valor } en vez de arreglos posicionales.
oracledb.outFormat = oracledb.OUT_FORMAT_OBJECT;

class ConexionDB {
    static #instancia;
    #pool = null;

    static obtenerInstancia() {
        if (!ConexionDB.#instancia) ConexionDB.#instancia = new ConexionDB();
        return ConexionDB.#instancia;
    }

    async iniciar() {
        if (this.#pool) return this.#pool;
        const { user, password, connectString, schema, poolMin, poolMax } = config.oracle;
        this.#pool = await oracledb.createPool({
            user,
            password,
            connectString,
            poolMin,
            poolMax,
            // Cada sesion nueva trabaja sobre el esquema ECOMMERCE: los modelos
            // escriben "carrito", no "ecommerce.carrito" (lo que sugiere la base).
            sessionCallback: (conexion, _etiqueta, listo) => {
                conexion.execute(`ALTER SESSION SET CURRENT_SCHEMA = ${schema}`).then(() => listo(), listo);
            },
        });
        return this.#pool;
    }

    async #conexion() {
        return (await this.iniciar()).getConnection();
    }

    /** Una sentencia con binds (nunca concatenar datos del usuario en el SQL). */
    async ejecutar(sql, binds = {}, opciones = {}) {
        const conexion = await this.#conexion();
        try {
            return await conexion.execute(sql, binds, opciones);
        } finally {
            await conexion.close();
        }
    }

    /** Varias sentencias atomicas: commit si trabajo() termina, rollback si lanza. */
    async transaccion(trabajo) {
        const conexion = await this.#conexion();
        try {
            const resultado = await trabajo(conexion);
            await conexion.commit();
            return resultado;
        } catch (err) {
            await conexion.rollback().catch(() => {});
            throw err;
        } finally {
            await conexion.close();
        }
    }

    async cerrar() {
        if (!this.#pool) return;
        await this.#pool.close(10);
        this.#pool = null;
    }
}

export const db = ConexionDB.obtenerInstancia();
