// scripts/comparar-cache.mjs
// Comprueba que la cache responde EXACTAMENTE lo mismo que Oracle.
// Levanta una segunda instancia de la API solo con Oracle (REDIS_URL=off) y
// compara, contra la API normal (Redis), el detalle de TODOS los productos y
// el listado con varias combinaciones de filtros, paginas y busquedas.
// Uso: npm run comparar-cache   (con la API normal ya corriendo en :5050)
import { spawn } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const CACHE = process.env.API_URL ?? "http://localhost:5050/api/v1";
const PUERTO_ORACLE = 5099;
const ORACLE = `http://localhost:${PUERTO_ORACLE}/api/v1`;
const raiz = resolve(dirname(fileURLToPath(import.meta.url)), "..");

const soloOracle = spawn(process.execPath, ["src/server.js"], {
    cwd: raiz,
    env: { ...process.env, PORT: String(PUERTO_ORACLE), REDIS_URL: "off", CACHE_WORKER: "off" },
    stdio: "ignore",
});
const terminar = (codigo) => {
    soloOracle.kill();
    process.exit(codigo);
};

async function pedir(base, ruta) {
    const r = await fetch(base + ruta);
    return { status: r.status, cache: r.headers.get("x-cache"), cuerpo: await r.text() };
}

for (let i = 0; i < 50; i++) {
    try {
        if ((await fetch(`${ORACLE}/salud`)).ok) break;
    } catch {
        /* todavia arrancando */
    }
    await new Promise((ok) => setTimeout(ok, 200));
}

let comparadas = 0;
const diferencias = [];
const fuentes = {};
async function comparar(ruta) {
    const [a, b] = await Promise.all([pedir(CACHE, ruta), pedir(ORACLE, ruta)]);
    comparadas += 1;
    fuentes[a.cache] = (fuentes[a.cache] ?? 0) + 1;
    if (a.status !== b.status || a.cuerpo !== b.cuerpo) diferencias.push({ ruta, cache: a.cache, a: a.cuerpo.slice(0, 300), b: b.cuerpo.slice(0, 300) });
}

const todos = JSON.parse((await pedir(ORACLE, "/productos?limit=100")).cuerpo);
const productos = todos.data;
const lineas = [...new Set(productos.map((p) => p.linea.codigo))];
const marcas = [...new Set(productos.map((p) => p.marca).filter(Boolean))];

for (const p of productos) await comparar(`/productos/${encodeURIComponent(p.codigo)}`);
await comparar("/productos/NO-EXISTE");
for (const limit of [1, 5, 12, 100]) for (const page of [1, 2, 3]) await comparar(`/productos?limit=${limit}&page=${page}`);
for (const linea of lineas) await comparar(`/productos?linea=${encodeURIComponent(linea)}&limit=50`);
for (const marca of marcas) await comparar(`/productos?marca=${encodeURIComponent(marca)}&limit=50`);
// busquedas: sin tildes/mayusculas, comodines literales, sin resultados
for (const q of ["cuero", "CUERO", "sintetico", "Sintético", "suela", "a", "%", "_", "zzzz", productos[0].nombre.slice(0, 5)]) {
    await comparar(`/productos?q=${encodeURIComponent(q)}&limit=50`);
}
if (lineas[0] && marcas[0]) await comparar(`/productos?linea=${encodeURIComponent(lineas[0])}&marca=${encodeURIComponent(marcas[0])}`);

console.log(`Comparadas ${comparadas} respuestas cache vs Oracle (fuentes de la cache: ${JSON.stringify(fuentes)})`);
if (diferencias.length) {
    for (const d of diferencias.slice(0, 5)) console.error(`  ✖ ${d.ruta} [${d.cache}]\n    cache : ${d.a}\n    oracle: ${d.b}`);
    console.error(`✖ ${diferencias.length} diferencias`);
    terminar(1);
}
console.log("✔ la cache responde identico a Oracle");
terminar(0);
