// scripts/verificar.mjs
// Verificacion local y de CI, sin base de datos:
//   1. Sintaxis de todos los .js de src/ y scripts/ (node --check).
//   2. Arranque real de la app en un puerto efimero con peticiones de humo:
//      salud, validacion de entrada, 404, CORS y correlacion.
// Uso: npm run verificar   (lo corre tambien GitHub Actions)
import { spawnSync } from "node:child_process";
import { readdirSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const RAIZ = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const ORIGEN_PRUEBA = "http://localhost:5500";
let fallos = 0;

function ok(mensaje, detalle = "") {
    console.log(`  ✓ ${mensaje}${detalle ? ` (${detalle})` : ""}`);
}

function fallo(mensaje, detalle = "") {
    fallos += 1;
    console.error(`  ✗ ${mensaje}${detalle ? ` — ${detalle}` : ""}`);
}

function revisar(mensaje, condicion, detalle = "") {
    if (condicion) ok(mensaje, detalle);
    else fallo(mensaje, detalle);
}

function archivosJs(directorio) {
    return readdirSync(directorio).flatMap((entrada) => {
        const ruta = path.join(directorio, entrada);
        if (statSync(ruta).isDirectory()) return archivosJs(ruta);
        return ruta.endsWith(".js") ? [ruta] : [];
    });
}

// 1) Sintaxis: barato y atrapa errores que un import dinamico no siempre ve.
console.log("Sintaxis:");
const js = [...archivosJs(path.join(RAIZ, "src")), ...archivosJs(path.join(RAIZ, "scripts"))].filter(
    (archivo) => path.basename(archivo) !== "verificar.mjs"
);
for (const archivo of js) {
    const relativo = path.relative(RAIZ, archivo);
    const resultado = spawnSync(process.execPath, ["--check", archivo], { encoding: "utf8" });
    revisar(relativo, resultado.status === 0, (resultado.stderr ?? "").trim().split("\n")[0]);
}

// 2) Humo HTTP: se levanta la app de verdad, pero sin tocar PostgreSQL
//    (las rutas validas no se consultan: solo salud, validacion y 404).
console.log("Humo HTTP:");
process.env.CLIENT_ORIGIN = ORIGEN_PRUEBA;
process.env.PORT = "0";
const { app } = await import("../src/app.js");
const { pool } = await import("../src/config/db.js");

const servidor = app.listen(0);
await new Promise((resolver, rechazar) => {
    servidor.once("listening", resolver);
    servidor.once("error", rechazar);
});
const base = `http://127.0.0.1:${servidor.address().port}`;

async function pedir(ruta, opciones = {}) {
    const respuesta = await fetch(base + ruta, {
        ...opciones,
        signal: AbortSignal.timeout(5000),
    });
    const tipo = respuesta.headers.get("content-type") ?? "";
    const cuerpo = tipo.includes("application/json") ? await respuesta.json() : null;
    return { respuesta, cuerpo };
}

try {
    const { respuesta: salud, cuerpo: cuerpoSalud } = await pedir("/");
    revisar("GET / responde 200", salud.status === 200, `status ${salud.status}`);
    revisar("GET / devuelve status success", cuerpoSalud?.status === "success");
    revisar("GET / expone la version v1", cuerpoSalud?.version === "v1");

    const { respuesta: invalido, cuerpo: cuerpoInvalido } = await pedir("/api/v1/productos/abc");
    revisar("id invalido responde 422", invalido.status === 422, `status ${invalido.status}`);
    revisar(
        "id invalido explica el campo",
        Array.isArray(cuerpoInvalido?.detalles) && cuerpoInvalido.detalles[0]?.campo === "id"
    );

    const { respuesta: inexistente } = await pedir("/ruta/que/no/existe");
    revisar("ruta desconocida responde 404", inexistente.status === 404, `status ${inexistente.status}`);

    const { respuesta: conOrigen } = await pedir("/", { headers: { Origin: ORIGEN_PRUEBA } });
    revisar(
        "CORS permite el origen configurado",
        conOrigen.headers.get("access-control-allow-origin") === ORIGEN_PRUEBA,
        conOrigen.headers.get("access-control-allow-origin") ?? "sin cabecera"
    );
    revisar("respuesta trae x-correlation-id", Boolean(conOrigen.headers.get("x-correlation-id")));

    const { respuesta: preflight } = await pedir("/api/v1/productos", { method: "OPTIONS", headers: {
        Origin: ORIGEN_PRUEBA,
        "Access-Control-Request-Method": "POST",
        "Access-Control-Request-Headers": "content-type",
    } });
    revisar("preflight OPTIONS responde 204", preflight.status === 204, `status ${preflight.status}`);
    // Los metodos permitidos viajan en el preflight; en un GET no aplican.
    revisar(
        "preflight anuncia los metodos REST",
        (preflight.headers.get("access-control-allow-methods") ?? "").includes("PUT"),
        preflight.headers.get("access-control-allow-methods") ?? "sin cabecera"
    );
} finally {
    servidor.close();
    // El pool nunca se conecto (no hubo queries validas), pero cerrarlo deja
    // el proceso limpio para que CI no quede colgado.
    await pool.end().catch(() => {});
}

if (fallos > 0) {
    console.error(`\n${fallos} verificacion(es) fallaron.`);
    process.exit(1);
}
console.log("\nTodo en orden.");
