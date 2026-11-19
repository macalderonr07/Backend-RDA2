// src/config/db.js
// Pool de conexiones a PostgreSQL. Las credenciales salen de variables de
// entorno (ver .env.example) para no commitear secretos.
// NOTA: usamos ruta ABSOLUTA al .env (basada en import.meta.url) en vez de
// "dotenv/config" a secas, porque ese shorthand busca el .env relativo al
// cwd del proceso: si se arranca "node server.js" parado dentro de src/,
// no encuentra el .env de la raiz del proyecto y las credenciales quedan
// undefined (el pool intenta conectar con defaults y falla con 500).
// En produccion (Render) dotenv no encuentra archivo y no pasa nada: las
// variables llegan inyectadas por la plataforma.
import path from "path";
import { fileURLToPath } from "url";
import dotenv from "dotenv";
import pg from "pg";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: path.join(__dirname, "..", "..", ".env") });

const { Pool } = pg;

// pg devuelve NUMERIC como string (para no perder precision). La columna
// pvp vive bien como float en JSON, asi que forzamos el parseo aqui
// una sola vez en lugar de convertir en cada query del modelo.
const OID_NUMERIC = 1700;
pg.types.setTypeParser(OID_NUMERIC, (valor) => parseFloat(valor));

// Dos formas de configurar la conexion, en este orden:
//  1. DATABASE_URL: una sola cadena, es lo que entregan Render/Railway/Heroku.
//  2. Variables PG* sueltas: comodo en desarrollo local (ver .env.example).
// SSL solo cuando la cadena o PGSSL lo piden (Render interno no usa SSL;
// una base externa si). rejectUnauthorized:false porque el certificado de
// varios PaaS es gestionado por la plataforma, no por una CA del contenedor.
const cadenaDeConexion = process.env.DATABASE_URL;
const usaSsl = Boolean(cadenaDeConexion)
    ? /sslmode=(require|verify-full)/i.test(cadenaDeConexion) || process.env.PGSSL === "true"
    : process.env.PGSSL === "true";

export const pool = new Pool(
    cadenaDeConexion
        ? {
              connectionString: cadenaDeConexion,
              ssl: usaSsl ? { rejectUnauthorized: false } : undefined,
          }
        : {
              host: process.env.PGHOST,
              port: Number(process.env.PGPORT) || 5432,
              user: process.env.PGUSER,
              password: process.env.PGPASSWORD,
              database: process.env.PGDATABASE,
              ssl: usaSsl ? { rejectUnauthorized: false } : undefined,
          }
);

pool.on("error", (err) => {
    console.error("Error inesperado en el pool de PostgreSQL:", err);
});
