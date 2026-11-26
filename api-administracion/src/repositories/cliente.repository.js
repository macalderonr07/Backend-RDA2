// src/repositories/cliente.repository.js
// Clientes para la VENTA: buscar por nombre, cedula/RUC o telefono, y dar de
// alta sin salir de la venta (cliente + telefono + datos de facturacion +
// direccion, todo en UNA transaccion). Las identificaciones viven en
// datos_facturacion (un cliente puede facturar como persona y como empresa).
import { conUsuario, consulta, ESQUEMA, llamar } from "../config/db.js";
import { m } from "../models/index.js";
import { AppError } from "../utils/AppError.js";

// matchedData puede traer { direccion: {} } aunque no se haya enviado: una
// direccion "vino" solo si trae su calle
const conDireccion = (d) => (d?.callePrincipal ? d : null);

const CONSUMIDOR_FINAL = { idTipoIdentificacion: "07", identificacion: "9999999999999", razonSocial: "CONSUMIDOR FINAL" };

/** Ficha del cliente para la venta: telefonos, datos de facturacion y direcciones activos. */
export async function ficha(idCliente, transaction) {
    const c = await m.Cliente.findByPk(idCliente, { transaction });
    if (!c) return null;
    const [telefonos, facturacion, direcciones] = await Promise.all([
        m.Telefono.findAll({ where: { idCliente }, transaction }),
        m.DatosFacturacion.findAll({ where: { idCliente, activo: 1 }, order: [["idDatosFacturacion", "ASC"]], transaction }),
        consulta(
            `SELECT d.id_direccion, d.dir_calle_principal, d.dir_numero, d.dir_calle_secundaria, d.dir_referencia, ci.ciu_nombre AS ciudad,
                    d.id_sector, se.sec_nombre AS sector
             FROM ${ESQUEMA}.direccion d JOIN ${ESQUEMA}.ciudad ci ON ci.id_ciudad = d.id_ciudad
             LEFT JOIN ${ESQUEMA}.sector se ON se.id_sector = d.id_sector
             WHERE d.id_cliente = :c AND d.dir_activa = 1 ORDER BY d.id_direccion DESC`,
            { c: idCliente },
            transaction
        ),
    ]);
    const idsSector = [...new Set(facturacion.map((d) => d.idSector).filter(Boolean))];
    const sectores = new Map(idsSector.length
        ? (await consulta(`SELECT se.id_sector, se.sec_nombre || ', ' || ci.ciu_nombre AS nombre FROM ${ESQUEMA}.sector se
                           JOIN ${ESQUEMA}.ciudad ci ON ci.id_ciudad = se.id_ciudad
                           WHERE se.id_sector IN (${idsSector.map((_, i) => `:s${i}`).join(",")})`,
            Object.fromEntries(idsSector.map((s, i) => [`s${i}`, s])), transaction)).map((f) => [f.id_sector, f.nombre])
        : []);
    return {
        idCliente: c.idCliente,
        nombre: [c.nombres, c.apellidos].filter(Boolean).join(" "),
        correo: c.correo,
        limiteCredito: c.limiteCredito,
        telefonos: telefonos.map((t) => t.numero),
        facturacion: facturacion.map((d) => ({
            id: d.idDatosFacturacion,
            idTipoIdentificacion: d.idTipoIdentificacion,
            identificacion: d.identificacion,
            razonSocial: d.razonSocial,
            correo: d.correo,
            idDireccion: d.idDireccion,
            sector: sectores.get(d.idSector) ?? null,
            etiqueta: d.idTipoIdentificacion === "07" ? "Consumidor final" : `${d.razonSocial} (${d.identificacion})${sectores.get(d.idSector) ? ` · ${sectores.get(d.idSector)}` : ""}`,
        })),
        direcciones: direcciones.map((d) => ({
            id: d.id_direccion,
            idSector: d.id_sector,
            etiqueta: [[d.dir_calle_principal, d.dir_numero].filter(Boolean).join(" "), d.dir_calle_secundaria ? `y ${d.dir_calle_secundaria}` : null, d.sector, d.ciudad]
                .filter(Boolean).join(", ") + (d.dir_referencia ? ` (${d.dir_referencia})` : ""),
        })),
    };
}

/** Busca por nombre/apellido, identificacion (cedula, RUC) o telefono. Hasta 15 resultados. */
export async function buscar(q) {
    const texto = String(q ?? "").trim().toLowerCase();
    if (texto.length < 2) return [];
    // cedula, RUC o telefono COMPLETO: busqueda exacta, que usa los indices
    // (ix_datos_fact_identificacion, ix_telefono_numero) en vez de recorrer tablas
    if (/^\d{7,13}$/.test(texto)) {
        const exactos = await consulta(
            `SELECT id_cliente FROM ${ESQUEMA}.datos_facturacion WHERE dfa_identificacion = :q AND dfa_activo = 1
             UNION SELECT id_cliente FROM ${ESQUEMA}.telefono WHERE tel_numero = :q`,
            { q: texto }
        );
        if (exactos.length) return Promise.all(exactos.slice(0, 15).map((f) => ficha(f.id_cliente)));
    }
    const filas = await consulta(
        `SELECT DISTINCT c.id_cliente, c.cli_nombres
         FROM ${ESQUEMA}.cliente c
         WHERE INSTR(LOWER(c.cli_nombres || ' ' || c.cli_apellidos), :q) > 0
            OR EXISTS (SELECT 1 FROM ${ESQUEMA}.datos_facturacion d
                       WHERE d.id_cliente = c.id_cliente AND d.dfa_activo = 1
                         AND (INSTR(d.dfa_identificacion, :q) > 0 OR INSTR(LOWER(d.dfa_razon_social), :q) > 0))
            OR EXISTS (SELECT 1 FROM ${ESQUEMA}.telefono t WHERE t.id_cliente = c.id_cliente AND INSTR(t.tel_numero, :q) > 0)
         ORDER BY c.cli_nombres
         FETCH FIRST 15 ROWS ONLY`,
        { q: texto }
    );
    return Promise.all(filas.map((f) => ficha(f.id_cliente)));
}

async function crearFacturacion(t, idCliente, d) {
    const datos = d.consumidorFinal ? CONSUMIDOR_FINAL : d;
    // la misma identificacion del mismo cliente no se repite: se reutiliza
    const existente = await m.DatosFacturacion.findOne({
        where: { idCliente, identificacion: datos.identificacion, activo: 1 },
        transaction: t,
    });
    // sector obligatorio (la direccion no): el indicado o el de la direccion elegida
    let idSector = d.consumidorFinal ? null : await resolverSector(t, d);
    if (!idSector && d.idDireccion && !d.consumidorFinal) idSector = (await m.Direccion.findByPk(d.idDireccion, { transaction: t }))?.idSector ?? null;
    if (!idSector && !d.consumidorFinal) {
        throw new AppError("Indica el sector de los datos de facturación", 422, [{ campo: "sector", mensaje: "Sector es obligatorio" }]);
    }
    if (existente) {
        if (!existente.idSector && idSector) await existente.update({ idSector }, { transaction: t });
        return existente.idDatosFacturacion;
    }
    const fila = await m.DatosFacturacion.create(
        {
            idCliente,
            idTipoIdentificacion: datos.idTipoIdentificacion,
            identificacion: datos.identificacion,
            razonSocial: datos.razonSocial,
            correo: datos.correo ?? null,
            idDireccion: d.idDireccion ?? null,
            idSector,
        },
        { transaction: t }
    );
    return fila.idDatosFacturacion;
}

/**
 * Sector de una direccion o de unos datos de facturacion: el id, o ciudad +
 * nombre (fn_sector lo busca sin distinguir mayusculas/tildes y lo crea si no
 * existe). null si no se indico.
 */
async function resolverSector(t, { idSector, idCiudad, sector }) {
    if (idSector) return Number(idSector);
    if (!idCiudad || !String(sector ?? "").trim()) return null;
    return llamar(t, "fn_sector", { p_ciudad: Number(idCiudad), p_nombre: String(sector).trim() });
}

async function crearDireccion(t, idCliente, d) {
    const idSector = await resolverSector(t, d);
    if (!idSector) throw new AppError("La dirección necesita su sector", 422, [{ campo: "sector", mensaje: "Sector es obligatorio" }]);
    const fila = await m.Direccion.create(
        {
            idCliente,
            idSector,
            idCiudad: d.idCiudad,
            callePrincipal: d.callePrincipal,
            numero: d.numero ?? null,
            calleSecundaria: d.calleSecundaria ?? null,
            referencia: d.referencia ?? null,
        },
        { transaction: t }
    );
    return fila.idDireccion;
}

/**
 * Alta completa desde la venta: { nombres, apellidos?, correo?, telefono?,
 * direccion?: {...}, facturacion?: {...} | { consumidorFinal: true } }.
 * La direccion es opcional (venta en el local); si viene, los datos de
 * facturacion la usan.
 */
export function crear(d, idUsuario) {
    return conUsuario(idUsuario, async (t) => {
        const c = await m.Cliente.create({ nombres: d.nombres, apellidos: d.apellidos ?? null, correo: d.correo ?? null }, { transaction: t });
        if (d.telefono) await m.Telefono.create({ idCliente: c.idCliente, numero: d.telefono, tipo: d.telefono.startsWith("09") ? "MOVIL" : "FIJO" }, { transaction: t });
        const idDireccion = conDireccion(d.direccion) ? await crearDireccion(t, c.idCliente, d.direccion) : null;
        if (d.facturacion && (d.facturacion.consumidorFinal || d.facturacion.identificacion)) await crearFacturacion(t, c.idCliente, { ...d.facturacion, idDireccion: d.facturacion.consumidorFinal ? null : idDireccion });
        return ficha(c.idCliente, t);
    });
}

/** Datos de facturacion nuevos (la primera vez que el cliente pide factura). Devuelve la ficha y el id creado. */
export function agregarFacturacion(idCliente, d, idUsuario) {
    return conUsuario(idUsuario, async (t) => {
        if (!(await m.Cliente.findByPk(idCliente, { transaction: t }))) return null;
        const idDireccion = conDireccion(d.direccion) ? await crearDireccion(t, idCliente, d.direccion) : d.idDireccion ?? null;
        const id = await crearFacturacion(t, idCliente, { ...d, idDireccion });
        return { idDatosFacturacion: id, cliente: await ficha(idCliente, t) };
    });
}

export function agregarDireccion(idCliente, d, idUsuario) {
    return conUsuario(idUsuario, async (t) => {
        if (!(await m.Cliente.findByPk(idCliente, { transaction: t }))) return null;
        const id = await crearDireccion(t, idCliente, d);
        return { idDireccion: id, cliente: await ficha(idCliente, t) };
    });
}

/** Una direccion debe ser del cliente (envio del pedido). */
export async function direccionDelCliente(t, idCliente, idDireccion) {
    const d = await m.Direccion.findByPk(idDireccion, { transaction: t });
    if (!d || d.idCliente !== idCliente) throw new AppError("La dirección de entrega no es de este cliente", 422, [{ campo: "idDireccion", mensaje: "Elige una dirección del cliente" }]);
    return d;
}

/**
 * Deudas del cliente para mostrarlas al cobrar: el resumen (v_deuda_cliente),
 * cada cuenta por cobrar con saldo (credito o avance) y sus ultimos movimientos.
 */
export async function deudas(idCliente) {
    const [resumen] = await consulta(
        `SELECT deuda_total, deuda_vencida, saldo_credito, saldo_avances, limite_credito, credito_disponible, cuentas_pendientes, ultimo_abono
         FROM ${ESQUEMA}.v_deuda_cliente WHERE id_cliente = :c`,
        { c: idCliente }
    );
    const cuentas = await consulta(
        `SELECT id_cuenta_por_cobrar, id_pedido, tipo, motivo, concepto, fecha, vencimiento, monto, abonado, saldo, estado, dias_vencida
         FROM ${ESQUEMA}.v_cuentas_por_cobrar WHERE id_cliente = :c AND saldo > 0 ORDER BY fecha`,
        { c: idCliente }
    );
    const movimientos = await consulta(
        `SELECT fecha, detalle, cargo, abono, saldo FROM ${ESQUEMA}.v_estado_cuenta_movimientos
         WHERE id_cliente = :c ORDER BY fecha DESC FETCH FIRST 20 ROWS ONLY`,
        { c: idCliente }
    );
    return { resumen: resumen ?? { deuda_total: 0, cuentas_pendientes: 0 }, cuentas, movimientos };
}

/** Sectores activos de una ciudad, por nombre. */
export function sectores(idCiudad) {
    return consulta(
        `SELECT id_sector AS id, sec_nombre AS nombre FROM ${ESQUEMA}.sector WHERE id_ciudad = :c AND sec_activo = 1 ORDER BY sec_nombre`,
        { c: idCiudad }
    );
}
