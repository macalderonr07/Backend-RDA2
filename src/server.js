// src/server.js
// Punto de entrada: levanta el servidor HTTP en el puerto configurado.
import { app } from "./app.js";
import { pool } from "./config/db.js";
import { prepararBaseDeDatos } from "./db/setup.js";

const PORT = process.env.PORT || 5050;

const servidor = app.listen(PORT, () => {
    console.log(`API de Productos escuchando en http://localhost:${PORT}`);
});

// En PaaS sin shell (plan free de Render) no hay donde correr `npm run db:setup`.
// Con AUTO_SETUP=true la base se prepara sola al arrancar; es idempotente, asi
// que los reinicios no duplican datos. Se hace en segundo plano para que el
// health check (/ ) responda de inmediato.
if (process.env.AUTO_SETUP === "true") {
    prepararBaseDeDatos()
        .then((total) => console.log(`AUTO_SETUP: base lista con ${total} productos.`))
        .catch((err) => console.error("AUTO_SETUP: no se pudo preparar la base:", err.message));
}

// Render (y otros PaaS) mandan SIGTERM al reiniciar: cerramos ordenadamente
// para no dejar conexiones del pool colgadas.
process.on("SIGTERM", () => {
    console.log("SIGTERM recibido: cerrando servidor.");
    servidor.close(() => {
        pool.end().finally(() => process.exit(0));
    });
});
