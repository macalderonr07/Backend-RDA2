// src/cache/catalogo.cache.js
// Lectura del catalogo con Redis de PRINCIPAL y Oracle de respaldo.
//
//   L1  memoria del proceso (Map LRU)     ~0 ms   invalidada por el canal de cambios
//   L2  Redis (un documento por producto)  ~1 ms   lo escribe SOLO el worker
//   --  Oracle (v_catalogo_web optimizada) respaldo: si Redis no esta, no termino
//       la carga, o le falta un documento (lo devuelve null y el controlador
//       consulta Oracle).
//
// Claves en Redis (prefijo configurable, por defecto "ce:"):
//   ce:prod:<codigo>   JSON del producto (igual que GET /productos/:codigo)
//   ce:indice          hash id_producto -> {codigo, nombre, linea, marca}:
//                      lo minimo para filtrar, ordenar y paginar el listado
//   ce:version         sube cuando cambia el indice (alta/baja/nombre/linea/marca)
//   ce:listo           "1" cuando la carga completa termino
//   ce:cambios         canal pub/sub: {codigos, indice} o {todo}
import { config } from "../config/env.js";
import { conLimite, iniciarRedis, redis, redisListo, suscripcionLista } from "./redis.js";

const P = config.redis.prefijo;
export const CLAVES = Object.freeze({
    producto: (codigo) => `${P}prod:${codigo}`,
    indice: `${P}indice`,
    version: `${P}version`,
    listo: `${P}listo`,
    candado: `${P}candado`,
    canal: `${P}cambios`,
    ultimaSincronia: `${P}ultima-sincronia`,
});

// ---------------------------------------------------------------- L1 (memoria)
// Solo se usa con la suscripcion activa: sin ella no llegarian los avisos de
// cambio y la memoria podria mostrar stock viejo.
const l1 = new Map();
const { l1Maximo, l1TtlMs } = config.redis;

function l1Leer(codigo) {
    const entrada = l1.get(codigo);
    if (!entrada) return undefined;
    l1.delete(codigo);
    if (entrada.vence < Date.now()) return undefined;
    l1.set(codigo, entrada); // al final: el mas usado sale ultimo (LRU)
    return entrada.producto;
}

function l1Guardar(codigo, producto) {
    l1.set(codigo, { producto, vence: Date.now() + l1TtlMs });
    if (l1.size > l1Maximo) l1.delete(l1.keys().next().value);
}

// Epoca: sube con cada aviso. Una lectura de Redis solo se guarda en memoria si
// no llego ningun aviso mientras leia (si no, podria guardar un dato ya viejo).
let epoca = 0;

let indiceLocal = null; // { version, lista: [{ codigo, nombre, linea, marca, busqueda }] }
let listo = false;
let listoRevisado = 0;

function alMensaje(texto) {
    epoca += 1;
    try {
        const aviso = JSON.parse(texto);
        if (aviso.todo) {
            l1.clear();
            indiceLocal = null;
            listoRevisado = 0;
            return;
        }
        for (const codigo of aviso.codigos ?? []) l1.delete(codigo);
        if (aviso.indice) indiceLocal = null;
    } catch {
        l1.clear();
        indiceLocal = null;
    }
}

function alReconectar() {
    epoca += 1;
    // mientras estuvo cortada pudieron perderse avisos: empezar de cero
    l1.clear();
    indiceLocal = null;
    listoRevisado = 0;
}

export function iniciarCache() {
    iniciarRedis({ canal: CLAVES.canal, alMensaje, alReconectar });
}

/** Redis conectado y con la carga completa hecha (se revisa cada 5 s). */
async function usable() {
    if (!redisListo()) return false;
    if (Date.now() - listoRevisado > 5000) {
        listo = (await conLimite(redis().get(CLAVES.listo))) === "1";
        listoRevisado = Date.now();
    }
    return listo;
}

// Misma comparacion que Oracle (COLLATE BINARY_AI): sin mayusculas ni tildes
export const normalizar = (texto) =>
    String(texto ?? "").normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase();

async function indiceActual() {
    const r = redis();
    // con suscripcion, un aviso borra indiceLocal cuando cambia; sin ella se
    // compara la version en cada listado
    if (indiceLocal && suscripcionLista()) return indiceLocal.lista;
    const version = await conLimite(r.get(CLAVES.version));
    if (indiceLocal && indiceLocal.version === version) return indiceLocal.lista;
    const hash = await conLimite(r.hGetAll(CLAVES.indice), 2000);
    const lista = Object.values(hash)
        .map((json) => JSON.parse(json))
        .map((e) => ({ ...e, busqueda: normalizar(e.nombre) }))
        // orden binario por codigo, como el ORDER BY de Oracle
        .sort((a, b) => (a.codigo < b.codigo ? -1 : a.codigo > b.codigo ? 1 : 0));
    indiceLocal = { version, lista };
    return lista;
}

const sinPiezas = ({ piezas: _piezas, ...resto }) => resto; // el listado no trae piezas

/**
 * Producto por codigo. { producto, fuente: "MEMORIA" | "REDIS" } o null si hay
 * que leerlo de Oracle (cache no disponible o documento ausente).
 */
export async function productoDesdeCache(codigo) {
    try {
        if (!(await usable())) return null;
        if (suscripcionLista()) {
            const enMemoria = l1Leer(codigo);
            if (enMemoria) return { producto: enMemoria, fuente: "MEMORIA" };
        }
        const desde = epoca;
        const json = await conLimite(redis().get(CLAVES.producto(codigo)));
        if (!json) return null;
        const producto = JSON.parse(json);
        if (suscripcionLista() && desde === epoca) l1Guardar(codigo, producto);
        return { producto, fuente: "REDIS" };
    } catch {
        return null;
    }
}

/**
 * Pagina del catalogo con los mismos filtros, orden y total que Oracle.
 * { productos, total, fuente } o null si hay que ir a Oracle.
 */
export async function listadoDesdeCache({ linea = null, marca = null, q = null, limit, offset }) {
    try {
        if (!(await usable())) return null;
        const patron = q ? normalizar(q) : null;
        const filtrados = (await indiceActual()).filter(
            (e) => (!linea || e.linea === linea) && (!marca || e.marca === marca) && (!patron || e.busqueda.includes(patron))
        );
        const pagina = filtrados.slice(offset, offset + limit).map((e) => e.codigo);

        const conMemoria = suscripcionLista();
        const productos = pagina.map((codigo) => (conMemoria ? l1Leer(codigo) : undefined));
        const faltan = pagina.filter((_, i) => !productos[i]);
        let fuente = "MEMORIA";
        if (faltan.length) {
            fuente = "REDIS";
            const desde = epoca;
            // un solo viaje a Redis para todos los que no estaban en memoria
            const jsons = await conLimite(redis().mGet(faltan.map(CLAVES.producto)));
            if (jsons.some((j) => !j)) return null; // indice y documentos desfasados: Oracle
            const leidos = new Map(faltan.map((codigo, i) => [codigo, JSON.parse(jsons[i])]));
            pagina.forEach((codigo, i) => {
                if (!productos[i]) {
                    productos[i] = leidos.get(codigo);
                    if (conMemoria && desde === epoca) l1Guardar(codigo, productos[i]);
                }
            });
        }
        return { productos: productos.map(sinPiezas), total: filtrados.length, fuente };
    } catch {
        return null;
    }
}

/** Para /salud: estado de la cache sin exponer detalles internos. */
export async function estadoCache() {
    if (!config.redis.url) return { estado: "desactivada" };
    if (!redisListo()) return { estado: "sin conexion (se responde desde Oracle)" };
    try {
        const [marca, ultima] = await conLimite(redis().mGet([CLAVES.listo, CLAVES.ultimaSincronia]));
        if (marca !== "1") return { estado: "cargando (se responde desde Oracle)" };
        // La reconstruccion completa corre cada CACHE_RECONCILIAR_MIN: sin ninguna
        // sincronia en el doble de ese tiempo, el worker esta fallando (ver logs).
        const minutos = ultima ? Math.floor((Date.now() - Number(ultima)) / 60000) : null;
        if (minutos !== null && minutos > 2 * config.redis.reconciliarCadaMin) {
            return {
                estado: `desactualizada: sin sincronizar hace ${minutos} min (revisar los logs de la API)`,
                ultimaSincronia: new Date(Number(ultima)).toISOString(),
            };
        }
        return {
            estado: "ok",
            ultimaSincronia: ultima ? new Date(Number(ultima)).toISOString() : null,
            memoria: suscripcionLista() ? "activa" : "desactivada (sin suscripcion)",
        };
    } catch {
        return { estado: "sin respuesta (se responde desde Oracle)" };
    }
}
