// db/generar-catalogo.mjs
// Genera db/02_catalogo_inicial.sql a partir del catalogo del frontend
// (negocio tailwind/comercial-elite/data/catalogo.json), para que la base y el
// sitio estatico partan de los mismos productos.
//
//   node db/generar-catalogo.mjs [ruta/catalogo.json]
//
// Mapeo al modelo de Comercial Elite (3FN):
//   categoria del JSON  -> categoria raiz (linea)       cat_codigo = slug
//   subcategoria        -> categoria hija de la linea
//   producto            -> producto (prd_imagen_url = URL externa de IMAGENES)
//   cada color          -> variante con su valor del atributo "Color"
//   presentacion        -> presentacion de cada variante, con su factor: cuantas
//                          unidades base trae (Cono 500 m = 500 m). El stock se
//                          lleva en la unidad base; el precio es por presentacion.
//   precio (con IVA)    -> historial_precio SIN IVA (la base calcula el IVA)
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const aqui = dirname(fileURLToPath(import.meta.url));
const rutaCatalogo = resolve(
    process.argv[2] ?? resolve(aqui, "../../../negocio tailwind/comercial-elite/data/catalogo.json")
);
const IVA = 0.15; // tarifa '4' (IVA 15%) de los datos base

// prd_imagen_url: la base no depende de las imagenes del repositorio — cada
// producto apunta a una fotografia real con URL externa estable (Wikimedia
// Commons, la miniatura que publica su API). El CHECK de la columna exige http/https.
const IMAGENES = {
    "CE-1042": "https://thumb.wikimedia.org/wikipedia/commons/thumb/2/2d/Tannery_Manila_luxury_leather_cow_hideF.jpg/960px-Tannery_Manila_luxury_leather_cow_hideF.jpg",
    "CE-1043": "https://thumb.wikimedia.org/wikipedia/commons/thumb/6/6e/Nappaleder.JPG/960px-Nappaleder.JPG",
    "CE-2010": "https://thumb.wikimedia.org/wikipedia/commons/thumb/7/70/Synthetic_Leather.jpg/960px-Synthetic_Leather.jpg",
    "CE-2011": "https://thumb.wikimedia.org/wikipedia/commons/thumb/c/cf/Python_bivittatus_skin.jpg/960px-Python_bivittatus_skin.jpg",
    "CE-3005": "https://upload.wikimedia.org/wikipedia/commons/4/48/Shoe_sole_sewing.jpg",
    "CE-3006": "https://thumb.wikimedia.org/wikipedia/commons/thumb/3/34/Hari_Mari_Outsole.jpg/960px-Hari_Mari_Outsole.jpg",
    "CE-4001": "https://thumb.wikimedia.org/wikipedia/commons/thumb/d/de/Rockport_shoe_insole._Torsion_system_technology_by_Adidas_printing.jpg/960px-Rockport_shoe_insole._Torsion_system_technology_by_Adidas_printing.jpg",
    "CE-4002": "https://thumb.wikimedia.org/wikipedia/commons/thumb/9/98/Insoles-Plantillas-Plantari.jpg/960px-Insoles-Plantillas-Plantari.jpg",
    "CE-5001": "https://upload.wikimedia.org/wikipedia/commons/9/96/HKM_Suutarin_pikilankaa.jpg",
    "CE-5002": "https://thumb.wikimedia.org/wikipedia/commons/thumb/a/a1/A_spool_of_bright_red_polyester_thread%2C_a_sewing_needle%2C_and_a_needle_threader.jpg/960px-A_spool_of_bright_red_polyester_thread%2C_a_sewing_needle%2C_and_a_needle_threader.jpg",
    "CE-6001": "https://thumb.wikimedia.org/wikipedia/commons/thumb/e/e9/2023_Butapren.jpg/960px-2023_Butapren.jpg",
    "CE-6002": "https://upload.wikimedia.org/wikipedia/commons/6/62/Den_Braven_Sealants_-_Polyflex_440_cartridge.jpg",
    "CE-7001": "https://thumb.wikimedia.org/wikipedia/commons/thumb/5/5d/Assorted_metal_eyelets_in_plastic_case_HN_Made_in_Sweden_ca_1970.jpg/960px-Assorted_metal_eyelets_in_plastic_case_HN_Made_in_Sweden_ca_1970.jpg",
    "CE-7002": "https://thumb.wikimedia.org/wikipedia/commons/thumb/8/8a/Palladium_Plated_Belt_Buckle.jpg/960px-Palladium_Plated_Belt_Buckle.jpg",
    "CE-8001": "https://thumb.wikimedia.org/wikipedia/commons/thumb/5/5c/Leathertools.jpg/960px-Leathertools.jpg",
    "CE-8002": "https://thumb.wikimedia.org/wikipedia/commons/thumb/b/b5/Marteaux_de_bottier.png/960px-Marteaux_de_bottier.png",
};

const catalogo = JSON.parse(readFileSync(rutaCatalogo, "utf8"));

// Literal SQL seguro: comillas simples duplicadas. Los datos vienen de un JSON
// propio, pero se escapan igual para no romper el script con un apostrofo.
const texto = (valor) => (valor == null ? "NULL" : `'${String(valor).replace(/'/g, "''")}'`);

function precioSinIva(precioConIva, codigo) {
    const base = Math.round((precioConIva / (1 + IVA)) * 100) / 100;
    const reconstruido = Math.round(base * (1 + IVA) * 100) / 100;
    if (reconstruido !== precioConIva) {
        throw new Error(
            `${codigo}: ${precioConIva} con IVA no sale exacto de un precio base de 2 decimales (${base} -> ${reconstruido})`
        );
    }
    return base;
}

// Unidad base del inventario (tabla unidad_medida) y factor de la presentacion de
// cada producto. La banda de cuero varia entre 18 y 29 pies: se toma el punto
// medio (23.5 pie2) como contenido de referencia de una banda.
const MEDIDAS = {
    "CE-1042": { unidad: "pie2", factor: 23.5 },  // Banda 18-29 pies
    "CE-1043": { unidad: "pie2", factor: 23.5 },  // Banda 18-29 pies
    "CE-2010": { unidad: "m", factor: 25 },       // Rollo 1.4 m x 25 m
    "CE-2011": { unidad: "m", factor: 20 },       // Rollo 1.4 m x 20 m
    "CE-3005": { unidad: "par", factor: 1 },
    "CE-3006": { unidad: "par", factor: 1 },
    "CE-4001": { unidad: "par", factor: 1 },
    "CE-4002": { unidad: "par", factor: 1 },
    "CE-5001": { unidad: "m", factor: 500 },      // Cono 500 m
    "CE-5002": { unidad: "m", factor: 1000 },     // Cono 1000 m
    "CE-6001": { unidad: "l", factor: 3.7 },      // Galon 3.7 L
    "CE-6002": { unidad: "kg", factor: 1 },       // Kit 1 kg
    "CE-7001": { unidad: "u", factor: 1000 },     // Bolsa x 1000 u
    "CE-7002": { unidad: "u", factor: 100 },      // Caja x 100 u
    "CE-8001": { unidad: "u", factor: 1 },
    "CE-8002": { unidad: "u", factor: 1 },
};

const lineas = new Map(catalogo.categorias.map((c) => [c.slug, c.nombre]));
const subcategorias = new Map(); // "linea|sub" -> codigo
const llamadas = [];

for (const p of catalogo.productos) {
    if (!lineas.has(p.categoria)) throw new Error(`${p.id}: categoria desconocida ${p.categoria}`);
    const claveSub = `${p.categoria}|${p.subcategoria}`;
    if (!subcategorias.has(claveSub)) {
        const n = [...subcategorias.keys()].filter((k) => k.startsWith(`${p.categoria}|`)).length + 1;
        subcategorias.set(claveSub, `${p.categoria}-${n}`); // cat_codigo es VARCHAR2(20)
    }
    const medida = MEDIDAS[p.id];
    if (!medida) throw new Error(`${p.id}: falta su unidad de medida y factor en MEDIDAS`);
    const imagenUrl = IMAGENES[p.id];
    if (!imagenUrl) throw new Error(`${p.id}: falta su URL de imagen en IMAGENES`);
    const colores = `SYS.ODCIVARCHAR2LIST(${p.colores.map(texto).join(", ")})`;
    llamadas.push(
        `    producto(${texto(p.id)}, ${texto(p.nombre)}, ${texto(p.categoria)}, ` +
            `${texto(subcategorias.get(claveSub))}, ${texto(p.subcategoria)},\n` +
            `             ${texto(medida.unidad)}, ${texto(p.uso)}, ` +
            `${texto(imagenUrl)},\n` +
            `             DATE ${texto(p.fechaIngreso)}, ${texto(p.presentacion)}, ${medida.factor}, ` +
            `${precioSinIva(p.precio, p.id).toFixed(2)}, ${colores});`
    );
}

const sqlLineas = [...lineas].map(([slug, nombre]) => `    v_id := categoria(${texto(slug)}, ${texto(nombre)}, NULL);`);

const sql = `/*==============================================================*/
/* Catalogo inicial de Comercial Elite (GENERADO, no editar)    */
/*   node db/generar-catalogo.mjs                                */
/* Fuente: data/catalogo.json del frontend.                     */
/*                                                              */
/* Como SYSTEM/SYSDBA en la PDB (escribe en el nodo PRODUCCION):*/
/*   sqlplus system@//localhost:1521/FREEPDB1 @02_catalogo_inicial.sql */
/*                                                              */
/* Se puede correr mas de una vez: un producto que ya existe    */
/* solo actualiza su uso e imagen (el historial de precios es   */
/* inmutable y no se duplica).                                  */
/*==============================================================*/
SET DEFINE OFF
SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
ALTER SESSION SET CURRENT_SCHEMA = produccion;

DECLARE
    v_usuario NUMBER;
    v_color   NUMBER;
    v_id      NUMBER;
    v_nuevos  PLS_INTEGER := 0;

    FUNCTION categoria(p_codigo IN VARCHAR2, p_nombre IN VARCHAR2, p_padre IN VARCHAR2) RETURN NUMBER IS
        v_cat   NUMBER;
        v_padre NUMBER;
    BEGIN
        SELECT MAX(id_categoria) INTO v_cat FROM categoria WHERE cat_codigo = p_codigo;
        IF v_cat IS NULL THEN
            IF p_padre IS NOT NULL THEN
                SELECT id_categoria INTO v_padre FROM categoria WHERE cat_codigo = p_padre;
            END IF;
            INSERT INTO categoria (id_categoria_padre, cat_codigo, cat_nombre)
            VALUES (v_padre, p_codigo, p_nombre)
            RETURNING id_categoria INTO v_cat;
            -- El color se define en la linea y lo heredan sus subcategorias
            IF p_padre IS NULL THEN
                INSERT INTO categoria_atributo (id_categoria, id_atributo) VALUES (v_cat, v_color);
            END IF;
        END IF;
        RETURN v_cat;
    END categoria;

    FUNCTION valor_color(p_valor IN VARCHAR2) RETURN NUMBER IS
        v_val NUMBER;
    BEGIN
        SELECT MAX(id_valor_atributo) INTO v_val
        FROM valor_atributo WHERE id_atributo = v_color AND val_valor = p_valor;
        IF v_val IS NULL THEN
            INSERT INTO valor_atributo (id_atributo, val_valor) VALUES (v_color, p_valor)
            RETURNING id_valor_atributo INTO v_val;
        END IF;
        RETURN v_val;
    END valor_color;

    PROCEDURE producto(p_codigo IN VARCHAR2, p_nombre IN VARCHAR2, p_linea IN VARCHAR2,
                       p_sub_codigo IN VARCHAR2, p_sub_nombre IN VARCHAR2, p_unidad IN VARCHAR2,
                       p_uso IN VARCHAR2, p_imagen_url IN VARCHAR2, p_fecha IN DATE,
                       p_presentacion IN VARCHAR2, p_factor IN NUMBER, p_precio IN NUMBER,
                       p_colores IN SYS.ODCIVARCHAR2LIST) IS
        v_prd NUMBER;
        v_cat NUMBER;
        v_var NUMBER;
        v_val NUMBER;
        v_pre NUMBER;
    BEGIN
        SELECT MAX(id_producto) INTO v_prd FROM producto WHERE prd_codigo = p_codigo;
        IF v_prd IS NOT NULL THEN
            UPDATE producto SET prd_uso = p_uso, prd_imagen_url = p_imagen_url WHERE id_producto = v_prd;
            RETURN;
        END IF;

        -- Las funciones locales del bloque no se pueden llamar dentro de un SQL
        v_cat := categoria(p_sub_codigo, p_sub_nombre, p_linea);
        INSERT INTO producto (id_categoria, id_unidad_medida, id_tarifa_iva, prd_codigo, prd_nombre,
                              prd_uso, prd_imagen_url, prd_publicado, prd_fecha_creacion)
        VALUES (v_cat, p_unidad, '4', p_codigo, p_nombre,
                p_uso, p_imagen_url, 1, CAST(p_fecha AS TIMESTAMP))
        RETURNING id_producto INTO v_prd;

        FOR i IN 1 .. p_colores.COUNT LOOP
            INSERT INTO variante (id_producto, var_sku)
            VALUES (v_prd, p_codigo || '-' || LPAD(i, 2, '0'))
            RETURNING id_variante INTO v_var;
            v_val := valor_color(p_colores(i));
            INSERT INTO variante_valor (id_variante, id_atributo, id_valor_atributo)
            VALUES (v_var, v_color, v_val);
            INSERT INTO presentacion (id_variante, pre_descripcion, pre_factor)
            VALUES (v_var, p_presentacion, p_factor)
            RETURNING id_presentacion INTO v_pre;
            INSERT INTO historial_precio (id_presentacion, hpr_precio, hpr_vigente_desde, id_usuario)
            VALUES (v_pre, p_precio, CAST(p_fecha AS TIMESTAMP), v_usuario);
        END LOOP;
        v_nuevos := v_nuevos + 1;
    END producto;
BEGIN
    -- Usuario tecnico de los datos base: queda como autor en precios y auditoria
    SELECT id_usuario INTO v_usuario FROM usuario WHERE usu_correo = 'sistema@comercialelite.local';
    fn_usuario_sesion(v_usuario);

    SELECT MAX(id_atributo) INTO v_color FROM atributo WHERE atr_nombre = 'Color';
    IF v_color IS NULL THEN
        INSERT INTO atributo (atr_nombre, atr_tipo_dato) VALUES ('Color', 'COLOR')
        RETURNING id_atributo INTO v_color;
    END IF;

    -- Lineas (categorias raiz), en el orden del catalogo
${sqlLineas.join("\n")}

    -- Productos
${llamadas.join("\n")}

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Catalogo inicial: ' || v_nuevos || ' productos nuevos, ${catalogo.productos.length} en total.');
END;
/
EXIT
`;

const destino = resolve(aqui, "02_catalogo_inicial.sql");
writeFileSync(destino, sql);
console.log(`Generado ${destino} (${catalogo.productos.length} productos, imagenes con URL externa)`);
