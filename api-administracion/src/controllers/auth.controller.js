// src/controllers/auth.controller.js
import { RespuestaFactory } from "../factories/respuesta.factory.js";
import { emitirToken } from "../middlewares/autenticacion.js";
import { cambiarClave, perfil, registrarAcceso, usuarioParaIngreso } from "../repositories/auth.repository.js";
import { AppError } from "../utils/AppError.js";
import { crearHashClave, HASH_SENUELO, verificarClave } from "../utils/clave.js";

// Mismo mensaje para correo inexistente, clave errada o usuario inactivo: no
// se revela que correos existen. El tiempo tambien es el mismo (senuelo).
const INGRESO_INVALIDO = "Correo o clave incorrectos";

// Cambio de clave: con una sesion abierta (un equipo sin bloquear) alguien
// podria probar claves actuales. Tras 5 fallos en 15 minutos se bloquea el
// cambio y se cierra la sesion. En memoria: basta para un solo proceso de la
// API (con varios, iria a la base o a un almacen compartido).
const INTENTOS = { maximo: 5, ventanaMs: 15 * 60 * 1000 };
const fallosCambio = new Map(); // idUsuario -> [marcas de tiempo]
function fallosRecientes(idUsuario) {
    const ahora = Date.now();
    const lista = (fallosCambio.get(idUsuario) ?? []).filter((t) => ahora - t < INTENTOS.ventanaMs);
    fallosCambio.set(idUsuario, lista);
    return lista;
}

export async function ingresar(req, res, next) {
    try {
        const { correo, clave } = req.body;
        const usuario = await usuarioParaIngreso(correo);
        const claveOk = await verificarClave(clave, usuario?.hashClave ?? HASH_SENUELO);
        const exito = Boolean(usuario && usuario.activo && claveOk);
        await registrarAcceso(correo, exito, req.ip);
        if (!exito) throw new AppError(INGRESO_INVALIDO, 401);
        const datos = await perfil(usuario.idUsuario);
        if (!datos) throw new AppError(INGRESO_INVALIDO, 401);
        res.status(200).json(RespuestaFactory.exito({ token: emitirToken(datos), usuario: datos }));
    } catch (err) {
        next(err);
    }
}

export function yo(req, res) {
    res.status(200).json(RespuestaFactory.exito(req.usuario));
}

export async function cambiarMiClave(req, res, next) {
    try {
        const { claveActual, claveNueva } = req.body;
        const id = req.usuario.idUsuario;
        if (fallosRecientes(id).length >= INTENTOS.maximo) {
            throw new AppError("Demasiados intentos con una clave actual incorrecta. Vuelve a iniciar sesión y espera 15 minutos.", 429);
        }
        const usuario = await usuarioParaIngreso(req.usuario.correo);
        if (!(await verificarClave(claveActual, usuario?.hashClave ?? HASH_SENUELO))) {
            fallosRecientes(id).push(Date.now());
            await registrarAcceso(req.usuario.correo, false, req.ip); // queda en la bitacora como intento fallido
            const quedan = INTENTOS.maximo - fallosRecientes(id).length;
            if (quedan <= 0) throw new AppError("Demasiados intentos con una clave actual incorrecta. Vuelve a iniciar sesión y espera 15 minutos.", 429);
            throw new AppError("La clave actual no es correcta", 422, [
                { campo: "claveActual", mensaje: `La clave actual no es correcta (te quedan ${quedan} intento${quedan === 1 ? "" : "s"})` },
            ]);
        }
        if (claveNueva === claveActual) {
            throw new AppError("La clave nueva debe ser distinta de la actual", 422, [{ campo: "claveNueva", mensaje: "La clave nueva debe ser distinta de la actual" }]);
        }
        const local = req.usuario.correo.split("@")[0].toLowerCase();
        if (local.length >= 4 && claveNueva.toLowerCase().includes(local)) {
            throw new AppError("La clave no debe contener tu correo", 422, [{ campo: "claveNueva", mensaje: "La clave no debe contener tu correo" }]);
        }
        await cambiarClave(id, await crearHashClave(claveNueva));
        fallosCambio.delete(id);
        // 204: el token con el que se pidio el cambio ya no vale (huella vieja);
        // el usuario vuelve a ingresar con la clave nueva, igual que sus otros equipos
        res.status(204).send();
    } catch (err) {
        next(err);
    }
}
