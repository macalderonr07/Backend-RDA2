// cargar-cache.mjs — carga inicial de la cache: los 50.000 productos como
// documentos en Redis + la lista ordenada de codigos de cada categoria.
// Mide cuanto tarda y cuanta memoria ocupa.
import { cerrar, documentosPorIds, guardarEnCache, oracle, redis } from "./comun.mjs";

const r = await redis();
await r.flushAll();
const cn = await (await oracle()).getConnection();
const ids = (await cn.execute("SELECT id_producto FROM producto ORDER BY id_producto")).rows.map((f) => f[0]);
const categorias = (await cn.execute("SELECT id_categoria, prd_codigo FROM producto ORDER BY id_categoria, prd_codigo")).rows;
await cn.close();

const t0 = performance.now();
for (let i = 0; i < ids.length; i += 2000) {
    await guardarEnCache(await documentosPorIds(ids.slice(i, i + 2000)));
}
const multi = r.multi();
const porCategoria = new Map();
for (const [c, codigo] of categorias) {
    if (!porCategoria.has(c)) porCategoria.set(c, []);
    porCategoria.get(c).push(codigo);
}
for (const [c, codigos] of porCategoria) multi.del(`c:${c}`).rPush(`c:${c}`, codigos);
await multi.exec();
const ms = performance.now() - t0;
const memoria = (await r.info("memory")).match(/used_memory_human:(\S+)/)[1];
console.log(`CACHE|carga inicial|${ids.length} productos|${(ms / 1000).toFixed(1)} s|memoria Redis ${memoria}|${await r.dbSize()} claves`);
await cerrar();
