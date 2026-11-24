/*==============================================================*/
/* Migracion: saldo de lotes y piezas libres calculados POR     */
/* LOTE (medido en db/bench/simulacion/INFORME.md)              */
/*                                                              */
/* v_lote_saldo agrupaba TODO el kardex y recorria el arbol de  */
/* cortes de TODOS los lotes antes de filtrar: a 300.000 lotes, */
/* 1,4 s por variante y 89 s una pagina de inventario. La usan  */
/* fn_consumir_lotes y fn_facturar_pedido (vender), v_pieza_    */
/* libre (disponible del cuero en el catalogo) y el inventario. */
/*                                                              */
/*  - v_lote_saldo: CROSS APPLY por lote; la raiz del arbol con */
/*    subconsulta escalar (asi CONNECT BY usa el indice)        */
/*    -> 0,01 s por variante.                                   */
/*  - v_pieza_libre: lo reservado por pieza con OUTER APPLY y   */
/*    el estado actual del pedido por su indice (antes:         */
/*    estado de TODOS los pedidos).                             */
/*  - v_lote_saldo_total: la definicion agrupada anterior, para */
/*    reportes que recorren TODOS los lotes (ahi agrupar de una */
/*    vez es mas rapido que lote por lote: 3 s vs 7 s).         */
/*                                                              */
/* Mismas columnas y mismos valores: comparadas fila por fila   */
/* con las anteriores (MINUS en ambos sentidos = 0).            */
/* Se puede correr mas de una vez.                              */
/*==============================================================*/
SET DEFINE OFF
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
ALTER SESSION SET CURRENT_SCHEMA = produccion;

CREATE OR REPLACE VIEW v_lote_saldo_total AS
WITH ingreso AS (
    SELECT dm.id_lote, MIN(m.mov_fechahora) AS fecha
    FROM detalle_movimiento dm
    JOIN movimiento_inventario m ON m.id_movimiento = dm.id_movimiento
    GROUP BY dm.id_lote
)
SELECT l.id_lote,
       l.id_variante,
       l.id_lote_origen,
       l.lot_codigo_proveedor,
       l.lot_costo_unitario,
       l.lot_fecha_vencimiento,
       i.fecha                                                             AS fecha_ingreso,
       SUM(CASE WHEN t.tmv_signo = 1 THEN dm.dmo_cantidad END)             AS entradas,
       NVL(SUM(CASE WHEN t.tmv_signo = -1 THEN dm.dmo_cantidad END), 0)    AS salidas,
       SUM(dm.dmo_cantidad * t.tmv_signo)                                  AS saldo,
       MAX(m.mov_fechahora)                                                AS ultimo_movimiento,
       TRUNC(SYSDATE) - TRUNC(CAST(i.fecha AS DATE))                       AS dias_en_inventario
FROM lote l
JOIN v_lote_raiz           lr ON lr.id_lote       = l.id_lote
JOIN ingreso               i  ON i.id_lote        = lr.id_lote_raiz
JOIN detalle_movimiento    dm ON dm.id_lote       = l.id_lote
JOIN movimiento_inventario m  ON m.id_movimiento  = dm.id_movimiento
JOIN tipo_movimiento       t  ON t.id_tipo_movimiento = m.id_tipo_movimiento
GROUP BY l.id_lote, l.id_variante, l.id_lote_origen, l.lot_codigo_proveedor, l.lot_costo_unitario,
         l.lot_fecha_vencimiento, i.fecha
;
GRANT SELECT ON v_lote_saldo_total TO elite_produccion;

CREATE OR REPLACE VIEW v_lote_saldo AS
SELECT l.id_lote,
       l.id_variante,
       l.id_lote_origen,
       l.lot_codigo_proveedor,
       l.lot_costo_unitario,
       l.lot_fecha_vencimiento,
       i.fecha                                                             AS fecha_ingreso,
       a.entradas,
       a.salidas,
       a.saldo,
       a.ultimo_movimiento,
       TRUNC(SYSDATE) - TRUNC(CAST(i.fecha AS DATE))                       AS dias_en_inventario
FROM lote l
-- fecha de ingreso = primer movimiento del lote RAIZ (de donde se corto esta pieza).
-- La raiz se busca con una subconsulta escalar: asi Oracle recorre el arbol con
-- el indice (CONNECT BY WITH FILTERING); dentro de un APPLY lo hacia leyendo
-- toda la tabla de lotes por cada fila.
CROSS APPLY (SELECT MIN(m.mov_fechahora) AS fecha
             FROM detalle_movimiento dm
             JOIN movimiento_inventario m ON m.id_movimiento = dm.id_movimiento
             WHERE dm.id_lote = (SELECT rz.id_lote FROM lote rz
                                 WHERE rz.id_lote_origen IS NULL
                                 START WITH rz.id_lote = l.id_lote
                                 CONNECT BY rz.id_lote = PRIOR rz.id_lote_origen)
             HAVING COUNT(*) > 0) i
-- saldo: solo los movimientos de ESTE lote
CROSS APPLY (SELECT SUM(CASE WHEN t.tmv_signo = 1 THEN dm.dmo_cantidad END)          AS entradas,
                    NVL(SUM(CASE WHEN t.tmv_signo = -1 THEN dm.dmo_cantidad END), 0) AS salidas,
                    SUM(dm.dmo_cantidad * t.tmv_signo)                               AS saldo,
                    MAX(m.mov_fechahora)                                             AS ultimo_movimiento
             FROM detalle_movimiento dm
             JOIN movimiento_inventario m ON m.id_movimiento = dm.id_movimiento
             JOIN tipo_movimiento       t ON t.id_tipo_movimiento = m.id_tipo_movimiento
             WHERE dm.id_lote = l.id_lote
             HAVING COUNT(*) > 0) a
;

CREATE OR REPLACE VIEW v_pieza_libre AS
SELECT ls.id_lote,
       ls.id_variante,
       ls.id_lote_origen,
       ls.lot_codigo_proveedor,
       ls.fecha_ingreso,
       ls.saldo,
       NVL(r.reservado, 0)                                                 AS reservado,
       ls.saldo - NVL(r.reservado, 0)                                      AS libre
FROM v_lote_saldo ls
-- reservado de ESTA pieza por pedidos cuyo estado actual es PEN o PAG
OUTER APPLY (SELECT SUM(d.dpe_cantidad * pr.pre_factor) AS reservado
             FROM detalle_pedido d
             JOIN presentacion pr ON pr.id_presentacion = d.id_presentacion
             WHERE d.id_lote_reservado = ls.id_lote
               AND (SELECT MAX(h.id_estado_pedido) KEEP (DENSE_RANK LAST ORDER BY h.hep_fechahora, h.id_historial_estado)
                    FROM historial_estado_pedido h WHERE h.id_pedido = d.id_pedido) IN ('PEN', 'PAG')) r
WHERE ls.saldo > 0
;

ALTER SESSION SET CURRENT_SCHEMA = ecommerce;
BEGIN
    DBMS_UTILITY.COMPILE_SCHEMA(schema => 'PRODUCCION', compile_all => FALSE);
    DBMS_UTILITY.COMPILE_SCHEMA(schema => 'ECOMMERCE', compile_all => FALSE);
END;
/
SELECT owner, object_name, object_type FROM dba_objects WHERE owner IN ('PRODUCCION', 'ECOMMERCE') AND status <> 'VALID';
PROMPT (si la consulta anterior no devolvio filas, todo quedo valido)
EXIT
