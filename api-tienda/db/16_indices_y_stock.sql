/*==============================================================*/
/* Migracion: rendimiento del catalogo y de la busqueda de      */
/* clientes (medido en db/bench/INFORME.md)                     */
/*                                                              */
/*  1. Seis indices que faltaban:                               */
/*     - detalle_pedido(id_presentacion): lo reservado          */
/*     - detalle_orden_compra(id_variante): lo que esta en      */
/*       camino                                                 */
/*     - datos_facturacion(dfa_identificacion): cliente por     */
/*       cedula o RUC                                           */
/*     - telefono(tel_numero): cliente por telefono             */
/*     - variante_valor(id_valor_atributo): filtro por color    */
/*     - producto(UPPER(prd_nombre)): busqueda por el inicio    */
/*  2. v_stock_variante reescrita con OUTER APPLY: calcula el   */
/*     saldo, lo reservado y lo en camino SOLO de las variantes */
/*     consultadas. La anterior calculaba el estado de todos    */
/*     los pedidos y el saldo de todos los lotes antes de       */
/*     filtrar (los indices solos no la mejoraban). Mismas      */
/*     columnas y mismos valores: comparada fila por fila con   */
/*     la anterior (MINUS en ambos sentidos = 0 filas).         */
/*                                                              */
/* Se puede correr mas de una vez.                              */
/*==============================================================*/
SET DEFINE OFF
SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
ALTER SESSION SET CURRENT_SCHEMA = produccion;

-- 1. Indices
DECLARE
    PROCEDURE indice(p_nombre VARCHAR2, p_ddl VARCHAR2) IS
        v_n NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_n FROM all_indexes WHERE owner = 'PRODUCCION' AND index_name = UPPER(p_nombre);
        IF v_n = 0 THEN
            EXECUTE IMMEDIATE p_ddl;
            DBMS_OUTPUT.PUT_LINE('  + ' || p_nombre);
        END IF;
    END;
BEGIN
    indice('ix_detalle_pedido_presentacion', 'CREATE INDEX produccion.ix_detalle_pedido_presentacion ON produccion.detalle_pedido (id_presentacion)');
    indice('ix_detalle_oc_variante', 'CREATE INDEX produccion.ix_detalle_oc_variante ON produccion.detalle_orden_compra (id_variante)');
    indice('ix_datos_fact_identificacion', 'CREATE INDEX produccion.ix_datos_fact_identificacion ON produccion.datos_facturacion (dfa_identificacion)');
    indice('ix_telefono_numero', 'CREATE INDEX produccion.ix_telefono_numero ON produccion.telefono (tel_numero)');
    indice('ix_variante_valor_valor', 'CREATE INDEX produccion.ix_variante_valor_valor ON produccion.variante_valor (id_valor_atributo)');
    indice('ix_producto_nombre_mayus', 'CREATE INDEX produccion.ix_producto_nombre_mayus ON produccion.producto (UPPER(prd_nombre))');
END;
/

-- 2. Vista de stock por variante, calculada solo para lo que se consulta
CREATE OR REPLACE VIEW v_stock_variante AS
SELECT v.id_variante,
       v.var_sku,
       p.prd_nombre,
       p.id_unidad_medida                                                      AS unidad,
       NVL(s.stock_fisico, 0)                                                  AS stock_fisico,
       NVL(r.reservado, 0)                                                     AS reservado,
       NVL(s.stock_fisico, 0) - NVL(r.reservado, 0)                            AS disponible,
       NVL(c.en_camino, 0)                                                     AS en_camino,
       v.var_stock_minimo                                                      AS stock_minimo,
       CASE WHEN NVL(s.stock_fisico, 0) - NVL(r.reservado, 0) + NVL(c.en_camino, 0) <= v.var_stock_minimo
            THEN 1 ELSE 0 END                                                  AS requiere_compra,
       ROUND(NVL(s.valor_inventario, 0), 2)                                    AS valor_inventario,
       ROUND(s.antiguedad_promedio_dias, 1)                                    AS antiguedad_promedio_dias,
       s.antiguedad_maxima_dias,
       s.ultimo_movimiento
FROM variante v
JOIN producto p ON p.id_producto = v.id_producto
-- saldo de cada lote de ESTA variante (no de todas): antiguedad desde el ingreso de su lote raiz
OUTER APPLY (
    SELECT SUM(x.saldo)                                                        AS stock_fisico,
           SUM(x.saldo * x.costo)                                              AS valor_inventario,
           SUM(CASE WHEN x.saldo > 0 THEN x.saldo * x.dias END)
               / NULLIF(SUM(CASE WHEN x.saldo > 0 THEN x.saldo END), 0)        AS antiguedad_promedio_dias,
           MAX(CASE WHEN x.saldo > 0 THEN x.dias END)                          AS antiguedad_maxima_dias,
           MAX(x.ultimo)                                                       AS ultimo_movimiento
    FROM (SELECT l.id_lote,
                 l.lot_costo_unitario                                          AS costo,
                 SUM(dm.dmo_cantidad * t.tmv_signo)                            AS saldo,
                 MAX(m.mov_fechahora)                                          AS ultimo,
                 TRUNC(SYSDATE) - TRUNC(CAST((
                     SELECT MIN(m2.mov_fechahora)
                     FROM detalle_movimiento dm2
                     JOIN movimiento_inventario m2 ON m2.id_movimiento = dm2.id_movimiento
                     WHERE dm2.id_lote = (SELECT rz.id_lote FROM lote rz WHERE rz.id_lote_origen IS NULL
                                          START WITH rz.id_lote = l.id_lote
                                          CONNECT BY rz.id_lote = PRIOR rz.id_lote_origen)) AS DATE)) AS dias
          FROM lote l
          JOIN detalle_movimiento    dm ON dm.id_lote = l.id_lote
          JOIN movimiento_inventario m  ON m.id_movimiento = dm.id_movimiento
          JOIN tipo_movimiento       t  ON t.id_tipo_movimiento = m.id_tipo_movimiento
          WHERE l.id_variante = v.id_variante
          GROUP BY l.id_lote, l.lot_costo_unitario) x
) s
-- reservado por pedidos PEN/PAG de ESTA variante (estado actual por el indice de historial)
OUTER APPLY (
    SELECT SUM(d.dpe_cantidad * pr.pre_factor)                                 AS reservado
    FROM detalle_pedido d
    JOIN presentacion pr ON pr.id_presentacion = d.id_presentacion
    WHERE pr.id_variante = v.id_variante
      AND (SELECT MAX(h.id_estado_pedido) KEEP (DENSE_RANK LAST ORDER BY h.hep_fechahora, h.id_historial_estado)
           FROM historial_estado_pedido h WHERE h.id_pedido = d.id_pedido) IN ('PEN', 'PAG')
) r
-- en camino: lo pendiente de recibir de ordenes EMITIDAS de ESTA variante
OUTER APPLY (
    SELECT SUM(GREATEST(d.dco_cantidad - NVL((SELECT SUM(x.dmo_cantidad) FROM detalle_movimiento x
                                              WHERE x.id_detalle_orden_compra = d.id_detalle_orden_compra), 0), 0)) AS en_camino
    FROM detalle_orden_compra d
    JOIN orden_compra oc ON oc.id_orden_compra = d.id_orden_compra
    WHERE d.id_variante = v.id_variante AND oc.oc_estado = 'EMITIDA'
) c
;
BEGIN EXECUTE IMMEDIATE 'DROP VIEW produccion.v_stock_variante_nueva'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN DBMS_STATS.GATHER_SCHEMA_STATS('PRODUCCION'); END;
/
-- Vistas espejo del e-commerce (el SELECT * se expande al crearlas)
ALTER SESSION SET CURRENT_SCHEMA = ecommerce;
CREATE OR REPLACE VIEW v_catalogo_web AS SELECT * FROM produccion.v_catalogo;
BEGIN
    DBMS_UTILITY.COMPILE_SCHEMA(schema => 'PRODUCCION', compile_all => FALSE);
    DBMS_UTILITY.COMPILE_SCHEMA(schema => 'ECOMMERCE', compile_all => FALSE);
END;
/
SELECT owner, object_name, object_type FROM dba_objects WHERE owner IN ('PRODUCCION', 'ECOMMERCE') AND status <> 'VALID';
PROMPT (si la consulta anterior no devolvio filas, todo quedo valido)
EXIT
