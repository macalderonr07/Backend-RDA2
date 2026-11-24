// carga.mjs — prueba de carga contra el backend de simulacion.
// Por cada camino (anterior, optimizada, cache) y cada consulta (ficha de
// producto, pagina de categoria): CONCURRENCIA clientes simultaneos durante
// DURACION segundos, con productos y categorias al azar (los mismos en todos
// los caminos). Informa peticiones/s y latencias p50, p95, p99.
const BASE = process.env.BACKEND ?? "http://localhost:7070";
const CONCURRENCIA = Number(process.env.CONCURRENCIA ?? 32);
const DURACION = Number(process.env.DURACION ?? 15);
const caminos = (process.env.CAMINOS ?? "anterior,optimizada,cache").split(",");

function azar(semilla) {
    let s = semilla;
    return () => ((s = (s * 1103515245 + 12345) % 2147483648) / 2147483648);
}
const rutas = {
    producto: (r) => `producto/CE-${100001 + Math.floor(r() * 50000)}`,
    categoria: (r) => `categoria/${11 + Math.floor(r() * 50)}/${1 + Math.floor(r() * 20)}`,
};
const percentil = (xs, p) => xs[Math.min(xs.length - 1, Math.floor((p / 100) * xs.length))];

async function escenario(camino, recurso) {
    const latencias = [];
    let errores = 0;
    const fin = Date.now() + DURACION * 1000;
    await Promise.all(Array.from({ length: CONCURRENCIA }, async (_, k) => {
        const r = azar(1000 + k);
        while (Date.now() < fin) {
            const t0 = performance.now();
            try {
                const res = await fetch(`${BASE}/${camino}/${rutas[recurso](r)}`);
                await res.arrayBuffer();
                if (!res.ok) errores += 1;
            } catch {
                errores += 1;
            }
            latencias.push(performance.now() - t0);
        }
    }));
    latencias.sort((a, b) => a - b);
    const rps = latencias.length / DURACION;
    console.log(`CARGA|${camino}|${recurso}|${latencias.length} peticiones|${rps.toFixed(1)} req/s|p50 ${percentil(latencias, 50).toFixed(1)} ms|p95 ${percentil(latencias, 95).toFixed(1)} ms|p99 ${percentil(latencias, 99).toFixed(1)} ms|errores ${errores}`);
}

for (const recurso of ["producto", "categoria"]) {
    for (const camino of caminos) await escenario(camino, recurso);
}
