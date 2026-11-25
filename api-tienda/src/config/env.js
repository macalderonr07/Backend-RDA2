// src/config/env.js
// Carga .env desde la raiz del proyecto sin depender del directorio desde el que
// se lance node (mismo problema que se corrigio en api-productos), y falla al
// arrancar si falta una variable obligatoria: mejor un error claro en el arranque
// que un 500 en la primera peticion.
import dotenv from "dotenv";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const raiz = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
dotenv.config({ path: resolve(raiz, ".env"), quiet: true });

// Zona horaria del negocio (Ecuador). Se fija en el proceso Node (fechas que
// lee el driver) y en cada sesion de Oracle (LOCALTIMESTAMP de los DEFAULT y
// funciones): asi da igual si el servidor o el contenedor corren en UTC.
const ZONA_HORARIA = /^[A-Za-z_]+\/[A-Za-z_]+$|^[+-]\d{2}:\d{2}$/.test(process.env.ZONA_HORARIA ?? "") ? process.env.ZONA_HORARIA : "America/Guayaquil";
process.env.TZ = ZONA_HORARIA;

const OBLIGATORIAS = ["ORACLE_USER", "ORACLE_PASSWORD", "ORACLE_CONNECT_STRING"];
const faltantes = OBLIGATORIAS.filter((nombre) => !process.env[nombre]);
if (faltantes.length > 0) {
    throw new Error(`Faltan variables de entorno: ${faltantes.join(", ")} (ver .env.example)`);
}

const entero = (valor, porDefecto) => {
    const n = Number.parseInt(valor, 10);
    return Number.isInteger(n) && n > 0 ? n : porDefecto;
};

export const config = Object.freeze({
    port: entero(process.env.PORT, 5050),
    zonaHoraria: ZONA_HORARIA,
    clientOrigin: process.env.CLIENT_ORIGIN ?? "",
    oracle: Object.freeze({
        user: process.env.ORACLE_USER,
        password: process.env.ORACLE_PASSWORD,
        connectString: process.env.ORACLE_CONNECT_STRING,
        // Solo letras, digitos y _ : se interpola en ALTER SESSION (no admite binds)
        schema: /^[A-Za-z][A-Za-z0-9_]{0,127}$/.test(process.env.ORACLE_SCHEMA ?? "")
            ? process.env.ORACLE_SCHEMA.toUpperCase()
            : "ECOMMERCE",
        poolMin: entero(process.env.ORACLE_POOL_MIN, 1),
        poolMax: entero(process.env.ORACLE_POOL_MAX, 5),
    }),
    // Cache del catalogo (Redis = lectura principal; Oracle = respaldo y fuente
    // de verdad). REDIS_URL=off la desactiva y todo se lee de Oracle.
    redis: Object.freeze({
        url: process.env.REDIS_URL === "off" ? null : (process.env.REDIS_URL || "redis://localhost:6379"),
        prefijo: /^[a-z0-9:_-]{1,20}$/i.test(process.env.REDIS_PREFIJO ?? "") ? process.env.REDIS_PREFIJO : "ce:",
        // cada cuanto el worker revisa la outbox de Oracle (ms)
        intervaloSincronia: entero(process.env.CACHE_INTERVALO_MS, 200),
        // reconstruccion completa de seguridad (min), por si algo escapara a los triggers
        reconciliarCadaMin: entero(process.env.CACHE_RECONCILIAR_MIN, 30),
        // cache en memoria del proceso (L1) delante de Redis
        l1Maximo: entero(process.env.CACHE_L1_MAXIMO, 5000),
        l1TtlMs: entero(process.env.CACHE_L1_TTL_MS, 60000),
        // el worker solo corre si CACHE_WORKER no es "off" (varias instancias: uno basta,
        // igual se coordinan con un candado en Redis)
        worker: process.env.CACHE_WORKER !== "off",
    }),
});
