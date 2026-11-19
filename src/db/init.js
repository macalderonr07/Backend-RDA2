// src/db/init.js
// CLI de un solo uso: crea/migra la tabla y la puebla con 1000 productos si
// esta vacia. Ejecutar con: npm run db:setup
// Flag --reset: vacia la tabla antes de volver a insertar.
// La logica vive en setup.js para que el servidor pueda reutilizarla cuando
// AUTO_SETUP=true (PaaS sin shell interactiva).
import { pool } from "../config/db.js";
import { prepararBaseDeDatos } from "./setup.js";

const reset = process.argv.includes("--reset");

prepararBaseDeDatos({ reset })
    .catch((err) => {
        console.error("Error inicializando la base de datos:", err);
        process.exitCode = 1;
    })
    .finally(() => pool.end());
