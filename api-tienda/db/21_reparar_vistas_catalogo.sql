/*==============================================================*/
/* Migracion: REPARA las vistas del catalogo                    */
/*                                                              */
/* Antes de existir el registro de migraciones, actualizar el   */
/* servidor volvia a correr TODAS las migraciones. Una corrida  */
/* que se detuvo en la 08 (ORA-00904) dejo reescritas por la 04 */
/* y la 06 las vistas v_catalogo, v_pieza_web y el espejo       */
/* v_catalogo_web con versiones VIEJAS (sin cortes, piezas ni   */
/* las columnas que hoy pide la API): la tienda respondia 500   */
/* al leer de Oracle y la cache dejo de sincronizarse.          */
/* Esta migracion vuelve a crear la version vigente de las tres */
/* (copiadas textualmente de la 10 y la 13). Verificado: tras   */
/* reproducir la falla, el codigo de los 222 objetos de la base */
/* queda identico al de una instalacion limpia.                 */
/*                                                              */
/* Se puede correr mas de una vez (solo CREATE OR REPLACE).     */
/*==============================================================*/
SET DEFINE OFF
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
ALTER SESSION SET CURRENT_SCHEMA = produccion;

-- Piezas libres para la tienda (version de la migracion 10)
CREATE OR REPLACE VIEW v_pieza_web AS
SELECT p.prd_codigo,
       v.id_variante,
       v.var_sku,
       pl.id_lote,
       pl.lot_codigo_proveedor                                 AS codigo,
       pl.libre                                                AS saldo,
       CASE WHEN pl.id_lote_origen IS NULL THEN 1 ELSE 0 END   AS pieza_entera,
       pl.fecha_ingreso
FROM v_pieza_libre pl
JOIN variante v ON v.id_variante = pl.id_variante
JOIN producto p ON p.id_producto = v.id_producto
WHERE p.prd_venta_por_pieza = 1 AND p.prd_publicado = 1 AND v.var_activa = 1 AND pl.libre > 0;

-- Catalogo con cortes estandar y piezas (version de la migracion 13)
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
       -- es lo LIBRE de la pieza más grande (sin lo reservado por pedidos pendientes)
       -- cortes estándar: cuántas piezas de esa medida salen de las piezas libres
       CASE WHEN p.prd_cortes_estandar = 1
            THEN fn_disponible_corte(v.id_variante, pr.pre_factor)
            ELSE
       FLOOR(GREATEST(CASE WHEN p.prd_venta_por_pieza = 1
                           THEN LEAST(s.disponible, NVL((SELECT MAX(pl.libre) FROM v_pieza_libre pl
                                                         WHERE pl.id_variante = v.id_variante), 0))
                           ELSE s.disponible END, 0) / pr.pre_factor / pr.pre_incremento)
       * pr.pre_incremento END                                 AS disponible,
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
       p.prd_venta_por_pieza                                   AS venta_por_pieza,
       m.mar_nombre                                            AS marca,
       pr.pre_incremento                                       AS incremento,
       pr.pre_factor                                           AS factor,
       p.prd_cortes_estandar                                   AS cortes_estandar,
       pr.pre_corte_de                                         AS corte_de
FROM producto p
JOIN categoria         c  ON c.id_categoria     = p.id_categoria
LEFT JOIN categoria    cp ON cp.id_categoria    = c.id_categoria_padre
LEFT JOIN marca        m  ON m.id_marca         = p.id_marca AND m.mar_activa = 1
JOIN unidad_medida     um ON um.id_unidad_medida = p.id_unidad_medida
JOIN tarifa_iva        t  ON t.id_tarifa_iva    = p.id_tarifa_iva
JOIN variante          v  ON v.id_producto      = p.id_producto
JOIN presentacion      pr ON pr.id_variante     = v.id_variante
JOIN v_precio_vigente  pv ON pv.id_presentacion = pr.id_presentacion
JOIN v_stock_variante  s  ON s.id_variante      = v.id_variante
LEFT JOIN v_oferta_vigente ov ON ov.id_producto = p.id_producto
WHERE p.prd_publicado = 1 AND v.var_activa = 1 AND pr.pre_activa = 1 AND c.cat_activa = 1;

ALTER SESSION SET CURRENT_SCHEMA = ecommerce;
-- Espejos del e-commerce (el SELECT * se expande al crearlas)
CREATE OR REPLACE VIEW v_catalogo_web AS SELECT * FROM produccion.v_catalogo;
CREATE OR REPLACE VIEW v_pieza_web AS SELECT * FROM produccion.v_pieza_web;

BEGIN
    DBMS_UTILITY.COMPILE_SCHEMA(schema => 'PRODUCCION', compile_all => FALSE);
    DBMS_UTILITY.COMPILE_SCHEMA(schema => 'ECOMMERCE', compile_all => FALSE);
END;
/

SELECT owner, object_name, object_type FROM dba_objects
WHERE owner IN ('PRODUCCION', 'ECOMMERCE') AND status <> 'VALID';
PROMPT (si la consulta anterior no devolvio filas, todo quedo valido)
EXIT
