// scripts/medir-cache.mjs
// Carga contra la API REAL de la tienda: la instancia normal (Redis principal)
// contra una instancia solo-Oracle (REDIS_URL=off) que este script levanta.
// CONCURRENCIA clientes durante DURACION s por escenario: listado del catalogo
// (paginas al azar) y ficha de producto (codigos al azar).
// Uso: npm run medir-cache   (con la API normal corriendo en :5050)
import { spawn } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const CACHE = process.env.API_URL ?? "http://localhost:5050/api/v1";
const PUERTO_ORACLE = 5099;
const ORACLE = `http://localhost:${PUERTO_ORACLE}/api/v1`;
const CONCURRENCIA = Number(process.env.CONCURRENCIA ?? 32);
const DURACION = Number(process.env.DURACION ?? 10);
const raiz = resolve(dirname(fileURLToPath(import.meta.url)), "..");

const soloOracle = spawn(process.execPath, ["src/server.js"], {
    cwd: raiz,
    // sin log por peticion en las dos instancias (morgan) seria lo justo; ambas lo tienen igual
    env: { ...process.env, PORT: String(PUERTO_ORACLE), REDIS_URL: "off", CACHE_WORKER: "off" },
    stdio: "ignore",
});
for (let i = 0; i < 50; i++) {
    try {
        if ((await fetch(`${ORACLE}/salud`)).ok) break;
    } catch {
        /* arrancando */
    }
    await new Promise((ok) => setTimeout(ok, 200));
}

const codigos = (await (await fetch(`${ORACLE}/productos?limit=100`)).json()).data.map((p) => p.codigo);
const paginas = Math.ceil(codigos.length / 12);
const rutas = {
    "listado (12 por pagina)": (k) => `/productos?limit=12&page=${1 + (k % paginas)}`,
    "ficha de producto": (k) => `/productos/${encodeURIComponent(codigos[(k * 7) % codigos.length])}`,
};
const percentil = (xs, p) => xs[Math.min(xs.length - 1, Math.floor((p / 100) * xs.length))];

async function escenario(base, ruta) {
    const latencias = [];
    let errores = 0;
    let k = 0;
    const fin = Date.now() + DURACION * 1000;
    await Promise.all(
        Array.from({ length: CONCURRENCIA }, async () => {
            while (Date.now() < fin) {
                const t0 = performance.now();
                try {
                    const r = await fetch(base + ruta(k++));
                    await r.arrayBuffer();
                    if (!r.ok) errores += 1;
                } catch {
                    errores += 1;
                }
                latencias.push(performance.now() - t0);
            }
        })
    );
    latencias.sort((a, b) => a - b);
    return { rps: latencias.length / DURACION, p50: percentil(latencias, 50), p95: percentil(latencias, 95), errores };
}

console.log(`API real, ${CONCURRENCIA} clientes, ${DURACION} s por escenario, ${codigos.length} productos\n`);
console.log("| Consulta | Camino | req/s | p50 | p95 | errores |\n|---|---|---|---|---|---|");
for (const [nombre, ruta] of Object.entries(rutas)) {
    for (const [camino, base] of [["Oracle optimizado", ORACLE], ["Redis + memoria", CACHE]]) {
        const m = await escenario(base, ruta);
        console.log(`| ${nombre} | ${camino} | ${m.rps.toFixed(0)} | ${m.p50.toFixed(1)} ms | ${m.p95.toFixed(1)} ms | ${m.errores} |`);
    }
}
soloOracle.kill();
