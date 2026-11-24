// src/models/carrito.model.js
// Repository de carritos: el unico recurso que el e-commerce ESCRIBE, en sus
// propias tablas (ecommerce.carrito / ecommerce.item_carrito).
// La base no guarda precios en el carrito (los precios cambian): el precio de
// cada linea se lee al momento desde v_catalogo_web.
// Reglas que hace cumplir la propia base (disparadores), no este archivo:
//   - un carrito ya convertido en pedido no se modifica (ORA-20001)
//   - car_actualizado se mueve solo con cada cambio de lineas
import oracledb from "oracledb";
import { db } from "../config/db.js";
import { colorDe, tallaDe } from "../utils/caracteristicas.js";
import { descuentosVolumen } from "./producto.model.js";

const redondear = (n) => Math.round(n * 100) / 100;

async function idCarrito(conexion, token) {
    const { rows } = await conexion.execute(`SELECT id_carrito FROM carrito WHERE car_token = :token`, { token });
    return rows[0]?.ID_CARRITO ?? null;
}

/**
 * Estado de venta de cada presentacion pedida, segun v_catalogo_web:
 * Map id -> { disponible, cantidadMinima, incremento, etiqueta }. Las que no estan
 * publicadas no aparecen en el Map.
 * "disponible" ya descuenta lo reservado por pedidos pendientes (lo calcula la base).
 */
export async function estadoPresentaciones(ids) {
    if (ids.length === 0) return new Map();
    // Un bind por id (:p0, :p1, ...): nunca se concatena el valor en el SQL
    const binds = Object.fromEntries(ids.map((id, i) => [`p${i}`, id]));
    const { rows } = await db.ejecutar(
        `SELECT id_presentacion, disponible, cantidad_minima, incremento, prd_nombre, caracteristicas, presentacion
         FROM v_catalogo_web
         WHERE id_presentacion IN (${ids.map((_, i) => `:p${i}`).join(", ")})`,
        binds
    );
    return new Map(
        rows.map((f) => {
            const color = colorDe(f.CARACTERISTICAS);
            const talla = tallaDe(f.CARACTERISTICAS);
            const detalle = [color, talla ? `talla ${talla}` : null].filter(Boolean).join(", ");
            return [
                f.ID_PRESENTACION,
                {
                    disponible: f.DISPONIBLE,
                    cantidadMinima: f.CANTIDAD_MINIMA,
                    incremento: f.INCREMENTO,
                    etiqueta: `${f.PRD_NOMBRE}${detalle ? ` (${detalle})` : ""} - ${f.PRESENTACION}`,
                },
            ];
        })
    );
}

export async function buscarCarrito(token) {
    const { rows: cabecera } = await db.ejecutar(
        `SELECT id_carrito, car_token, car_creado, car_actualizado, id_pedido, id_cliente
         FROM carrito WHERE car_token = :token`,
        { token }
    );
    if (cabecera.length === 0) return null;
    const carrito = cabecera[0];

    // LEFT JOIN: si una presentacion se despublica, la linea sigue en el carrito
    // pero sin precio y marcada como no disponible (no se pierde en silencio).
    const { rows: lineas } = await db.ejecutar(
        `SELECT i.id_presentacion, i.ica_cantidad, i.ica_pieza, pz.codigo AS pieza_codigo,
                c.prd_codigo, c.prd_nombre, c.caracteristicas, c.presentacion,
                c.precio_final_con_iva, c.imagen_url, c.disponible, c.factor
         FROM item_carrito i
         LEFT JOIN v_catalogo_web c ON c.id_presentacion = i.id_presentacion
         LEFT JOIN (SELECT id_lote, MAX(codigo) AS codigo FROM v_pieza_web GROUP BY id_lote) pz
                ON pz.id_lote = i.ica_pieza
         WHERE i.id_carrito = :id
         ORDER BY c.prd_codigo, i.id_presentacion, i.ica_pieza`,
        { id: carrito.ID_CARRITO }
    );

    // Descuento por volumen, con la regla de la base (fn_crear_pedido): se mide
    // lo que lleva el carrito de cada PRODUCTO en unidad base (todas sus tallas
    // y colores) y se aplica el escalon mas alto alcanzado. Es una estimacion:
    // la base lo calcula sobre el precio sin IVA al crear el pedido, asi que
    // puede diferir en un centavo por redondeo.
    const codigos = [...new Set(lineas.filter((f) => f.PRD_CODIGO).map((f) => f.PRD_CODIGO))];
    const reglas = await descuentosVolumen(codigos);
    const basePorProducto = new Map();
    for (const f of lineas) {
        if (!f.PRD_CODIGO) continue;
        basePorProducto.set(f.PRD_CODIGO, (basePorProducto.get(f.PRD_CODIGO) ?? 0) + f.ICA_CANTIDAD * f.FACTOR);
    }
    const reglaDe = (codigo) =>
        (reglas.get(codigo) ?? []).filter((r) => basePorProducto.get(codigo) >= r.desde).at(-1) ?? null;

    const items = lineas.map((f) => {
        const publicada = f.PRD_CODIGO != null;
        const lista = publicada ? redondear(f.ICA_CANTIDAD * f.PRECIO_FINAL_CON_IVA) : null;
        const regla = publicada ? reglaDe(f.PRD_CODIGO) : null;
        const descuento = regla ? redondear((lista * regla.porcentaje) / 100) : 0;
        return {
            idPresentacion: f.ID_PRESENTACION,
            // banda elegida (productos por pieza); null = la asigna la base al pedir
            pieza: f.ICA_PIEZA > 0 ? f.ICA_PIEZA : null,
            piezaCodigo: f.PIEZA_CODIGO ?? null,
            codigo: f.PRD_CODIGO,
            nombre: f.PRD_NOMBRE,
            color: colorDe(f.CARACTERISTICAS),
            talla: tallaDe(f.CARACTERISTICAS),
            presentacion: f.PRESENTACION,
            imagenUrl: f.IMAGEN_URL,
            cantidad: f.ICA_CANTIDAD,
            precioUnitario: f.PRECIO_FINAL_CON_IVA,
            subtotalLista: lista,
            // { porcentaje, desde, unidad } si la linea alcanza un descuento por volumen
            descuentoVolumen: regla ? { porcentaje: regla.porcentaje, desde: regla.desde, unidad: regla.unidad } : null,
            descuento,
            subtotal: publicada ? redondear(lista - descuento) : null,
            publicada,
            stock: f.DISPONIBLE,
        };
    });

    return {
        token: carrito.CAR_TOKEN,
        creado: carrito.CAR_CREADO,
        actualizado: carrito.CAR_ACTUALIZADO,
        idPedido: carrito.ID_PEDIDO,
        // Solo el hecho, nunca el id: el id_cliente es interno de la base
        clienteIdentificado: carrito.ID_CLIENTE != null,
        items,
        totalUnidades: items.reduce((s, i) => s + i.cantidad, 0),
        ahorro: redondear(items.reduce((s, i) => s + i.descuento, 0)),
        total: redondear(items.reduce((s, i) => s + (i.subtotal ?? 0), 0)),
    };
}

export async function crearCarrito() {
    // El token (UUID) lo genera la base por DEFAULT; se recupera con RETURNING
    const { outBinds } = await db.transaccion((conexion) =>
        conexion.execute(`INSERT INTO carrito (id_cliente) VALUES (NULL) RETURNING car_token INTO :token`, {
            token: { dir: oracledb.BIND_OUT, type: oracledb.STRING, maxSize: 36 },
        })
    );
    return buscarCarrito(outBinds.token[0]);
}

/** Agrega una linea o suma a la existente. null si el carrito no existe. */
export async function agregarItem(token, idPresentacion, cantidad, pieza = 0) {
    const existe = await db.transaccion(async (conexion) => {
        const id = await idCarrito(conexion, token);
        if (id === null) return false;
        await conexion.execute(
            `MERGE INTO item_carrito i
             USING (SELECT :id AS id_carrito, :pres AS id_presentacion, :pieza AS ica_pieza FROM dual) n
             ON (i.id_carrito = n.id_carrito AND i.id_presentacion = n.id_presentacion AND i.ica_pieza = n.ica_pieza)
             WHEN MATCHED THEN UPDATE SET i.ica_cantidad = i.ica_cantidad + :cantidad
             WHEN NOT MATCHED THEN INSERT (id_carrito, id_presentacion, ica_pieza, ica_cantidad)
                                   VALUES (n.id_carrito, n.id_presentacion, n.ica_pieza, :cantidad)`,
            { id, pres: idPresentacion, pieza: pieza ?? 0, cantidad }
        );
        return true;
    });
    return existe ? buscarCarrito(token) : null;
}

/**
 * Suma varias lineas en una sola transaccion (un combo entra completo o no
 * entra). lineas: [{ idPresentacion, cantidad }]. null si el carrito no existe.
 */
export async function agregarItems(token, lineas) {
    const existe = await db.transaccion(async (conexion) => {
        const id = await idCarrito(conexion, token);
        if (id === null) return false;
        for (const { idPresentacion, cantidad } of lineas) {
            await conexion.execute(
                `MERGE INTO item_carrito i
                 USING (SELECT :id AS id_carrito, :pres AS id_presentacion FROM dual) n
                 ON (i.id_carrito = n.id_carrito AND i.id_presentacion = n.id_presentacion AND i.ica_pieza = 0)
                 WHEN MATCHED THEN UPDATE SET i.ica_cantidad = i.ica_cantidad + :cantidad
                 WHEN NOT MATCHED THEN INSERT (id_carrito, id_presentacion, ica_pieza, ica_cantidad)
                                       VALUES (n.id_carrito, n.id_presentacion, 0, :cantidad)`,
                { id, pres: idPresentacion, cantidad }
            );
        }
        return true;
    });
    return existe ? buscarCarrito(token) : null;
}

/**
 * Cambia la cantidad de una linea existente.
 * Devuelve { carrito } | { carrito: null, motivo: "CARRITO" | "ITEM" }.
 */
export async function actualizarCantidad(token, idPresentacion, cantidad, pieza = 0) {
    const motivo = await db.transaccion(async (conexion) => {
        const id = await idCarrito(conexion, token);
        if (id === null) return "CARRITO";
        const { rowsAffected } = await conexion.execute(
            `UPDATE item_carrito SET ica_cantidad = :cantidad
             WHERE id_carrito = :id AND id_presentacion = :pres AND ica_pieza = :pieza`,
            { cantidad, id, pres: idPresentacion, pieza: pieza ?? 0 }
        );
        return rowsAffected === 0 ? "ITEM" : null;
    });
    return motivo ? { carrito: null, motivo } : { carrito: await buscarCarrito(token) };
}

/** Reemplaza todas las lineas (atomico). null si el carrito no existe. */
export async function reemplazarItems(token, items) {
    const existe = await db.transaccion(async (conexion) => {
        const id = await idCarrito(conexion, token);
        if (id === null) return false;
        await conexion.execute(`DELETE FROM item_carrito WHERE id_carrito = :id`, { id });
        if (items.length > 0) {
            await conexion.executeMany(
                `INSERT INTO item_carrito (id_carrito, id_presentacion, ica_pieza, ica_cantidad)
                 VALUES (:id, :pres, :pieza, :cantidad)`,
                items.map((i) => ({ id, pres: i.idPresentacion, pieza: i.pieza ?? 0, cantidad: i.cantidad }))
            );
        }
        return true;
    });
    return existe ? buscarCarrito(token) : null;
}

/** Quita una linea. Devuelve "ELIMINADO" | "CARRITO" | "ITEM". */
export async function eliminarItem(token, idPresentacion, pieza = 0) {
    return db.transaccion(async (conexion) => {
        const id = await idCarrito(conexion, token);
        if (id === null) return "CARRITO";
        const { rowsAffected } = await conexion.execute(
            `DELETE FROM item_carrito WHERE id_carrito = :id AND id_presentacion = :pres AND ica_pieza = :pieza`,
            { id, pres: idPresentacion, pieza: pieza ?? 0 }
        );
        return rowsAffected === 0 ? "ITEM" : "ELIMINADO";
    });
}

/** Elimina el carrito y sus lineas. Devuelve "ELIMINADO" | "NO_EXISTE" | "CONVERTIDO". */
export async function eliminarCarrito(token) {
    return db.transaccion(async (conexion) => {
        const { rows } = await conexion.execute(
            `SELECT id_carrito, id_pedido FROM carrito WHERE car_token = :token FOR UPDATE`,
            { token }
        );
        if (rows.length === 0) return "NO_EXISTE";
        // Un carrito convertido es la traza del pedido web: no se borra
        if (rows[0].ID_PEDIDO != null) return "CONVERTIDO";
        const id = rows[0].ID_CARRITO;
        await conexion.execute(`DELETE FROM item_carrito WHERE id_carrito = :id`, { id });
        await conexion.execute(`DELETE FROM carrito WHERE id_carrito = :id`, { id });
        return "ELIMINADO";
    });
}

/**
 * Piezas libres (v_pieza_web) con la variante de cada presentacion pedida:
 * Map id_lote -> { libre, idVariante, codigo } y Map id_presentacion -> { idVariante, factor }.
 * Sirve para validar que la banda elegida es de esa presentacion y alcanza.
 */
export async function estadoPiezas(idsLote, idsPresentacion) {
    const piezas = new Map();
    const presentaciones = new Map();
    if (idsLote.length > 0) {
        const binds = Object.fromEntries(idsLote.map((x, i) => [`l${i}`, x]));
        const { rows } = await db.ejecutar(
            `SELECT id_lote, id_variante, codigo, saldo FROM v_pieza_web
             WHERE id_lote IN (${idsLote.map((_, i) => `:l${i}`).join(", ")})`,
            binds
        );
        rows.forEach((f) => piezas.set(f.ID_LOTE, { libre: f.SALDO, idVariante: f.ID_VARIANTE, codigo: f.CODIGO }));
    }
    if (idsPresentacion.length > 0) {
        const binds = Object.fromEntries(idsPresentacion.map((x, i) => [`p${i}`, x]));
        const { rows } = await db.ejecutar(
            `SELECT id_presentacion, id_variante, factor FROM v_catalogo_web
             WHERE id_presentacion IN (${idsPresentacion.map((_, i) => `:p${i}`).join(", ")})`,
            binds
        );
        rows.forEach((f) => presentaciones.set(f.ID_PRESENTACION, { idVariante: f.ID_VARIANTE, factor: f.FACTOR }));
    }
    return { piezas, presentaciones };
}
