/*==============================================================*/
/* Migracion: el cuero se vende POR PIEZA (bandas medidas)      */
/*                                                              */
/* Caso de uso del negocio: una banda de cuero mide entre 18 y  */
/* 29 pie2; venderla con un factor fijo de 23.5 era ambiguo (no */
/* se sabia si se entregaba de mas o de menos). Con esta        */
/* migracion el cuero sigue el patron "venta por pieza" que la  */
/* base ya preve (prd_venta_por_pieza, lotes como piezas,       */
/* fn_fraccionar_lote):                                         */
/*                                                              */
/*  1. CE-1042 y CE-1043 pasan a prd_venta_por_pieza = 1.       */
/*  2. La presentacion "Banda 18-29 pies" (factor 23.5) se      */
/*     desactiva; entran "Pie2 al detal" (min 1) y "Pie2 precio */
/*     banda" (min 10, mas barato), ambas factor 1: el precio   */
/*     es por pie2 y la cantidad se pide en pie2. Igual que el  */
/*     cuero CUE-NAPA de la demo de la base.                    */
/*  3. El lote agregado del inventario inicial de cada variante */
/*     se fracciona en bandas individuales con su area medida   */
/*     (fn_fraccionar_lote: sale FRS, entra FRE, cada banda es  */
/*     un lote con su pieza de origen).                         */
/*  4. Nueva vista produccion.v_pieza_web (y espejo             */
/*     ecommerce.v_pieza_web): las piezas con saldo de los      */
/*     productos por pieza, para que la tienda muestre cuantas  */
/*     bandas hay y cuanto mide cada una. No expone costos.     */
/*  5. v_catalogo expone venta_por_pieza (ultima columna) y se  */
/*     recrea v_catalogo_web.                                   */
/*                                                              */
/* Se puede correr mas de una vez: cada paso verifica su estado.*/
/*                                                              */
/* Como SYSTEM/SYSDBA en la PDB:                                */
/*   sqlplus system@//localhost:1521/FREEPDB1 @06_cuero_por_pieza.sql */
/*==============================================================*/
SET DEFINE OFF
SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

ALTER SESSION SET CURRENT_SCHEMA = produccion;

DECLARE
    v_sistema NUMBER;
    v_bodega  NUMBER;

    -- Presentacion por pie2: la crea si falta (con su precio) y la deja activa.
    PROCEDURE pie2(p_variante IN NUMBER, p_desc IN VARCHAR2, p_minima IN NUMBER, p_precio IN NUMBER) IS
        v_pre NUMBER;
    BEGIN
        SELECT MAX(id_presentacion) INTO v_pre
        FROM presentacion WHERE id_variante = p_variante AND pre_descripcion = p_desc;
        IF v_pre IS NULL THEN
            INSERT INTO presentacion (id_variante, pre_descripcion, pre_factor, pre_cantidad_minima)
            VALUES (p_variante, p_desc, 1, p_minima)
            RETURNING id_presentacion INTO v_pre;
            -- Vigencia desde ayer: LOCALTIMESTAMP depende de la zona horaria de
            -- la sesion que instala; si difiere de la de la API (p. ej. UTC del
            -- contenedor vs hora local), el precio quedaria "a futuro" y
            -- v_precio_vigente dejaria el producto fuera del catalogo por horas.
            INSERT INTO historial_precio (id_presentacion, hpr_precio, hpr_vigente_desde, id_usuario)
            VALUES (v_pre, p_precio, CAST(SYSDATE - 1 AS TIMESTAMP), v_sistema);
        END IF;
    END;

    -- Fracciona el lote agregado del inventario inicial en bandas medidas,
    -- solo si la variante sigue intacta: un unico lote, sin cortes previos.
    PROCEDURE bandas(p_sku IN VARCHAR2, p_areas IN VARCHAR2) IS
        v_lote  NUMBER;
        v_n     NUMBER;
        v_hijos NUMBER;
        v_dummy SYS.ODCINUMBERLIST;
    BEGIN
        SELECT COUNT(*), MAX(l.id_lote) INTO v_n, v_lote
        FROM lote l JOIN variante v ON v.id_variante = l.id_variante
        WHERE v.var_sku = p_sku;
        IF v_n <> 1 THEN
            DBMS_OUTPUT.PUT_LINE('  = ' || p_sku || ': ya tiene ' || v_n || ' lotes, no se fracciona');
            RETURN;
        END IF;
        SELECT COUNT(*) INTO v_hijos FROM lote WHERE id_lote_origen = v_lote;
        IF v_hijos > 0 THEN
            DBMS_OUTPUT.PUT_LINE('  = ' || p_sku || ': ya fraccionado');
            RETURN;
        END IF;
        v_dummy := fn_fraccionar_lote(v_lote, p_areas, v_bodega,
                                      'Medicion de bandas individuales (cuero por pieza)');
        DBMS_OUTPUT.PUT_LINE('  + ' || p_sku || ': bandas ' || p_areas);
    END;
BEGIN
    SELECT id_usuario INTO v_sistema FROM usuario WHERE usu_correo = 'sistema@comercialelite.local';
    SELECT MAX(id_usuario) INTO v_bodega FROM usuario WHERE usu_correo = 'inventario@comercialelite.local';
    IF v_bodega IS NULL THEN
        RAISE_APPLICATION_ERROR(-20000, 'Falta el usuario de bodega: correr antes 03_inventario_inicial.sql');
    END IF;
    fn_usuario_sesion(v_bodega);

    -- 1. El cuero se vende por pieza
    UPDATE producto SET prd_venta_por_pieza = 1
    WHERE prd_codigo IN ('CE-1042', 'CE-1043') AND prd_venta_por_pieza = 0;

    -- 2. Presentaciones por pie2 (la banda de factor fijo se desactiva)
    FOR v IN (SELECT v.id_variante, p.prd_codigo
              FROM variante v JOIN producto p ON p.id_producto = v.id_producto
              WHERE p.prd_codigo IN ('CE-1042', 'CE-1043')) LOOP
        UPDATE presentacion SET pre_activa = 0
        WHERE id_variante = v.id_variante AND pre_descripcion = 'Banda 18-29 pies' AND pre_activa = 1;
        -- precios SIN IVA por pie2; el precio banda es el incentivo a llevar mas
        IF v.prd_codigo = 'CE-1042' THEN
            pie2(v.id_variante, 'Pie2 al detal',      1, 2.10);
            pie2(v.id_variante, 'Pie2 precio banda', 10, 1.90);
        ELSE
            pie2(v.id_variante, 'Pie2 al detal',      1, 2.40);
            pie2(v.id_variante, 'Pie2 precio banda', 10, 2.15);
        END IF;
    END LOOP;

    -- 3. El inventario agregado se convierte en bandas medidas (suman lo mismo:
    --    12x23.5=282, 8x23.5=188, 10x23.5=235, 6x23.5=141, 3x23.5=70.5)
    bandas('CE-1042-01', '[18, 19.5, 20, 21, 22, 23, 24, 25, 26, 27, 28, 28.5]');
    bandas('CE-1042-02', '[19, 21, 22, 23, 24, 25, 26, 28]');
    bandas('CE-1043-01', '[18.5, 20, 21, 22, 23, 23.5, 24.5, 26, 27.5, 29]');
    bandas('CE-1043-02', '[19, 21.5, 23, 24, 26, 27.5]');
    bandas('CE-1043-03', '[21, 24, 25.5]');

    COMMIT;
END;
/

-- 4. Piezas visibles para la tienda: cuantas bandas hay y cuanto mide cada una.
--    Solo productos por pieza publicados; sin costos ni vencimientos.
CREATE OR REPLACE VIEW v_pieza_web AS
SELECT p.prd_codigo,
       v.id_variante,
       v.var_sku,
       ls.id_lote,
       ls.lot_codigo_proveedor                                 AS codigo,
       ls.saldo,
       CASE WHEN ls.id_lote_origen IS NULL THEN 1 ELSE 0 END   AS pieza_entera,
       ls.fecha_ingreso
FROM v_lote_saldo ls
JOIN variante v ON v.id_variante = ls.id_variante
JOIN producto p ON p.id_producto = v.id_producto
WHERE p.prd_venta_por_pieza = 1 AND p.prd_publicado = 1 AND v.var_activa = 1 AND ls.saldo > 0;

GRANT SELECT ON produccion.v_pieza_web TO ecommerce WITH GRANT OPTION;
GRANT SELECT ON produccion.v_pieza_web TO elite_ecommerce;

-- 5. v_catalogo expone venta_por_pieza (columna nueva al final; el texto es el
--    de 04_v_catalogo_unidad.sql mas esa columna)
CREATE OR REPLACE VIEW v_catalogo AS
SELECT p.id_producto,
       p.prd_codigo,
       p.prd_nombre,
       c.cat_nombre                                            AS categoria,
       v.id_variante,
       v.var_sku,
       (SELECT LISTAGG(a.atr_nombre || ': ' || va.val_valor, ', ') WITHIN GROUP (ORDER BY a.atr_nombre)
        FROM variante_valor vv
        JOIN valor_atributo va ON va.id_valor_atributo = vv.id_valor_atributo
        JOIN atributo       a  ON a.id_atributo        = vv.id_atributo
        WHERE vv.id_variante = v.id_variante)                  AS caracteristicas,
       pr.id_presentacion,
       pr.pre_descripcion                                      AS presentacion,
       pr.pre_cantidad_minima                                  AS cantidad_minima,
       pv.precio,
       t.tiv_porcentaje                                        AS iva_porcentaje,
       ROUND(pv.precio * (1 + t.tiv_porcentaje / 100), 2)      AS precio_con_iva,
       ov.id_oferta,
       ov.ofe_porcentaje                                       AS pct_oferta,
       ov.ofe_hasta                                            AS oferta_hasta,
       ROUND(pv.precio * (1 - NVL(ov.ofe_porcentaje, 0) / 100), 2) AS precio_final,
       ROUND(ROUND(pv.precio * (1 - NVL(ov.ofe_porcentaje, 0) / 100), 2)
             * (1 + t.tiv_porcentaje / 100), 2)                AS precio_final_con_iva,
       -- en productos por pieza, lo máximo que se puede pedir en una línea
       -- es lo que tiene la pieza más grande
       FLOOR(GREATEST(CASE WHEN p.prd_venta_por_pieza = 1
                           THEN LEAST(s.disponible, NVL((SELECT MAX(ls.saldo) FROM v_lote_saldo ls
                                                         WHERE ls.id_variante = v.id_variante), 0))
                           ELSE s.disponible END, 0) / pr.pre_factor) AS disponible,
       CASE WHEN p.prd_fecha_creacion >= TRUNC(SYSDATE) - 30 THEN 1 ELSE 0 END AS es_novedad,
       -- datos de vitrina para el e-commerce
       p.prd_imagen_url                                        AS imagen_url,
       p.prd_uso                                               AS uso,
       c.cat_codigo                                            AS categoria_codigo,
       NVL(cp.cat_codigo, c.cat_codigo)                        AS linea_codigo,
       NVL(cp.cat_nombre, c.cat_nombre)                        AS linea,
       p.prd_fecha_creacion                                    AS fecha_creacion,
       p.id_unidad_medida                                      AS unidad_codigo,
       um.umd_nombre                                           AS unidad,
       p.prd_venta_por_pieza                                   AS venta_por_pieza
FROM producto p
JOIN categoria         c  ON c.id_categoria     = p.id_categoria
LEFT JOIN categoria    cp ON cp.id_categoria    = c.id_categoria_padre
JOIN unidad_medida     um ON um.id_unidad_medida = p.id_unidad_medida
JOIN tarifa_iva        t  ON t.id_tarifa_iva    = p.id_tarifa_iva
JOIN variante          v  ON v.id_producto      = p.id_producto
JOIN presentacion      pr ON pr.id_variante     = v.id_variante
JOIN v_precio_vigente  pv ON pv.id_presentacion = pr.id_presentacion
JOIN v_stock_variante  s  ON s.id_variante      = v.id_variante
LEFT JOIN v_oferta_vigente ov ON ov.id_producto = p.id_producto
WHERE p.prd_publicado = 1 AND v.var_activa = 1 AND pr.pre_activa = 1 AND c.cat_activa = 1;

-- En Oracle el "SELECT *" de una vista se expande al crearla: las vistas del
-- e-commerce se (re)crean para que vean las columnas nuevas.
-- (CREATE OR REPLACE conserva los permisos ya otorgados.)
ALTER SESSION SET CURRENT_SCHEMA = ecommerce;
CREATE OR REPLACE VIEW v_catalogo_web AS
SELECT * FROM produccion.v_catalogo;
CREATE OR REPLACE VIEW v_pieza_web AS
SELECT * FROM produccion.v_pieza_web;
GRANT SELECT ON ecommerce.v_pieza_web TO elite_ecommerce;

BEGIN
    DBMS_UTILITY.COMPILE_SCHEMA(schema => 'ECOMMERCE', compile_all => FALSE);
    DBMS_UTILITY.COMPILE_SCHEMA(schema => 'PRODUCCION', compile_all => FALSE);
END;
/

SELECT owner, object_name, object_type FROM dba_objects
WHERE owner IN ('PRODUCCION', 'ECOMMERCE') AND status <> 'VALID';
PROMPT (si la consulta anterior no devolvio filas, todo quedo valido)
EXIT
