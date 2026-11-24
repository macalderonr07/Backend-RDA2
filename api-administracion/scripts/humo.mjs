// scripts/humo.mjs — prueba de humo de la API de administracion contra la base
// real (npm run humo, con la API corriendo). Recorre los flujos de negocio de
// punta a punta: catalogo generico, alta de producto con variantes y formas de
// venta, precios y ofertas, compra (OC -> emision -> recepcion), inventario
// (ajuste, fraccionamiento, kardex), venta en tienda (pedido -> pago -> factura
// -> despacho -> entrega), seguridad (usuarios, permisos) y reportes.
// Usa codigos unicos por corrida: se puede repetir. Termina con codigo != 0 si
// algo no responde como el contrato promete.
import "../src/config/env.js"; // carga .env (ADMIN_CORREO / ADMIN_CLAVE)
import { cedulaValida } from "../src/utils/patrones.js";

const BASE = process.env.API_URL ?? `http://localhost:${process.env.PORT ?? 5070}/api/v1`;
let pruebas = 0;
let fallos = 0;
let token = null;

function ok(condicion, nombre, extra = "") {
    pruebas += 1;
    if (condicion) console.log(`  ✔ ${nombre}`);
    else {
        fallos += 1;
        console.error(`  ✖ ${nombre}${extra ? ` — ${typeof extra === "string" ? extra : JSON.stringify(extra).slice(0, 400)}` : ""}`);
    }
}

async function pedir(ruta, { metodo = "GET", cuerpo, conToken = token } = {}) {
    const respuesta = await fetch(`${BASE}${ruta}`, {
        method: metodo,
        headers: {
            ...(cuerpo ? { "Content-Type": "application/json" } : {}),
            ...(conToken ? { Authorization: `Bearer ${conToken}` } : {}),
        },
        body: cuerpo ? JSON.stringify(cuerpo) : undefined,
    });
    const json = respuesta.status === 204 ? null : await respuesta.json().catch(() => null);
    return { status: respuesta.status, json, data: json?.data };
}

const seccion = (t) => console.log(`\n▶ ${t}`);
const unico = Date.now().toString(36).toUpperCase().slice(-6);
const cedula = (base) => [...Array(10).keys()].map((d) => base + d).find(cedulaValida);

console.log(`Prueba de humo de administración contra ${BASE} (corrida ${unico})`);

// ------------------------------------------------------------ Autenticación
seccion("Autenticación");
let r = await pedir("/salud");
ok(r.status === 200, "GET /salud responde");
r = await pedir("/provincias");
ok(r.status === 401, "sin token -> 401");
r = await pedir("/auth/ingresar", { metodo: "POST", cuerpo: { correo: process.env.ADMIN_CORREO, clave: "ClaveIncorrecta123" } });
ok(r.status === 401 && r.json.message === "Correo o clave incorrectos", "clave incorrecta -> 401 con mensaje genérico");
r = await pedir("/auth/ingresar", { metodo: "POST", cuerpo: { correo: process.env.ADMIN_CORREO, clave: process.env.ADMIN_CLAVE } });
ok(r.status === 200 && r.data?.token && r.data.usuario.permisos.includes("CATALOGO_GESTIONAR"), "login de ADMIN -> token y permisos", r.json);
token = r.data?.token;
const yo = r.data?.usuario;
r = await pedir("/meta");
ok(r.status === 200 && r.data.recursos.length >= 15 && r.data.patrones.correo, "GET /meta publica recursos y patrones");

// ------------------------------------------------------------ CRUD genérico
seccion("CRUD genérico (provincias, proveedores)");
r = await pedir("/provincias", { metodo: "POST", cuerpo: { nombre: "<script>" } });
ok(r.status === 422 && r.json.detalles?.[0]?.campo === "nombre", "nombre con < > rechazado por la regex -> 422");
r = await pedir("/provincias", { metodo: "POST", cuerpo: { nombre: `Provincia Humo ${unico}` } });
ok(r.status === 201 && r.data.idProvincia, "POST /provincias -> 201", r.json);
const idProv = r.data?.idProvincia;
r = await pedir(`/provincias/${idProv}`, { metodo: "PATCH", cuerpo: { nombre: `Provincia Humo ${unico} B` } });
ok(r.status === 200 && r.data.nombre.endsWith(" B"), "PATCH /provincias/:id -> 200");
r = await pedir(`/provincias?q=humo ${unico.toLowerCase()}`);
ok(r.status === 200 && r.data.length === 1 && r.json.meta.totalItems === 1, "búsqueda sin distinguir mayúsculas");
r = await pedir(`/provincias/${idProv}`, { metodo: "DELETE" });
ok(r.status === 204, "DELETE /provincias/:id -> 204");
r = await pedir(`/provincias/${idProv}`);
ok(r.status === 404, "ya no existe -> 404");
r = await pedir("/provincias", { metodo: "POST", cuerpo: { nombre: "X", hashClave: "x" } });
ok(r.status === 422, "campo no permitido en el body -> 422");
r = await pedir("/proveedores", {
    metodo: "POST",
    cuerpo: { idTipoIdentificacion: "05", identificacion: "1234567890", razonSocial: "Proveedor Humo" },
});
ok(r.status === 422 && /cédula/i.test(JSON.stringify(r.json)), "cédula con dígito verificador inválido -> 422");
r = await pedir("/proveedores", {
    metodo: "POST",
    cuerpo: { idTipoIdentificacion: "04", identificacion: `17${String(Date.now()).slice(-8)}001`, razonSocial: `PROVEEDOR HUMO ${unico}`, correo: "humo@proveedor.ec", telefono: "022 500 300" },
});
ok(r.status === 201 && r.data.telefono === "022500300", "POST /proveedores -> 201 (teléfono normalizado)", r.json);
const idProveedor = r.data?.idProveedor;

// ------------------------------------------------------------ Productos
seccion("Productos: alta con variantes, formas de venta y precios");
const colores = (await pedir("/atributos?q=color")).data?.[0];
const valores = (await pedir(`/valores-atributo?idAtributo=${colores?.idAtributo}&limit=100`)).data ?? [];
const negro = valores.find((v) => v.valor === "Negro");
const cafe = valores.find((v) => v.valor === "Café");
const categoria = (await pedir("/categorias?q=herrajes")).data?.find((c) => c.idCategoriaPadre);
ok(Boolean(negro && cafe && categoria), "catálogos de apoyo (Color, categoría)");
r = await pedir(`/catalogo/categorias/${categoria?.idCategoria}/atributos`);
ok(r.status === 200 && r.data.propios.some((a) => a.nombre === "Color") && Array.isArray(r.data.otros),
    "atributos de la categoría: los propios (o de su línea) y los demás aparte", r.json);
r = await pedir("/catalogo/productos", {
    metodo: "POST",
    cuerpo: {
        codigo: "LO-QUE-SEA", // se ignora: el codigo lo genera el servidor
        nombre: `Remache de humo ${unico}`,
        idCategoria: categoria?.idCategoria,
        idUnidadMedida: "u",
        idTarifaIva: "4",
        uso: "Prueba de humo",
        variantes: [{ valores: [negro?.idValorAtributo], stockMinimo: 10 }, { valores: [cafe?.idValorAtributo] }],
        presentaciones: [
            // precios CON IVA (15 %): la base guarda 0.10 y 1.00
            { descripcion: "Unidad", factor: 1, precioConIva: 0.12 },
            { descripcion: "Docena", factor: 12, precioConIva: 1.15 },
        ],
    },
});
ok(r.status === 201 && r.data.variantes.length === 2 && r.data.variantes.every((v) => v.presentaciones.length === 2 && v.presentaciones.every((p) => p.precio > 0)),
    "POST /catalogo/productos -> 2 variantes × 2 formas de venta con precio", r.json);
const producto = r.data;
const codigo = producto?.codigo;
ok(/^CE-7\d{3}$/.test(codigo ?? ""), `código automático en el bloque de herrajes (7xxx): ${codigo}`);
const docena = producto?.variantes[0].presentaciones.find((p) => p.descripcion === "Docena");
ok(docena?.precioConIva === 1.15 && docena?.precio === 1, "precio escrito con IVA (1.15) -> base sin IVA 1.00", docena);
const [varNegro] = producto?.variantes ?? [];
r = await pedir("/catalogo/productos", { metodo: "POST", cuerpo: { nombre: "Repetidas", idCategoria: categoria?.idCategoria, idUnidadMedida: "u", idTarifaIva: "4", variantes: [{ valores: [negro?.idValorAtributo] }, { valores: [negro?.idValorAtributo] }], presentaciones: [{ descripcion: "Unidad", factor: 1, precioConIva: 1 }] } });
ok(r.status === 422, "variantes repetidas -> 422");
r = await pedir(`/catalogo/productos/${producto?.idProducto}/precios`, { metodo: "POST", cuerpo: { descripcion: "Docena", precioConIva: 1.09 } });
ok(r.status === 200 && r.json.meta.preciosRegistrados === 2, "precio nuevo de la Docena en las 2 variantes", r.json);
ok(r.data?.variantes.every((v) => v.presentaciones.find((p) => p.descripcion === "Docena")?.precioConIva === 1.09),
    "el precio con IVA queda en 1.09 (base 0.95)", r.json);
r = await pedir(`/catalogo/productos/${producto?.idProducto}/precios`);
ok(r.status === 200 && r.data.length >= 6, "historial de precios conserva los anteriores");
r = await pedir(`/catalogo/productos/${producto?.idProducto}`, { metodo: "PATCH", cuerpo: { publicado: true } });
ok(r.status === 200 && r.data.publicado === true, "publicar el producto");
r = await pedir("/catalogo/ofertas", { metodo: "POST", cuerpo: { idProducto: producto?.idProducto, porcentaje: 10, descripcion: "Oferta de humo" } });
ok(r.status === 201 && r.data.idOferta, "oferta registrada (fn_registrar_oferta)", r.json);
r = await pedir(`/catalogo/ofertas/${r.data?.idOferta}`, { metodo: "PATCH", cuerpo: { activa: false } });
ok(r.status === 204, "oferta pausada (fn_cambiar_estado_oferta)", r.json);
r = await pedir(`/catalogo/productos?q=${unico.toLowerCase()}&limit=5`);
ok(r.status === 200 && r.data.some((p) => p.codigo === codigo), "listado con búsqueda");

// ------------------------------------------------------------ Codigos automaticos
seccion("Códigos automáticos: categorías y combos");
r = await pedir("/categorias", { metodo: "POST", cuerpo: { codigo: "inventado", nombre: "Pega", activa: 0 } });
ok(r.status === 422, "el código no se escribe a mano -> 422 (campo no permitido)", r.json);
const padre = (await pedir("/categorias?q=herrajes")).data?.find((c) => !c.idCategoriaPadre);
r = await pedir("/categorias", { metodo: "POST", cuerpo: { nombre: `Remaches humo ${unico}`, idCategoriaPadre: padre?.idCategoria, activa: 0 } });
const hija = r.data;
ok(r.status === 201 && /^herrajes-\d+$/.test(hija?.codigo ?? ""), `subcategoría: código del padre + número (${hija?.codigo})`, r.json);
r = await pedir("/categorias", { metodo: "POST", cuerpo: { nombre: `Humo ${unico} línea`, activa: 0 } });
const raiz = r.data;
ok(r.status === 201 && /^humo(-|$)/.test(raiz?.codigo ?? ""), `línea: primera palabra del nombre (${raiz?.codigo})`, r.json);
r = await pedir(`/categorias/${hija?.idCategoria}`, { metodo: "PATCH", cuerpo: { codigo: "otro" } });
ok(r.status === 422, "el código no se edita -> 422", r.json);
await pedir(`/categorias/${hija?.idCategoria}`, { metodo: "DELETE" });
await pedir(`/categorias/${raiz?.idCategoria}`, { metodo: "DELETE" });
const llave = (await pedir("/catalogo/productos?q=llave&limit=5")).data?.find((x) => x.codigo === "CE-9002");
r = await pedir("/catalogo/combos", { metodo: "POST", cuerpo: { nombre: `Combo humo ${unico}`, publicado: false, componentes: [
    { idProducto: producto?.idProducto, presentacion: "Unidad", cantidad: 2 },
    { idProducto: llave?.idProducto, presentacion: "2 llaves", cantidad: 1 },
] } });
ok(r.status === 201 && /^CMB-\d{4}$/.test(r.data?.codigo ?? ""), `combo con código CMB-000N (${r.data?.codigo})`, r.json);
if (r.data?.idCombo) await pedir(`/catalogo/combos/${r.data.idCombo}`, { metodo: "DELETE" });

// ------------------------------------------------------------ Compras
seccion("Compras: orden -> emisión -> recepción");
r = await pedir("/compras/ordenes", {
    metodo: "POST",
    cuerpo: { idProveedor, observacion: "OC de humo", lineas: [{ idVariante: varNegro?.idVariante, cantidad: 120, costoUnitario: 0.04 }] },
});
ok(r.status === 201 && r.data.estado === "BORRADOR" && r.data.lineas.length === 1, "OC en borrador", r.json);
const oc = r.data;
r = await pedir(`/compras/ordenes/${oc?.idOrdenCompra}/estado`, { metodo: "POST", cuerpo: { estado: "EMITIDA" } });
ok(r.status === 200 && r.data.estado === "EMITIDA", "OC emitida (fn_cambiar_estado_oc)", r.json);
r = await pedir(`/compras/ordenes/${oc?.idOrdenCompra}/recepciones`, {
    metodo: "POST",
    cuerpo: { lineas: [{ idDetalleOrdenCompra: oc?.lineas[0].id_detalle_orden_compra, cantidad: 120, codigoLote: `LOTE-${unico}` }] },
});
ok(r.status === 201 && r.data.orden.lineas[0].cantidad_pendiente === 0, "recepción completa (fn_recepcionar_compra)", r.json);
r = await pedir(`/compras/ordenes/${oc?.idOrdenCompra}/recepciones`, {
    metodo: "POST",
    cuerpo: { lineas: [{ idDetalleOrdenCompra: oc?.lineas[0].id_detalle_orden_compra, cantidad: 1 }] },
});
ok(r.status === 409, "recibir más de lo pedido lo rechaza la base -> 409", r.json);
// Fibra en planchas: una linea por plancha -> cada plancha es su propio lote (pieza)
{
    const fibra = (await pedir("/catalogo/productos?q=fibra&limit=5")).data?.find((x) => x.codigo === "CE-9101");
    const varFibra = fibra ? (await pedir(`/catalogo/productos/${fibra.idProducto}`)).data?.variantes[0] : null;
    if (varFibra) {
        r = await pedir("/compras/ordenes", { metodo: "POST", cuerpo: { idProveedor, observacion: "Planchas de humo", lineas: [{ idVariante: varFibra.idVariante, cantidad: 48, costoUnitario: 1.1 }] } });
        const ocF = r.data;
        await pedir(`/compras/ordenes/${ocF?.idOrdenCompra}/estado`, { metodo: "POST", cuerpo: { estado: "EMITIDA" } });
        const det = ocF?.lineas[0].id_detalle_orden_compra;
        r = await pedir(`/compras/ordenes/${ocF?.idOrdenCompra}/recepciones`, { metodo: "POST", cuerpo: { lineas: [
            { idDetalleOrdenCompra: det, cantidad: 24, codigoLote: `PL-${unico}-1` },
            { idDetalleOrdenCompra: det, cantidad: 24, codigoLote: `PL-${unico}-2` },
        ] } });
        const lotes = (await pedir(`/inventario/variantes/${varFibra.idVariante}/lotes`)).data ?? [];
        const nuevas = lotes.filter((l) => String(l.lot_codigo_proveedor ?? l.codigo ?? "").startsWith(`PL-${unico}`));
        ok(r.status === 201 && nuevas.length === 2, "recepción de 2 planchas = 2 lotes (piezas) de 24 pie²", { status: r.status, lotes: nuevas });
    }
}

// ------------------------------------------------------------ Inventario
seccion("Inventario: stock, ajuste, fraccionamiento, kárdex");
r = await pedir(`/inventario/stock?q=${codigo.toLowerCase()}`);
const stockNegro = r.data?.find((s) => s.id_variante === varNegro?.idVariante);
ok(r.status === 200 && stockNegro?.stock_fisico === 120, "stock refleja la recepción (120 u)", r.json);
// Inventario por producto (front: producto -> variantes -> kardex)
r = await pedir(`/inventario/stock?idProducto=${producto?.idProducto}&limit=50`);
ok(r.status === 200 && r.data.length === producto?.variantes?.length && r.data.every((s) => s.id_producto === producto?.idProducto),
    "stock filtrado por producto: todas sus variantes y solo esas", { n: r.data?.length });
r = await pedir("/inventario/stock?idProducto=abc");
ok(r.status === 422, "idProducto no numérico -> 422 (validación)", r.json);
r = await pedir("/catalogo/productos?requiereCompra=1&limit=50");
ok(r.status === 200 && r.data.every((p) => p.requiereCompra), "productos por reponer: solo los que tienen alguna variante bajo el mínimo", { n: r.data?.length });
r = await pedir("/inventario/ajustes", { metodo: "POST", cuerpo: { idVariante: varNegro?.idVariante, tipo: "MER", cantidad: 2, motivo: "Merma de humo" } });
ok(r.status === 201, "merma registrada (fn_registrar_ajuste)", r.json);
r = await pedir("/inventario/ajustes", { metodo: "POST", cuerpo: { idVariante: varNegro?.idVariante, tipo: "AJN", cantidad: 99999, motivo: "Demasiado" } });
ok(r.status === 409, "ajuste mayor que el stock lo rechaza la base -> 409", r.json);
r = await pedir(`/inventario/variantes/${varNegro?.idVariante}/lotes`);
const lote = r.data?.[0];
ok(r.status === 200 && lote?.saldo === 118, "lote con saldo 118", r.json);
r = await pedir(`/inventario/lotes/${lote?.id_lote}/fraccionar`, { metodo: "POST", cuerpo: { piezas: [12, 12], motivo: "Bolsas de docena" } });
ok(r.status === 201 && r.data.paquetes.length === 2, "fraccionar en 2 paquetes (fn_fraccionar_lote)", r.json);
r = await pedir(`/inventario/variantes/${varNegro?.idVariante}/kardex`);
ok(r.status === 200 && r.data.length >= 4 && r.data.some((k) => k.tipo === "MER"), "kárdex con recepción, merma y fraccionamiento", r.json);

// ------------------------------------------------------------ Ventas
seccion("Ventas: cliente -> pedido en tienda -> pago -> factura -> entrega");
r = await pedir("/clientes", { metodo: "POST", cuerpo: { nombres: `Taller Humo ${unico}`, correo: `humo.${unico.toLowerCase()}@taller.ec` } });
ok(r.status === 201, "cliente creado", r.json);
const idCliente = r.data?.idCliente;
r = await pedir("/datos-facturacion", {
    metodo: "POST",
    cuerpo: { idCliente, idTipoIdentificacion: "05", identificacion: cedula("171765432"), razonSocial: `TALLER HUMO ${unico}` },
});
ok(r.status === 201, "datos de facturación con cédula válida", r.json);
const idDatos = r.data?.idDatosFacturacion;
const unidad = varNegro?.presentaciones.find((p) => p.descripcion === "Unidad");
r = await pedir("/ventas/pedidos", { metodo: "POST", cuerpo: { idCliente, canal: "TDA", lineas: [{ idPresentacion: unidad?.idPresentacion, cantidad: 10 }] } });
ok(r.status === 201 && r.data.estado === "PEN" && r.data.lineas.length === 1, "pedido en tienda (fn_crear_pedido)", r.json);
const pedido = r.data;
r = await pedir("/ventas/pedidos", { metodo: "POST", cuerpo: { idCliente, canal: "TDA", lineas: [{ idPresentacion: unidad?.idPresentacion, cantidad: 1.5 }] } });
ok(r.status === 409, "1.5 unidades lo rechaza la base (incremento) -> 409", r.json);
const metodo = (await pedir("/metodos-pago?q=efectivo")).data?.[0];
r = await pedir(`/ventas/pedidos/${pedido?.idPedido ?? pedido?.id}/pagos`, { metodo: "POST", cuerpo: { idMetodoPago: metodo?.idMetodoPago, monto: pedido?.total } });
ok(r.status === 201 && r.data.cubierto >= r.data.total && r.data.estado === "PAG", "pago completo: pedido pasa a PAG (fn_registrar_pago)", r.json);
const punto = (await pedir("/puntos-emision")).data?.[0];
r = await pedir(`/ventas/pedidos/${pedido?.id}/factura`, { metodo: "POST", cuerpo: { idDatosFacturacion: idDatos, idPuntoEmision: punto?.idPuntoEmision, tipo: "01" } });
ok(r.status === 201 && r.data.pedido.comprobantes.length === 1 && r.data.pedido.estado === "FAC", "factura emitida (fn_facturar_pedido)", r.json);
r = await pedir(`/ventas/pedidos/${pedido?.id}/estado`, { metodo: "POST", cuerpo: { estado: "DES" } });
ok(r.status === 409 && /sin envío/.test(r.json.message), "venta de mostrador sin envío no pasa por despacho -> 409 (regla de la base)", r.json);
r = await pedir(`/ventas/pedidos/${pedido?.id}/estado`, { metodo: "POST", cuerpo: { estado: "ENT" } });
ok(r.status === 200 && r.data.estado === "ENT", "pedido entregado en tienda", r.json);
r = await pedir(`/inventario/stock?q=${codigo.toLowerCase()}`);
ok(r.data?.find((s) => s.id_variante === varNegro?.idVariante)?.stock_fisico === 108, "la factura descontó 10 u del stock (118 -> 108)", r.json);
r = await pedir("/ventas/pedidos?canal=TDA&limit=5");
ok(r.status === 200 && r.data.some((p) => p.id_pedido === pedido?.id), "listado de pedidos por canal");

// ------------------------------------------------------------ Seguridad
seccion("Seguridad: usuarios, roles y permisos");
// apellido solo con letras (el codigo de corrida tiene digitos): 0-9 -> a-j
const apellidoHumo = `Humo${unico.toLowerCase().replace(/\d/g, (d) => "abcdefghij"[d])}`;
const fichaBodega = { nombres: "Bodeguero", apellidos: `${apellidoHumo} Prueba`, idTipoIdentificacion: "05", // tercer digito 0: en la cedula va de 0 a 5 (con 6-9 ningun verificador es valido)
    identificacion: cedula(`170${String(Date.now() % 1000000).padStart(6, "0")}`) };
const claveBodega = `Bodega${unico}x9`;
r = await pedir("/seguridad/usuarios/correo-sugerido?nombres=Bodeguero&apellidos=" + encodeURIComponent(fichaBodega.apellidos));
const correoBodega = r.data?.correo;
ok(correoBodega === `bo${apellidoHumo.toLowerCase()}@comercialelite.ec`, `usuario estándar: 2 letras del nombre + primer apellido (${correoBodega})`, r.json);
r = await pedir("/seguridad/usuarios", { metodo: "POST", cuerpo: { ...fichaBodega, clave: "corta", roles: ["BODEGA"] } });
ok(r.status === 422, "clave débil -> 422");
r = await pedir("/seguridad/usuarios", { metodo: "POST", cuerpo: { correo: "otro@x.ec", ...fichaBodega, clave: claveBodega, roles: ["BODEGA"] } });
ok(r.status === 201 && r.data.correo === correoBodega && r.data.empleado, "el usuario se crea con el correo estándar (el que se mande se ignora) y su ficha de empleado", r.json);
ok(r.status === 201 && r.data.roles[0].codigo === "BODEGA", "usuario de bodega creado", r.json);
const idBodega = r.data?.idUsuario;
const tokenBodega = (await pedir("/auth/ingresar", { metodo: "POST", cuerpo: { correo: correoBodega, clave: claveBodega }, conToken: null })).data?.token;
r = await pedir("/catalogo/productos", { metodo: "POST", cuerpo: { codigo: "X" }, conToken: tokenBodega });
ok(r.status === 403, "bodega no puede crear productos -> 403", r.json);
// Cambio de la propia clave: pide la actual, limita intentos y cierra las demas sesiones
r = await pedir("/auth/clave", { metodo: "PUT", cuerpo: { claveActual: "NoEsLaClave1x", claveNueva: `Nueva${unico}z7Q` }, conToken: tokenBodega });
ok(r.status === 422 && /te quedan 4/.test(JSON.stringify(r.json)), "clave actual errada -> 422 con los intentos que quedan", r.json);
r = await pedir("/auth/clave", { metodo: "PUT", cuerpo: { claveActual: claveBodega, claveNueva: claveBodega }, conToken: tokenBodega });
ok(r.status === 422, "la clave nueva igual a la actual -> 422", r.json);
r = await pedir("/auth/clave", { metodo: "PUT", cuerpo: { claveActual: claveBodega, claveNueva: `Nueva${unico}z7Q` }, conToken: tokenBodega });
ok(r.status === 204, "cambio de clave con la clave actual correcta -> 204", r.json);
r = await pedir("/inventario/stock", { conToken: tokenBodega });
ok(r.status === 401 && /clave cambió/.test(r.json?.message ?? ""), "el token anterior al cambio deja de valer -> 401", r.json);
const tokenNuevo = (await pedir("/auth/ingresar", { metodo: "POST", cuerpo: { correo: correoBodega, clave: `Nueva${unico}z7Q` }, conToken: null })).data?.token;
ok(Boolean(tokenNuevo), "ingresa con la clave nueva");
r = await pedir(`/seguridad/usuarios/${idBodega}`, { metodo: "PATCH", cuerpo: { activo: 0 } });
ok(r.status === 200 && r.data.activo === false, "usuario desactivado");
r = await pedir("/inventario/stock", { conToken: tokenNuevo });
ok(r.status === 401, "un usuario desactivado pierde el acceso de inmediato -> 401");
r = await pedir(`/seguridad/usuarios/${yo?.idUsuario}`, { metodo: "PATCH", cuerpo: { activo: 0 } });
ok(r.status === 409, "nadie puede desactivarse a sí mismo -> 409");
r = await pedir("/seguridad/roles", { metodo: "POST", cuerpo: { nombre: `Cajero humo ${apellidoHumo}`, permisos: ["VENTA_REGISTRAR", "PAGO_REGISTRAR"] } });
const rolNuevo = r.data?.codigo;
ok(r.status === 201 && /^CAJERO_HUMO/.test(rolNuevo ?? ""), `rol nuevo con código automático (${rolNuevo})`, r.json);
r = await pedir(`/seguridad/roles/${rolNuevo}`, { metodo: "PUT", cuerpo: { permisos: ["VENTA_REGISTRAR"] } });
ok(r.status === 200, "los permisos de un rol se editan", r.json);
r = await pedir("/seguridad/roles/ADMIN", { metodo: "PUT", cuerpo: { permisos: ["VENTA_REGISTRAR"] } });
ok(r.status === 409, "ADMIN no puede perder el permiso de gestionar usuarios -> 409", r.json);
r = await pedir(`/seguridad/roles/${rolNuevo}`, { metodo: "DELETE" });
ok(r.status === 204, "un rol sin usuarios se elimina", r.json);
r = await pedir("/seguridad/roles");
ok(r.status === 200 && r.data.some((x) => x.codigo === "ADMIN" && x.permisos.length >= 10), "roles con sus permisos");

// ------------------------------------------------------------ Reportes
seccion("Reportes");
r = await pedir("/reportes/resumen");
ok(r.status === 200 && r.data.productos_publicados > 0, "resumen del tablero", r.json);
r = await pedir("/reportes");
ok(r.status === 200 && r.data.length >= 5, "lista de reportes del usuario");
r = await pedir("/reportes/ventas-por-canal");
ok(r.status === 200 && Array.isArray(r.data), "reporte ventas por canal");
r = await pedir("/reportes/auditoria");
ok(r.status === 200 && r.data.some((e) => e.evento === "LOGIN_OK"), "bitácora registra los ingresos", r.json);
r = await pedir("/reportes/indicadores?desde=2026-11-01&hasta=2026-11-30");
ok(r.status === 200 && r.data.some((k) => k.clave === "vendido" && "variacion" in k) && r.json.meta.periodo.anteriorHasta === "2026-10-31",
    "indicadores con el período anterior de igual largo", r.json);
r = await pedir("/reportes/ventas-por-periodo?desde=2026-11-01&hasta=2026-11-30&agrupar=semana");
ok(r.status === 200 && r.json.meta.reporte.columnas.length > 0 && "total" in r.json.meta.totales && r.json.meta.parametros.agrupar === "semana",
    "reporte con metadatos (columnas tipadas), totales y parámetros", r.json);
r = await pedir("/reportes/tableros");
ok(r.status === 200 && r.data[0].widgets.some((w) => w.tipo === "indicadores"), "configuración de tableros (widgets)");
r = await pedir("/reportes/ventas-por-periodo?desde=2026-12-01&hasta=2026-11-01");
ok(r.status === 422, "período al revés -> 422");
r = await pedir("/reportes/no-existe");
ok(r.status === 404, "reporte desconocido -> 404");

console.log(`\n${fallos === 0 ? "✔" : "✖"} ${pruebas - fallos} de ${pruebas} pruebas de humo en orden.`);
process.exit(fallos === 0 ? 0 : 1);
