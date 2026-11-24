/*==============================================================*/
/* Vistas REALES de produccion en SIMULA (generado):            */
/*  - sub-vistas: v_lote_raiz, v_lote_saldo,                    */
/*    v_pedido_estado_actual, v_detalle_pedido_valor,           */
/*    v_orden_compra_detalle (texto copiado de produccion)      */
/*  - v_stock_variante_anterior: la de antes de la migracion 16 */
/*  - v_stock_variante: la optimizada (migracion 16)            */
/*  - OUTBOX para sincronizar la cache NoSQL: catalogo_cambio   */
/*    + disparadores que anotan el producto que cambio (stock,  */
/*    precio, reservas, estado de pedidos).                     */
/*==============================================================*/
SET DEFINE OFF
WHENEVER SQLERROR EXIT FAILURE
ALTER SESSION SET CURRENT_SCHEMA = simula;
CREATE OR REPLACE VIEW v_lote_raiz AS
WITH r (id_lote, id_lote_raiz, id_lote_origen) AS (
    SELECT id_lote, id_lote, id_lote_origen FROM lote
    UNION ALL
    SELECT r.id_lote, l.id_lote, l.id_lote_origen
    FROM r JOIN lote l ON l.id_lote = r.id_lote_origen
)
SELECT id_lote, id_lote_raiz FROM r WHERE id_lote_origen IS NULL
/

CREATE OR REPLACE VIEW v_lote_saldo AS
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
/

CREATE OR REPLACE VIEW v_pedido_estado_actual AS
SELECT id_pedido, id_estado_pedido, estado, desde
FROM (SELECT h.id_pedido,
             h.id_estado_pedido,
             e.esp_nombre    AS estado,
             h.hep_fechahora AS desde,
             ROW_NUMBER() OVER (PARTITION BY h.id_pedido
                                ORDER BY h.hep_fechahora DESC, h.id_historial_estado DESC) AS rn
      FROM historial_estado_pedido h
      JOIN estado_pedido e ON e.id_estado_pedido = h.id_estado_pedido)
WHERE rn = 1
/

CREATE OR REPLACE VIEW v_detalle_pedido_valor AS
WITH l AS (
    SELECT d.id_detalle_pedido, d.id_pedido, d.id_presentacion, d.dpe_cantidad, d.dpe_precio_unitario,
           d.dpe_descuento, d.id_tarifa_iva, d.id_oferta, d.id_usuario_descuento, d.id_descuento_volumen,
           pr.id_variante, pr.pre_factor, t.tiv_porcentaje, o.ofe_porcentaje, dv.dvo_porcentaje,
           d.dpe_cantidad * d.dpe_precio_unitario                                                  AS bruto,
           ROUND(d.dpe_cantidad * d.dpe_precio_unitario * NVL(o.ofe_porcentaje, 0) / 100, 2)       AS descuento_oferta
    FROM detalle_pedido d
    JOIN presentacion pr ON pr.id_presentacion = d.id_presentacion
    JOIN tarifa_iva   t  ON t.id_tarifa_iva    = d.id_tarifa_iva
    LEFT JOIN oferta  o  ON o.id_oferta        = d.id_oferta
    LEFT JOIN descuento_volumen dv ON dv.id_descuento_volumen = d.id_descuento_volumen
), v AS (
    SELECT l.*,
           CASE WHEN dpe_descuento = 0
                THEN ROUND((bruto - descuento_oferta) * NVL(dvo_porcentaje, 0) / 100, 2)
                ELSE 0 END                                                                          AS descuento_volumen
    FROM l
)
SELECT id_detalle_pedido,
       id_pedido,
       id_presentacion,
       id_variante,
       dpe_cantidad,
       pre_factor,
       CAST(dpe_cantidad * pre_factor AS NUMBER(14,3))                  AS cantidad_base,
       dpe_precio_unitario,
       id_oferta,
       ofe_porcentaje                                                   AS pct_oferta,
       descuento_oferta,
       dpe_descuento,
       descuento_oferta + dpe_descuento + descuento_volumen             AS descuento_total,
       id_tarifa_iva,
       tiv_porcentaje,
       ROUND(bruto - descuento_oferta - dpe_descuento - descuento_volumen, 2) AS base_imponible,
       ROUND((bruto - descuento_oferta - dpe_descuento - descuento_volumen) * tiv_porcentaje / 100, 2) AS iva,
       ROUND(bruto, 2)                                                  AS valor_lista,
       CASE WHEN bruto > 0
            THEN ROUND((descuento_oferta + dpe_descuento + descuento_volumen) * 100 / bruto, 2)
            ELSE 0 END                                                  AS pct_descuento,
       id_usuario_descuento,
       id_descuento_volumen,
       CASE WHEN dpe_descuento = 0 THEN dvo_porcentaje END              AS pct_volumen,
       descuento_volumen
FROM v
/

CREATE OR REPLACE VIEW v_orden_compra_detalle AS
SELECT d.id_detalle_orden_compra,
       d.id_orden_compra,
       d.id_variante,
       v.var_sku,
       d.dco_cantidad                                    AS cantidad_pedida,
       d.dco_costo_unitario                              AS costo_pactado,
       NVL(r.recibido, 0)                                AS cantidad_recibida,
       GREATEST(d.dco_cantidad - NVL(r.recibido, 0), 0)  AS cantidad_pendiente
FROM detalle_orden_compra d
JOIN variante v ON v.id_variante = d.id_variante
LEFT JOIN (
    SELECT id_detalle_orden_compra, SUM(dmo_cantidad) AS recibido
    FROM detalle_movimiento
    WHERE id_detalle_orden_compra IS NOT NULL
    GROUP BY id_detalle_orden_compra
) r ON r.id_detalle_orden_compra = d.id_detalle_orden_compra
/

CREATE OR REPLACE VIEW v_stock_variante_anterior AS
WITH saldos AS (
    SELECT id_variante,
           SUM(saldo)                                                    AS stock_fisico,
           SUM(saldo * lot_costo_unitario)                               AS valor_inventario,
           SUM(CASE WHEN saldo > 0 THEN saldo * dias_en_inventario END)
               / NULLIF(SUM(CASE WHEN saldo > 0 THEN saldo END), 0)      AS antiguedad_promedio_dias,
           MAX(CASE WHEN saldo > 0 THEN dias_en_inventario END)          AS antiguedad_maxima_dias,
           MAX(ultimo_movimiento)                                        AS ultimo_movimiento
    FROM v_lote_saldo
    GROUP BY id_variante
), reservas AS (
    SELECT dv.id_variante, SUM(dv.cantidad_base) AS reservado
    FROM v_detalle_pedido_valor dv
    JOIN v_pedido_estado_actual ea ON ea.id_pedido = dv.id_pedido
    WHERE ea.id_estado_pedido IN ('PEN', 'PAG')
    GROUP BY dv.id_variante
), en_camino AS (
    SELECT d.id_variante, SUM(d.cantidad_pendiente) AS en_camino
    FROM v_orden_compra_detalle d
    JOIN orden_compra oc ON oc.id_orden_compra = d.id_orden_compra
    WHERE oc.oc_estado = 'EMITIDA'
    GROUP BY d.id_variante
)
SELECT v.id_variante,
       v.var_sku,
       p.prd_nombre,
       p.id_unidad_medida                                    AS unidad,
       NVL(s.stock_fisico, 0)                                AS stock_fisico,
       NVL(r.reservado, 0)                                   AS reservado,
       NVL(s.stock_fisico, 0) - NVL(r.reservado, 0)          AS disponible,
       NVL(c.en_camino, 0)                                   AS en_camino,
       v.var_stock_minimo                                    AS stock_minimo,
       CASE WHEN NVL(s.stock_fisico, 0) - NVL(r.reservado, 0) + NVL(c.en_camino, 0) <= v.var_stock_minimo
            THEN 1 ELSE 0 END                                AS requiere_compra,
       ROUND(NVL(s.valor_inventario, 0), 2)                  AS valor_inventario,
       ROUND(s.antiguedad_promedio_dias, 1)                  AS antiguedad_promedio_dias,
       s.antiguedad_maxima_dias,
       s.ultimo_movimiento
FROM variante v
JOIN producto p ON p.id_producto = v.id_producto
LEFT JOIN saldos    s ON s.id_variante = v.id_variante
LEFT JOIN reservas  r ON r.id_variante = v.id_variante
LEFT JOIN en_camino c ON c.id_variante = v.id_variante;
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

-- OUTBOX: que producto cambio (la cache se reconstruye solo para esos)
CREATE TABLE catalogo_cambio (
    id_cambio   NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_producto NUMBER NOT NULL,
    creado      TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL
);

-- Kardex (el de mas volumen): trigger COMPUESTO, una fila de outbox por producto y por sentencia
CREATE OR REPLACE TRIGGER tr_outbox_movimiento
FOR INSERT ON detalle_movimiento
COMPOUND TRIGGER
    TYPE t_ids IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    lotes t_ids;
    AFTER EACH ROW IS
    BEGIN
        lotes(lotes.COUNT + 1) := :NEW.id_lote;
    END AFTER EACH ROW;
    AFTER STATEMENT IS
    BEGIN
        FORALL i IN 1 .. lotes.COUNT
            INSERT INTO catalogo_cambio (id_producto)
            SELECT v.id_producto FROM lote l JOIN variante v ON v.id_variante = l.id_variante WHERE l.id_lote = lotes(i);
    END AFTER STATEMENT;
END;
/
CREATE OR REPLACE TRIGGER tr_outbox_precio AFTER INSERT ON historial_precio FOR EACH ROW
BEGIN
    INSERT INTO catalogo_cambio (id_producto)
    SELECT v.id_producto FROM presentacion pr JOIN variante v ON v.id_variante = pr.id_variante WHERE pr.id_presentacion = :NEW.id_presentacion;
END;
/
CREATE OR REPLACE TRIGGER tr_outbox_reserva AFTER INSERT ON detalle_pedido FOR EACH ROW
BEGIN
    INSERT INTO catalogo_cambio (id_producto)
    SELECT v.id_producto FROM presentacion pr JOIN variante v ON v.id_variante = pr.id_variante WHERE pr.id_presentacion = :NEW.id_presentacion;
END;
/
-- un cambio de estado (pagado, cancelado) libera o confirma reservas: todos los productos del pedido
CREATE OR REPLACE TRIGGER tr_outbox_estado AFTER INSERT ON historial_estado_pedido FOR EACH ROW
BEGIN
    INSERT INTO catalogo_cambio (id_producto)
    SELECT DISTINCT v.id_producto FROM detalle_pedido d JOIN presentacion pr ON pr.id_presentacion = d.id_presentacion
    JOIN variante v ON v.id_variante = pr.id_variante WHERE d.id_pedido = :NEW.id_pedido;
END;
/
SELECT object_name || ' ' || status FROM all_objects WHERE owner = 'SIMULA' AND object_type IN ('VIEW', 'TRIGGER') ORDER BY 1;
EXIT
