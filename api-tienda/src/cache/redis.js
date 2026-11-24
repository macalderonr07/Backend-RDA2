// src/cache/redis.js
// Conexion a Redis (Singleton, como el pool de Oracle). Redis es OPCIONAL: si
// no hay URL, no conecta o se cae, la API sigue respondiendo desde Oracle.
//  - disableOfflineQueue: sin conexion, los comandos fallan al instante (no se
//    encolan esperando), asi la peticion pasa a Oracle sin demora.
//  - Una segunda conexion queda suscrita al canal de cambios: el worker avisa
//    que productos cambiaron y cada instancia invalida su cache en memoria.
import { createClient } from "redis";
import { config } from "../config/env.js";

let cliente = null;
let suscriptor = null;
let ultimoError = 0;

function registrarError(origen) {
    return (err) => {
        // una linea cada 30 s como mucho: un Redis caido no debe inundar el log
        if (Date.now() - ultimoError > 30000) {
            ultimoError = Date.now();
            console.error(`[cache] ${origen}: ${err.message} (se responde desde Oracle)`);
        }
    };
}

const opciones = () => ({
    url: config.redis.url,
    disableOfflineQueue: true,
    socket: { connectTimeout: 2000, reconnectStrategy: (intentos) => Math.min(200 * intentos, 5000) },
});

/**
 * Conecta sin bloquear el arranque (si Redis no esta, la API arranca igual).
 * alMensaje(texto): cada aviso del canal de cambios. alReconectar(): la
 * suscripcion se corto y volvio (pudo perder avisos: hay que limpiar memoria).
 */
export function iniciarRedis({ canal, alMensaje, alReconectar }) {
    if (!config.redis.url || cliente) return;
    cliente = createClient(opciones());
    cliente.on("error", registrarError("redis"));
    cliente.connect().catch(registrarError("redis"));

    suscriptor = createClient(opciones());
    suscriptor.on("error", registrarError("suscripcion"));
    suscriptor.on("ready", alReconectar);
    suscriptor
        .connect()
        .then(() => suscriptor.subscribe(canal, alMensaje))
        .catch(registrarError("suscripcion"));
}

export const redis = () => cliente;
export const redisListo = () => Boolean(cliente?.isReady);
export const suscripcionLista = () => Boolean(suscriptor?.isReady);

/** Un comando de Redis con tiempo maximo: si Redis se cuelga, se usa Oracle. */
export function conLimite(promesa, ms = 300) {
    let reloj;
    return Promise.race([
        promesa,
        new Promise((_, rechazar) => {
            reloj = setTimeout(() => rechazar(new Error(`Redis no respondio en ${ms} ms`)), ms);
        }),
    ]).finally(() => clearTimeout(reloj));
}

export async function cerrarRedis() {
    await Promise.allSettled([cliente?.quit(), suscriptor?.quit()]);
    cliente = null;
    suscriptor = null;
}
