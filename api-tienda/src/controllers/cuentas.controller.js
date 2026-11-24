// src/controllers/cuentas.controller.js
// Cuentas de la tienda en linea (ecommerce.cuenta_web). La clave se procesa con
// scrypt en la API (la base solo guarda el hash) y cada intento de acceso queda
// en la bitacora de la base via fn_registrar_acceso_web, exitoso o no.
import { RespuestaFactory } from "../factories/respuesta.factory.js";
import { buscarCredenciales, buscarCuenta, registrarAcceso, registrarCuenta } from "../models/cuenta.model.js";
import { AppError } from "../utils/AppError.js";
import { crearHashClave, HASH_SENUELO, verificarClave } from "../utils/clave.js";

// POST /cuentas — registro: cliente en produccion + cuenta en e-commerce
export async function registrar(req, res, next) {
    try {
        const { nombres, apellidos, correo, telefono, clave } = req.body;
        const cuenta = await registrarCuenta({
            nombres,
            apellidos,
            correo,
            telefono,
            hashClave: await crearHashClave(clave),
            ip: req.ip ?? null,
        });
        res.status(201).json(RespuestaFactory.exito(cuenta));
    } catch (err) {
        next(err);
    }
}

// POST /cuentas/sesion — inicio de sesion. El mensaje de error es el mismo
// exista o no la cuenta (no se revela que correos estan registrados), y cuando
// no existe se verifica contra un hash senuelo para que tarde lo mismo.
export async function iniciarSesion(req, res, next) {
    try {
        const { correo, clave } = req.body;
        const credenciales = await buscarCredenciales(correo);
        const claveValida = await verificarClave(clave, credenciales?.hashClave ?? HASH_SENUELO);
        const exito = Boolean(credenciales) && claveValida && credenciales.activa;

        // La base registra el resultado (bitacora + ultimo acceso) y devuelve
        // la cuenta solo si el acceso vale y la cuenta esta activa.
        const idCuenta = await registrarAcceso(correo, exito ? 1 : 0, {
            sesion: req.correlationId ?? null,
            ip: req.ip ?? null,
            agente: req.get("user-agent") ?? null,
        });
        if (!exito || idCuenta == null) {
            throw new AppError("Correo o clave incorrectos", 401);
        }
        res.status(200).json(RespuestaFactory.exito(await buscarCuenta(correo)));
    } catch (err) {
        next(err);
    }
}
