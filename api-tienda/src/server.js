// src/server.js
// Punto de entrada: abre el pool de Oracle ANTES de escuchar (si la base no
// responde, el proceso no arranca a medias) y lo cierra al apagar.
import { app } from "./app.js";
import { iniciarCache } from "./cache/catalogo.cache.js";
import { cerrarRedis } from "./cache/redis.js";
import { detenerSincronizador, iniciarSincronizador } from "./cache/sincronizador.js";
import { db } from "./config/db.js";
import { config } from "./config/env.js";

try {
    await db.iniciar();
} catch (err) {
    console.error("No se pudo conectar a Oracle:", err.message);
    process.exit(1);
}

// Redis no bloquea el arranque: si no esta, se responde desde Oracle
iniciarCache();
iniciarSincronizador();

const servidor = app.listen(config.port, () => {
    console.log(`API Comercial Elite escuchando en http://localhost:${config.port}`);
});

async function apagar(senal) {
    console.log(`${senal}: cerrando servidor y pool de Oracle...`);
    servidor.close();
    await detenerSincronizador().catch(() => {});
    await cerrarRedis();
    await db.cerrar().catch((err) => console.error("Error al cerrar el pool:", err.message));
    process.exit(0);
}

process.on("SIGINT", apagar);
process.on("SIGTERM", apagar);
