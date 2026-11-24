// src/utils/clave.js
// Hash de claves con scrypt (node:crypto, sin dependencias nuevas). La base
// solo guarda el hash (cuenta_web.cwe_hash_clave): la clave en claro nunca se
// almacena ni se loguea. Formato autodescriptivo para poder subir el costo en
// el futuro sin invalidar los hashes viejos:
//   scrypt$N$r$p$<sal base64>$<hash base64>   (<= 255, cabe en VARCHAR2(255))
import { randomBytes, randomUUID, scrypt, timingSafeEqual } from "node:crypto";
import { promisify } from "node:util";

const scryptAsync = promisify(scrypt);

// Parametros recomendados por OWASP para scrypt interactivo
const COSTO = { N: 16384, r: 8, p: 1 };
const BYTES_SAL = 16;
const BYTES_HASH = 32;

export async function crearHashClave(clave) {
    const sal = randomBytes(BYTES_SAL);
    const hash = await scryptAsync(clave, sal, BYTES_HASH, { ...COSTO, maxmem: 64 * 1024 * 1024 });
    return ["scrypt", COSTO.N, COSTO.r, COSTO.p, sal.toString("base64"), hash.toString("base64")].join("$");
}

export async function verificarClave(clave, hashGuardado) {
    try {
        const [algoritmo, N, r, p, salB64, hashB64] = String(hashGuardado).split("$");
        if (algoritmo !== "scrypt") return false;
        const esperado = Buffer.from(hashB64, "base64");
        const sal = Buffer.from(salB64, "base64");
        const calculado = await scryptAsync(clave, sal, esperado.length, {
            N: Number(N),
            r: Number(r),
            p: Number(p),
            maxmem: 64 * 1024 * 1024,
        });
        return esperado.length > 0 && timingSafeEqual(esperado, calculado);
    } catch {
        return false;
    }
}

// Hash de una clave aleatoria que nadie conoce: cuando el correo no tiene
// cuenta, el login verifica contra este senuelo para que la peticion tarde lo
// mismo que con una cuenta real (no se puede adivinar que correos existen
// midiendo tiempos).
export const HASH_SENUELO = await crearHashClave(randomUUID());
