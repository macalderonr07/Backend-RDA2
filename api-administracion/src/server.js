// src/server.js — verifica la conexion antes de escuchar y la cierra al salir.
import { app } from "./app.js";
import { sequelize } from "./config/db.js";
import { config } from "./config/env.js";

try {
    await sequelize.authenticate();
} catch (err) {
    console.error("No se pudo conectar a Oracle:", err.message);
    process.exit(1);
}

const servidor = app.listen(config.port, () => {
    console.log(`API de administracion escuchando en http://localhost:${config.port}`);
});

async function cerrar(senal) {
    console.log(`${senal}: cerrando...`);
    servidor.close();
    await sequelize.close();
    process.exit(0);
}
process.on("SIGINT", () => cerrar("SIGINT"));
process.on("SIGTERM", () => cerrar("SIGTERM"));
