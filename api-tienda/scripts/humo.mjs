// scripts/humo.mjs
// Prueba de humo de la API completa contra la base real (npm run humo, con la
// API ya corriendo). Recorre el contrato entero: catalogo, CRUD del carrito,
// checkout de invitado (carrito -> pedido WEB) y cuentas. Termina con codigo
// distinto de 0 si algo no responde como el contrato promete.
const BASE = process.env.API_URL ?? "http://localhost:5050/api/v1";

let pruebas = 0;
let fallos = 0;

function ok(condicion, nombre, extra = "") {
    pruebas += 1;
    if (condicion) {
        console.log(`  ✔ ${nombre}`);
    } else {
        fallos += 1;
        console.error(`  ✖ ${nombre}${extra ? ` — ${extra}` : ""}`);
    }
}

async function pedir(ruta, { metodo = "GET", cuerpo } = {}) {
    const respuesta = await fetch(`${BASE}${ruta}`, {
        method: metodo,
        headers: cuerpo ? { "Content-Type": "application/json" } : {},
        body: cuerpo ? JSON.stringify(cuerpo) : undefined,
    });
    const json = respuesta.status === 204 ? null : await respuesta.json().catch(() => null);
    return { status: respuesta.status, json };
}

const unico = Date.now(); // correo distinto en cada corrida

// El catalogo se lee de la cache (Redis), que se sincroniza con Oracle en ~200 ms:
// despues de escribir, esperar a que el valor cambie (maximo 3 s).
async function esperarCambio(leer, antes, maximoMs = 3000) {
    const inicio = Date.now();
    let valor = await leer();
    while (valor === antes && Date.now() - inicio < maximoMs) {
        await new Promise((listo) => setTimeout(listo, 50));
        valor = await leer();
    }
    return { valor, ms: Date.now() - inicio };
}

console.log(`Prueba de humo contra ${BASE}`);

// ---- Salud y catalogo (solo lectura) ----
let r = await pedir("/salud");
ok(r.status === 200 && r.json.data.baseDeDatos === "ok", "GET /salud responde y ve la base");

r = await pedir("/categorias");
ok(r.status === 200 && Array.isArray(r.json.data) && r.json.data.length > 0, "GET /categorias trae lineas");

r = await pedir("/productos?limit=5");
ok(r.status === 200 && r.json.data.length > 0 && r.json.meta.totalItems > 0, "GET /productos pagina y trae meta");
const productos = r.json.data;

// preferir un producto comun (no por pieza ni de cortes): su disponible baja
// exactamente con cada reserva, lo que permite probar la sincronia de la cache
const candidatos = (await pedir("/productos?limit=50")).json.data;
const conStock = [...candidatos.filter((p) => !p.porPieza && !p.cortesEstandar), ...candidatos]
    .flatMap((p) => p.presentaciones.map((x) => ({ ...x, codigo: p.codigo })))
    .find((x) => x.disponible >= Math.max(1, x.cantidadMinima));
productos.push(...candidatos.filter((p) => !productos.some((q) => q.codigo === p.codigo)));
ok(Boolean(conStock), "hay una presentacion con stock para probar el carrito");

r = await pedir(`/productos/${productos[0].codigo}`);
ok(r.status === 200 && r.json.data.codigo === productos[0].codigo, "GET /productos/:codigo devuelve el detalle");

r = await pedir("/productos/NO-EXISTE");
ok(r.status === 404, "GET /productos/NO-EXISTE -> 404");

r = await pedir("/productos?limit=0");
ok(r.status === 422, "GET /productos?limit=0 -> 422");

// ---- Carrito: CRUD completo ----
r = await pedir("/carritos", { metodo: "POST" });
ok(r.status === 201 && r.json.data.token, "POST /carritos crea un carrito con token");
const token = r.json.data.token;
const cantidad = Math.max(1, conStock.cantidadMinima);

r = await pedir(`/carritos/${token}/items`, {
    metodo: "POST",
    cuerpo: { idPresentacion: conStock.idPresentacion, cantidad },
});
ok(r.status === 201 && r.json.data.items.length === 1, "POST items agrega una linea", JSON.stringify(r.json));

r = await pedir(`/carritos/${token}/items`, {
    metodo: "POST",
    cuerpo: { idPresentacion: 999999, cantidad: 1 },
});
ok(r.status === 422, "POST items con presentacion inexistente -> 422");

r = await pedir(`/carritos/${token}`);
ok(r.status === 200 && r.json.data.total > 0, "GET /carritos/:token resuelve precios y total");

// ---- Checkout de invitado: carrito -> pedido WEB en la base ----
r = await pedir(`/carritos/${token}/pedido`, { metodo: "POST", cuerpo: {} });
ok(r.status === 409, "confirmar sin identificar al cliente -> 409 (regla de la base)");

r = await pedir(`/carritos/${token}/cliente`, {
    metodo: "POST",
    cuerpo: { nombres: "Prueba Humo", correo: `humo.${unico}@example.com`, telefono: "0999999999" },
});
ok(r.status === 200 && r.json.data.clienteIdentificado === true, "POST cliente identifica al invitado");

// disponible ANTES del pedido (lo que muestra la cache). Por pieza (cuero) el
// disponible es la pieza libre mas grande: reservar otra pieza no lo cambia.
const productoDe = productos.find((p) => p.codigo === conStock.codigo);
const disponibleDe = async () =>
    (await pedir(`/productos/${conStock.codigo}`)).json.data.presentaciones.find((x) => x.idPresentacion === conStock.idPresentacion).disponible;
const disponibleAntes = await disponibleDe();

r = await pedir(`/carritos/${token}/pedido`, { metodo: "POST", cuerpo: { observacion: "Prueba de humo" } });
// La tienda envia una COTIZACION (venta por confirmar): no crea pedido ni
// reserva stock; el personal la confirma en la administracion o vence en 14 dias.
const diasHasta = (fecha) => (new Date(fecha) - Date.now()) / 86400000;
ok(r.status === 201 && r.json.data.idCotizacion > 0 && /^COT-\d{6}$/.test(r.json.data.numeroCotizacion) && r.json.data.estado === "COT"
    && r.json.data.idPedido === null && Math.round(diasHasta(r.json.data.vence)) === 14,
    "POST pedido envía una cotización por confirmar (COT-…, vence en 14 días, sin pedido)", JSON.stringify(r.json));
const idCotizacion = r.json?.data?.idCotizacion;

// ---- La cotizacion NO reserva stock: el disponible sigue igual ----
await new Promise((listo) => setTimeout(listo, 600));
ok((await disponibleDe()) === disponibleAntes, `la cotización no reserva stock (disponible ${disponibleAntes} sin cambios)`);

r = await pedir(`/carritos/${token}/pedido`);
ok(r.status === 200 && r.json.data.idCotizacion === idCotizacion && r.json.data.estadoNombre === "Cotización por confirmar", "GET pedido devuelve la cotización y su estado");

r = await pedir(`/carritos/${token}/items`, {
    metodo: "POST",
    cuerpo: { idPresentacion: conStock.idPresentacion, cantidad: 1 },
});
ok(r.status === 409, "el carrito convertido no se modifica -> 409 (disparador de la base)");

r = await pedir(`/carritos/${token}`, { metodo: "DELETE" });
ok(r.status === 409, "el carrito convertido no se elimina -> 409");

// ---- Combos: uno solo, el color se elige al agregarlo ----
r = await pedir("/combos");
const combo = r.json?.data?.find((c) => c.colores.some((x) => x.disponible >= 2));
ok(r.status === 200 && Boolean(combo), "GET /combos trae combos con colores armables, precio y componentes");
if (combo) {
    const opcion = combo.colores.find((x) => x.disponible >= 2);
    const carritoCombo = (await pedir("/carritos", { metodo: "POST" })).json.data.token;
    r = await pedir(`/carritos/${carritoCombo}/combos`, {
        metodo: "POST",
        cuerpo: { codigo: combo.codigo, color: opcion.color, cantidad: 2 },
    });
    const lineasOk =
        r.status === 201 &&
        opcion.lineas.every(
            (l) => r.json.data.items.find((i) => i.idPresentacion === l.idPresentacion)?.cantidad === l.cantidad * 2
        );
    ok(lineasOk, "POST combos agrega cada componente del color elegido x cantidad", JSON.stringify(r.json));
    r = await pedir(`/carritos/${carritoCombo}/combos`, {
        metodo: "POST",
        cuerpo: { codigo: combo.codigo, color: opcion.color, cantidad: 1000 },
    });
    const sinCambios = (await pedir(`/carritos/${carritoCombo}`)).json.data.items.every(
        (i) => i.cantidad === opcion.lineas.find((l) => l.idPresentacion === i.idPresentacion).cantidad * 2
    );
    ok(r.status === 409 && sinCambios, "combo sin stock -> 409 y el carrito queda igual (todo o nada)");
    if (combo.colores.length > 1) {
        r = await pedir(`/carritos/${carritoCombo}/combos`, { metodo: "POST", cuerpo: { codigo: combo.codigo, color: "Fucsia" } });
        ok(r.status === 422, "combo con un color que no tiene -> 422");
    }
    r = await pedir(`/carritos/${carritoCombo}/combos`, { metodo: "POST", cuerpo: { codigo: "CMB-NO-EXISTE" } });
    ok(r.status === 404, "combo inexistente -> 404");
    await pedir(`/carritos/${carritoCombo}`, { metodo: "DELETE" });
}

// ---- Marca, incremento de venta y descuento por volumen ----
r = await pedir("/productos?limit=100");
const conMarca = r.json.data.find((p) => p.marca);
if (conMarca) {
    r = await pedir(`/productos?marca=${encodeURIComponent(conMarca.marca)}&limit=100`);
    ok(r.status === 200 && r.json.data.length > 0 && r.json.data.every((p) => p.marca === conMarca.marca),
        "GET /productos?marca= filtra por marca");
}
const todos = (await pedir("/productos?limit=100")).json.data;
const conVolumen = todos.find((p) => p.descuentosVolumen?.length > 0);
if (conVolumen) {
    const regla = conVolumen.descuentosVolumen[0];
    // presentaciones de factor 1 con stock, sumando hasta el umbral (tallas distintas)
    const candidatas = conVolumen.presentaciones.filter((x) => x.factor === 1 && x.disponible > 0);
    const lineas = [];
    let faltan = regla.desde;
    for (const x of candidatas) {
        if (faltan <= 0) break;
        const n = Math.min(x.disponible, faltan);
        lineas.push({ idPresentacion: x.idPresentacion, cantidad: n });
        faltan -= n;
    }
    if (faltan <= 0) {
        const t2 = (await pedir("/carritos", { metodo: "POST" })).json.data.token;
        r = await pedir(`/carritos/${t2}/items`, { metodo: "PUT", cuerpo: { items: lineas } });
        ok(r.status === 200 && r.json.data.ahorro > 0 && r.json.data.items.every((i) => i.descuentoVolumen?.porcentaje === regla.porcentaje),
            `carrito con ${regla.desde} ${regla.unidad} de ${conVolumen.codigo} aplica ${regla.porcentaje} % por volumen`,
            JSON.stringify(r.json));
        await pedir(`/carritos/${t2}`, { metodo: "DELETE" });
    }
}
const enteros = todos.flatMap((p) => p.presentaciones).find((x) => x.incremento === 1 && x.disponible >= 2);
if (enteros) {
    const t3 = (await pedir("/carritos", { metodo: "POST" })).json.data.token;
    r = await pedir(`/carritos/${t3}/items`, { metodo: "POST", cuerpo: { idPresentacion: enteros.idPresentacion, cantidad: 1.5 } });
    ok(r.status === 422, "cantidad fuera del incremento de venta (1.5 de algo entero) -> 422");
    await pedir(`/carritos/${t3}`, { metodo: "DELETE" });
}

// ---- Bandas de cuero: cada banda es su propia linea y no se repite ----
{
    const conPiezas = (await pedir("/productos?limit=100")).json.data.find((p) => p.porPieza);
    if (conPiezas) {
        const detalle = (await pedir(`/productos/${conPiezas.codigo}`)).json.data;
        const [sku, piezas] = Object.entries(detalle.piezas ?? {}).find(([, lista]) => lista.length >= 2) ?? [];
        const presBanda = detalle.presentaciones.find((x) => x.sku === sku && x.factor === 1 && x.cantidadMinima <= 1)
            ?? detalle.presentaciones.find((x) => x.sku === sku);
        if (presBanda) {
            const [a1, a2] = piezas.slice(-2);
            const tk = (await pedir("/carritos", { metodo: "POST" })).json.data.token;
            await pedir(`/carritos/${tk}/items`, { metodo: "POST", cuerpo: { idPresentacion: presBanda.idPresentacion, cantidad: a1.saldo, pieza: a1.idLote } });
            r = await pedir(`/carritos/${tk}/items`, { metodo: "POST", cuerpo: { idPresentacion: presBanda.idPresentacion, cantidad: a2.saldo, pieza: a2.idLote } });
            ok(r.status === 201 && r.json.data.items.filter((i) => i.pieza).length === 2,
                "dos bandas del mismo color son dos lineas del carrito", JSON.stringify(r.json));
            r = await pedir(`/carritos/${tk}/items`, { metodo: "POST", cuerpo: { idPresentacion: presBanda.idPresentacion, cantidad: a1.saldo, pieza: a1.idLote } });
            ok(r.status === 409, "la misma banda no se agrega dos veces -> 409");
            r = await pedir(`/carritos/${tk}/items/${presBanda.idPresentacion}?pieza=${a2.idLote}`, { metodo: "DELETE" });
            const quedan = (await pedir(`/carritos/${tk}`)).json.data.items;
            ok(r.status === 204 && quedan.length === 1 && quedan[0].pieza === a1.idLote, "quitar una banda deja la otra");
            await pedir(`/carritos/${tk}`, { metodo: "DELETE" });
        }
    }
}

// ---- Fibra de caucho: cortes estandar cortados de la plancha al pedir ----
{
    const fibra = (await pedir("/productos?limit=100")).json.data.find((p) => p.cortesEstandar);
    if (fibra) {
        const detalle = (await pedir(`/productos/${fibra.codigo}`)).json.data;
        ok(detalle.piezas === undefined, "un producto de cortes estandar no expone bandas");
        const delSku = (sku) => detalle.presentaciones.filter((x) => x.sku === sku);
        const sku = detalle.presentaciones.find((x) => x.factor === 1 && x.disponible >= 5)?.sku;
        if (sku) {
            const corte = (f) => delSku(sku).find((x) => x.factor === f);
            const antes = corte(1).disponible; // pie2 libres en total
            const tk = (await pedir("/carritos", { metodo: "POST" })).json.data.token;
            await pedir(`/carritos/${tk}/items`, { metodo: "PUT", cuerpo: { items: [
                { idPresentacion: corte(2).idPresentacion, cantidad: 2 },
                { idPresentacion: corte(1).idPresentacion, cantidad: 1 },
            ] } });
            await pedir(`/carritos/${tk}/cliente`, {
                metodo: "POST",
                cuerpo: { nombres: "Prueba Fibra", correo: `fibra.${unico}@example.com`, telefono: "0999999999" },
            });
            r = await pedir(`/carritos/${tk}/pedido`, { metodo: "POST", cuerpo: { observacion: "Humo: cortes de fibra" } });
            ok(r.status === 201 && r.json.data.estado === "COT", "cotización de 2 x 2 pies + 1 pie de fibra enviada", JSON.stringify(r.json));
            // el corte de la plancha recien ocurre al confirmar (en la administracion)
            await new Promise((listo) => setTimeout(listo, 600));
            const despues = (await pedir(`/productos/${fibra.codigo}`)).json.data.presentaciones
                .find((x) => x.idPresentacion === corte(1).idPresentacion).disponible;
            ok(despues === antes, `la cotización no corta ni reserva la plancha (${antes} pie2 sin cambios)`);
        }
    }
}

// ---- Cuentas web ----
const correoCuenta = `cuenta.${unico}@example.com`;
r = await pedir("/cuentas", {
    metodo: "POST",
    cuerpo: { nombres: "Cuenta", apellidos: "De Humo", correo: correoCuenta, clave: "ClaveDeHumo123" },
});
ok(r.status === 201 && r.json.data.correo === correoCuenta, "POST /cuentas crea la cuenta", JSON.stringify(r.json));

r = await pedir("/cuentas", {
    metodo: "POST",
    cuerpo: { nombres: "Cuenta", correo: correoCuenta, clave: "ClaveDeHumo123" },
});
ok(r.status === 409, "correo repetido -> 409");

r = await pedir("/cuentas/sesion", { metodo: "POST", cuerpo: { correo: correoCuenta, clave: "ClaveDeHumo123" } });
ok(r.status === 200 && r.json.data.idCuenta > 0, "login correcto -> 200 con la cuenta");

r = await pedir("/cuentas/sesion", { metodo: "POST", cuerpo: { correo: correoCuenta, clave: "ClaveMala999" } });
ok(r.status === 401, "clave incorrecta -> 401");

r = await pedir("/cuentas/sesion", { metodo: "POST", cuerpo: { correo: "nadie@example.com", clave: "loquesea123" } });
ok(r.status === 401, "correo sin cuenta -> 401 con el mismo mensaje");

console.log(`\n${fallos === 0 ? "✔" : "✖"} ${pruebas - fallos} de ${pruebas} pruebas de humo en orden.`);
process.exit(fallos === 0 ? 0 : 1);
