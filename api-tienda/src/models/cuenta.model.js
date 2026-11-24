// src/models/cuenta.model.js
// Repository de cuentas web (ecommerce.cuenta_web). El reparto de trabajo es el
// del modelo de la base: la API valida la clave (scrypt, utils/clave.js) y la
// base registra el resultado (fn_registrar_acceso_web deja la bitacora en
// log_evento_web y actualiza el ultimo acceso).
import oracledb from "oracledb";
import { config } from "../config/env.js";
import { db } from "../config/db.js";

// Validado en env.js (solo letras, digitos y _): seguro de interpolar
const ESQUEMA = config.oracle.schema;

/**
 * Crea la cuenta: fn_registrar_cuenta_web registra (o reconoce por correo) al
 * cliente en produccion y guarda la cuenta en el nodo e-commerce. Correo
 * duplicado -> ORA-20001 -> 409. Devuelve la cuenta creada.
 */
export async function registrarCuenta({ nombres, apellidos, correo, telefono, hashClave, ip }) {
    await db.transaccion((conexion) =>
        conexion.execute(
            `BEGIN
                 :cuenta := ${ESQUEMA}.fn_registrar_cuenta_web(:nombres, :apellidos, :correo, :hash, :telefono, :ip);
             END;`,
            {
                cuenta: { dir: oracledb.BIND_OUT, type: oracledb.NUMBER },
                nombres,
                apellidos: apellidos ?? null,
                correo,
                hash: hashClave,
                telefono: telefono ?? null,
                ip: ip ?? null,
            }
        )
    );
    return buscarCuenta(correo);
}

/** Credenciales para validar el login. null si el correo no tiene cuenta. */
export async function buscarCredenciales(correo) {
    const { rows } = await db.ejecutar(
        `SELECT cwe_hash_clave, cwe_activa FROM cuenta_web WHERE cwe_correo = :correo`,
        { correo }
    );
    if (rows.length === 0) return null;
    return { hashClave: rows[0].CWE_HASH_CLAVE, activa: rows[0].CWE_ACTIVA === 1 };
}

/**
 * Registra el resultado del login en la base (bitacora + ultimo acceso).
 * exito: 1 clave valida, 0 rechazado. Devuelve el id de la cuenta si el
 * acceso vale, null si no (cuenta inexistente, clave mala o cuenta inactiva).
 */
export async function registrarAcceso(correo, exito, { sesion = null, ip = null, agente = null } = {}) {
    const { outBinds } = await db.transaccion((conexion) =>
        conexion.execute(
            `BEGIN
                 :cuenta := ${ESQUEMA}.fn_registrar_acceso_web(:correo, :exito, :sesion, :ip, :agente);
             END;`,
            {
                cuenta: { dir: oracledb.BIND_OUT, type: oracledb.NUMBER },
                correo,
                exito,
                sesion,
                ip,
                agente,
            }
        )
    );
    return outBinds.cuenta;
}

/** Cuenta con la actividad de compra del cliente (v_cuenta_web). */
export async function buscarCuenta(correo) {
    const { rows } = await db.ejecutar(
        `SELECT id_cuenta_web, correo, activa, creada, ultimo_acceso, cliente, compras, ultima_compra, segmento
         FROM v_cuenta_web WHERE correo = :correo`,
        { correo }
    );
    if (rows.length === 0) return null;
    const f = rows[0];
    return {
        idCuenta: f.ID_CUENTA_WEB,
        correo: f.CORREO,
        activa: f.ACTIVA === 1,
        creada: f.CREADA,
        ultimoAcceso: f.ULTIMO_ACCESO,
        cliente: f.CLIENTE,
        compras: f.COMPRAS,
        ultimaCompra: f.ULTIMA_COMPRA,
        segmento: f.SEGMENTO,
    };
}
