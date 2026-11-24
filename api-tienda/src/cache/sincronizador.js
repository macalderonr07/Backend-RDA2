// src/cache/sincronizador.js
// Worker que mantiene Redis igual a Oracle (Oracle es la fuente de verdad).
//
// Cada CACHE_INTERVALO_MS (200 ms):
//   1. lee la outbox produccion.catalogo_cambio (la llenan triggers y un job);
//   2. reconstruye SOLO esos productos desde v_catalogo_web (vista optimizada);
//   3. los escribe en Redis en una transaccion MULTI (documento + indice);
//   4. avisa por el canal de cambios (cada instancia limpia su memoria);
//   5. borra de la outbox lo procesado.
// Si el proceso cae entre 3 y 5, al volver reprocesa esos cambios: escribir
// dos veces el mismo documento no hace dano (idempotente). Nunca se pierde un
// cambio porque la outbox vive en Oracle, en la misma transaccion del negocio.
//
// Carga completa: al arrancar (o si Redis se vacio) y cada CACHE_RECONCILIAR_MIN
// como red de seguridad. Varias instancias de la API: solo trabaja la que tiene
// el candado en Redis.
import { randomUUID } from "node:crypto";
import { db } from "../config/db.js";
import { config } from "../config/env.js";
import { idsPublicados, productosPorIds } from "../models/producto.model.js";
import { CLAVES } from "./catalogo.cache.js";
import { redis, redisListo } from "./redis.js";

const INSTANCIA = randomUUID();
const CANDADO_MS = 30000;
let activo = false;
let ultimaReconciliacion = 0;
let enCurso = null;

// Toma o renueva el candado de forma atomica (solo si es nuestro o esta libre)
const LUA_CANDADO = `
if redis.call('get', KEYS[1]) == ARGV[1] then
    return redis.call('pexpire', KEYS[1], ARGV[2])
end
if redis.call('set', KEYS[1], ARGV[1], 'NX', 'PX', ARGV[2]) then return 1 end
return 0`;

const tomarCandado = async () =>
    (await redis().eval(LUA_CANDADO, { keys: [CLAVES.candado], arguments: [INSTANCIA, String(CANDADO_MS)] })) === 1;

const entradaIndice = (id, p) =>
    JSON.stringify({ id, codigo: p.codigo, nombre: p.nombre, linea: p.linea.codigo, marca: p.marca ?? null });

/** Reconstruye estos productos en Redis. Devuelve cuantos documentos escribio. */
async function aplicar(ids) {
    const r = redis();
    const documentos = await productosPorIds(ids);
    const anteriores = await r.hmGet(CLAVES.indice, ids.map(String));
    const anteriorPorId = new Map(ids.map((id, i) => [id, anteriores[i] ? JSON.parse(anteriores[i]) : null]));

    const multi = r.multi();
    const codigos = new Set();
    let indiceCambio = false;
    const presentes = new Set();
    for (const { id, producto } of documentos) {
        presentes.add(id);
        codigos.add(producto.codigo);
        multi.set(CLAVES.producto(producto.codigo), JSON.stringify(producto));
        const entrada = entradaIndice(id, producto);
        const anterior = anteriorPorId.get(id);
        if (JSON.stringify(anterior) !== entrada) {
            multi.hSet(CLAVES.indice, String(id), entrada);
            indiceCambio = true;
            if (anterior && anterior.codigo !== producto.codigo) {
                multi.del(CLAVES.producto(anterior.codigo));
                codigos.add(anterior.codigo);
            }
        }
    }
    // los que ya no salen en v_catalogo_web (despublicados, sin presentaciones activas...)
    for (const id of ids) {
        const anterior = anteriorPorId.get(id);
        if (!presentes.has(id) && anterior) {
            multi.del(CLAVES.producto(anterior.codigo));
            multi.hDel(CLAVES.indice, String(id));
            codigos.add(anterior.codigo);
            indiceCambio = true;
        }
    }
    if (indiceCambio) multi.incr(CLAVES.version);
    multi.set(CLAVES.ultimaSincronia, String(Date.now()));
    await multi.exec();
    if (codigos.size) await r.publish(CLAVES.canal, JSON.stringify({ codigos: [...codigos], indice: indiceCambio }));
    return documentos.length;
}

/** Carga completa: todos los productos publicados, e indice nuevo de una vez. */
async function cargaCompleta(motivo) {
    const r = redis();
    const inicio = Date.now();
    // lo anotado HASTA aqui queda cubierto por esta carga; lo que llegue despues, por el ciclo normal
    const { rows } = await db.ejecutar("SELECT NVL(MAX(id_cambio), 0) AS maximo FROM produccion.catalogo_cambio");
    const hasta = rows[0].MAXIMO;

    const documentos = await productosPorIds(await idsPublicados());
    for (let i = 0; i < documentos.length; i += 1000) {
        const tramo = r.multi();
        for (const { producto } of documentos.slice(i, i + 1000)) tramo.set(CLAVES.producto(producto.codigo), JSON.stringify(producto));
        await tramo.exec();
        await tomarCandado(); // renovar en cargas largas
    }
    const vigentes = new Set(documentos.map(({ producto }) => producto.codigo));
    const viejos = Object.values(await r.hGetAll(CLAVES.indice))
        .map((json) => JSON.parse(json).codigo)
        .filter((codigo) => !vigentes.has(codigo));

    const multi = r.multi().del(CLAVES.indice);
    if (documentos.length) {
        multi.hSet(CLAVES.indice, Object.fromEntries(documentos.map(({ id, producto }) => [String(id), entradaIndice(id, producto)])));
    }
    for (const codigo of viejos) multi.del(CLAVES.producto(codigo));
    multi.incr(CLAVES.version).set(CLAVES.listo, "1").set(CLAVES.ultimaSincronia, String(Date.now()));
    await multi.exec();
    await r.publish(CLAVES.canal, JSON.stringify({ todo: true }));

    await db.ejecutar("DELETE FROM produccion.catalogo_cambio WHERE id_cambio <= :hasta", { hasta }, { autoCommit: true });
    ultimaReconciliacion = Date.now();
    console.log(`[cache] carga completa (${motivo}): ${documentos.length} productos en ${Date.now() - inicio} ms`);
}

async function paso() {
    if (!redisListo() || !(await tomarCandado())) return;
    const r = redis();
    if ((await r.get(CLAVES.listo)) !== "1") return cargaCompleta("Redis sin catalogo");
    if (Date.now() - ultimaReconciliacion > config.redis.reconciliarCadaMin * 60000) return cargaCompleta("reconciliacion periodica");

    const { rows } = await db.ejecutar(
        "SELECT id_cambio, id_producto FROM produccion.catalogo_cambio ORDER BY id_cambio FETCH FIRST 2000 ROWS ONLY"
    );
    if (!rows.length) return;
    const ids = [...new Set(rows.map((f) => f.ID_PRODUCTO))];
    const inicio = Date.now();
    const escritos = await aplicar(ids);
    if (process.env.CACHE_DEBUG) console.log(`[cache] ${rows.length} cambios -> ${escritos} productos reconstruidos en ${Date.now() - inicio} ms`);
    await db.ejecutar("DELETE FROM produccion.catalogo_cambio WHERE id_cambio <= :hasta", { hasta: rows.at(-1).ID_CAMBIO }, { autoCommit: true });
}

async function bucle() {
    while (activo) {
        enCurso = paso().catch((err) => console.error(`[cache] sincronia: ${err.message}`));
        await enCurso;
        await new Promise((listo) => setTimeout(listo, config.redis.intervaloSincronia));
    }
}

export function iniciarSincronizador() {
    if (!config.redis.url || !config.redis.worker || activo) return;
    activo = true;
    bucle();
}

export async function detenerSincronizador() {
    activo = false;
    await enCurso;
    // soltar el candado si es nuestro: otra instancia toma el relevo al instante
    if (redisListo()) {
        await redis()
            .eval("if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) end return 0", {
                keys: [CLAVES.candado],
                arguments: [INSTANCIA],
            })
            .catch(() => {});
    }
}
