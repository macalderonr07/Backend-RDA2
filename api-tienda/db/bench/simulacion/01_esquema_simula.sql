/*==============================================================*/
/* Simulacion a escala (NO toca produccion).                    */
/* Esquema SIMULA con las tablas COPIADAS de produccion (mismas */
/* columnas) y las vistas REALES (la de stock anterior y la     */
/* optimizada de la migracion 16), con 10 veces el volumen de   */
/* la primera medicion:                                         */
/*   50.000 productos, 150.000 variantes, 300.000 presentaciones*/
/*   450.000 precios, 300.000 lotes, 900.000 movimientos,       */
/*   200.000 pedidos, 500.000 cambios de estado, 600.000 lineas */
/*   de pedido, 60.000 lineas de orden de compra.               */
/* Uso (sysdba, en FREEPDB1): @01_esquema_simula.sql <clave>    */
/* La clave se pasa al correr (no queda en el repositorio).     */
/*==============================================================*/
SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT FAILURE
BEGIN EXECUTE IMMEDIATE 'DROP USER simula CASCADE'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
CREATE USER simula IDENTIFIED BY "&1" QUOTA UNLIMITED ON users DEFAULT TABLESPACE users;
GRANT CREATE SESSION, CREATE TABLE, CREATE VIEW, CREATE TRIGGER, CREATE SEQUENCE TO simula;
ALTER SESSION SET CURRENT_SCHEMA = simula;

-- Tablas con las MISMAS columnas que produccion (sin datos ni restricciones de negocio)
BEGIN
    FOR t IN (SELECT column_value AS nombre FROM TABLE(SYS.ODCIVARCHAR2LIST(
                  'CATEGORIA', 'PRODUCTO', 'VARIANTE', 'PRESENTACION', 'HISTORIAL_PRECIO', 'LOTE', 'MOVIMIENTO_INVENTARIO',
                  'DETALLE_MOVIMIENTO', 'PEDIDO', 'HISTORIAL_ESTADO_PEDIDO', 'DETALLE_PEDIDO', 'ORDEN_COMPRA',
                  'DETALLE_ORDEN_COMPRA', 'OFERTA', 'DESCUENTO_VOLUMEN'))) LOOP
        EXECUTE IMMEDIATE 'CREATE TABLE simula.' || t.nombre || ' AS SELECT * FROM produccion.' || t.nombre || ' WHERE 1 = 0';
    END LOOP;
    -- catalogos chicos: con sus datos
    FOR t IN (SELECT column_value AS nombre FROM TABLE(SYS.ODCIVARCHAR2LIST('TIPO_MOVIMIENTO', 'ESTADO_PEDIDO', 'TARIFA_IVA'))) LOOP
        EXECUTE IMMEDIATE 'CREATE TABLE simula.' || t.nombre || ' AS SELECT * FROM produccion.' || t.nombre;
    END LOOP;
END;
/

EXEC DBMS_RANDOM.SEED(2026);
INSERT INTO categoria (id_categoria, id_categoria_padre, cat_codigo, cat_nombre, cat_activa)
SELECT LEVEL, CASE WHEN LEVEL > 10 THEN MOD(LEVEL, 10) + 1 END, 'cat-' || LEVEL, 'Categoria ' || LEVEL, 1 FROM dual CONNECT BY LEVEL <= 60;
INSERT INTO producto (id_producto, id_categoria, id_unidad_medida, id_tarifa_iva, prd_codigo, prd_nombre, prd_publicado, prd_venta_por_pieza,
                      prd_fecha_creacion, prd_cortes_estandar, prd_precio_por_variante)
SELECT LEVEL, 11 + MOD(LEVEL, 50), 'u', '4', 'CE-' || (100000 + LEVEL), 'Producto ' || DBMS_RANDOM.STRING('l', 6) || ' ' || LEVEL, 1, 0,
       SYSTIMESTAMP - NUMTODSINTERVAL(MOD(LEVEL, 900), 'DAY'), 0, 0 FROM dual CONNECT BY LEVEL <= 50000;
INSERT INTO variante (id_variante, id_producto, var_sku, var_stock_minimo, var_activa)
SELECT LEVEL, CEIL(LEVEL / 3), 'CE-' || (100000 + CEIL(LEVEL / 3)) || '-' || MOD(LEVEL, 3), 5, 1 FROM dual CONNECT BY LEVEL <= 150000;
INSERT INTO presentacion (id_presentacion, id_variante, pre_descripcion, pre_factor, pre_cantidad_minima, pre_activa, pre_incremento)
SELECT LEVEL, CEIL(LEVEL / 2), CASE MOD(LEVEL, 2) WHEN 0 THEN 'Unidad' ELSE 'Docena' END, CASE MOD(LEVEL, 2) WHEN 0 THEN 1 ELSE 12 END, 1, 1, 1
FROM dual CONNECT BY LEVEL <= 300000;
INSERT INTO historial_precio (id_historial_precio, id_presentacion, hpr_precio, hpr_vigente_desde, id_usuario)
SELECT LEVEL, CEIL(LEVEL / 1.5), ROUND(DBMS_RANDOM.VALUE(1, 60), 2), SYSTIMESTAMP - NUMTODSINTERVAL(MOD(LEVEL, 3) * 120 + 1, 'DAY'), 1
FROM dual CONNECT BY LEVEL <= 450000;
-- 300.000 lotes: 1 de cada 10 es un corte de otro (id_lote_origen), como el cuero y la fibra
INSERT INTO lote (id_lote, id_variante, lot_costo_unitario, id_lote_origen)
SELECT LEVEL, CEIL(LEVEL / 2), ROUND(DBMS_RANDOM.VALUE(0.5, 30), 4), CASE WHEN MOD(LEVEL, 10) = 0 THEN LEVEL - 1 END FROM dual CONNECT BY LEVEL <= 300000;
-- movimientos 1..300.000: compra (COM, +) uno por lote; 300.001..600.000: ventas (VEN, -)
INSERT INTO movimiento_inventario (id_movimiento, id_tipo_movimiento, mov_fechahora, id_usuario)
SELECT LEVEL, CASE WHEN LEVEL <= 300000 THEN 'COM' ELSE 'VEN' END, SYSTIMESTAMP - NUMTODSINTERVAL(MOD(LEVEL, 700), 'DAY'), 1
FROM dual CONNECT BY LEVEL <= 600000;
-- kardex: cada lote entra con 40-200 (900.000 lineas en total) y luego salen ventas de 1 a 10
INSERT INTO detalle_movimiento (id_detalle_movimiento, id_movimiento, id_lote, dmo_cantidad)
SELECT LEVEL,
       CASE WHEN LEVEL <= 300000 THEN LEVEL ELSE 300000 + 1 + MOD(LEVEL, 300000) END,
       CASE WHEN LEVEL <= 300000 THEN LEVEL ELSE 1 + MOD(LEVEL * 13, 300000) END,
       CASE WHEN LEVEL <= 300000 THEN ROUND(DBMS_RANDOM.VALUE(40, 200)) ELSE ROUND(DBMS_RANDOM.VALUE(1, 10)) END
FROM dual CONNECT BY LEVEL <= 900000;
INSERT INTO pedido (id_pedido, id_cliente, id_canal_venta, ped_fechahora)
SELECT LEVEL, 1 + MOD(LEVEL * 11, 20000), CASE MOD(LEVEL, 3) WHEN 0 THEN 'WEB' WHEN 1 THEN 'TDA' ELSE 'WSP' END, SYSTIMESTAMP - NUMTODSINTERVAL(MOD(LEVEL, 700), 'DAY')
FROM dual CONNECT BY LEVEL <= 200000;
INSERT INTO historial_estado_pedido (id_historial_estado, id_pedido, id_estado_pedido, hep_fechahora)
SELECT LEVEL, CEIL(LEVEL / 2.5), CASE MOD(LEVEL, 5) WHEN 0 THEN 'PEN' WHEN 1 THEN 'PAG' WHEN 2 THEN 'FAC' WHEN 3 THEN 'ENT' ELSE 'CAN' END,
       SYSTIMESTAMP - NUMTODSINTERVAL(MOD(LEVEL, 700), 'DAY') + NUMTODSINTERVAL(MOD(LEVEL, 3), 'MINUTE')
FROM dual CONNECT BY LEVEL <= 500000;
INSERT INTO detalle_pedido (id_detalle_pedido, id_pedido, id_presentacion, dpe_cantidad, dpe_precio_unitario, dpe_descuento, id_tarifa_iva)
SELECT LEVEL, CEIL(LEVEL / 3), 1 + MOD(LEVEL * 17, 300000), ROUND(DBMS_RANDOM.VALUE(1, 10)), ROUND(DBMS_RANDOM.VALUE(1, 60), 2), 0, '4'
FROM dual CONNECT BY LEVEL <= 600000;
INSERT INTO orden_compra (id_orden_compra, id_proveedor, id_usuario_crea, oc_fecha, oc_estado)
SELECT LEVEL, 1 + MOD(LEVEL, 50), 1, SYSDATE - MOD(LEVEL, 300), CASE MOD(LEVEL, 4) WHEN 0 THEN 'EMITIDA' WHEN 1 THEN 'CERRADA' ELSE 'BORRADOR' END
FROM dual CONNECT BY LEVEL <= 20000;
INSERT INTO detalle_orden_compra (id_detalle_orden_compra, id_orden_compra, id_variante, dco_cantidad, dco_costo_unitario)
SELECT LEVEL, CEIL(LEVEL / 3), 1 + MOD(LEVEL * 7, 150000), ROUND(DBMS_RANDOM.VALUE(10, 200)), ROUND(DBMS_RANDOM.VALUE(0.5, 30), 4)
FROM dual CONNECT BY LEVEL <= 60000;
COMMIT;

-- Claves primarias e indices IGUALES a produccion (los de la migracion 16 incluidos)
ALTER TABLE categoria ADD PRIMARY KEY (id_categoria);
ALTER TABLE producto ADD PRIMARY KEY (id_producto);
ALTER TABLE variante ADD PRIMARY KEY (id_variante);
ALTER TABLE presentacion ADD PRIMARY KEY (id_presentacion);
ALTER TABLE historial_precio ADD PRIMARY KEY (id_historial_precio);
ALTER TABLE lote ADD PRIMARY KEY (id_lote);
ALTER TABLE movimiento_inventario ADD PRIMARY KEY (id_movimiento);
ALTER TABLE detalle_movimiento ADD PRIMARY KEY (id_detalle_movimiento);
ALTER TABLE pedido ADD PRIMARY KEY (id_pedido);
ALTER TABLE historial_estado_pedido ADD PRIMARY KEY (id_historial_estado);
ALTER TABLE detalle_pedido ADD PRIMARY KEY (id_detalle_pedido);
ALTER TABLE orden_compra ADD PRIMARY KEY (id_orden_compra);
ALTER TABLE detalle_orden_compra ADD PRIMARY KEY (id_detalle_orden_compra);
ALTER TABLE tipo_movimiento ADD PRIMARY KEY (id_tipo_movimiento);
ALTER TABLE estado_pedido ADD PRIMARY KEY (id_estado_pedido);
ALTER TABLE tarifa_iva ADD PRIMARY KEY (id_tarifa_iva);
CREATE UNIQUE INDEX ak_producto_codigo ON producto (prd_codigo);
CREATE INDEX ix_producto_categoria ON producto (id_categoria);
CREATE INDEX ix_variante_producto ON variante (id_producto);
CREATE INDEX ix_presentacion_variante ON presentacion (id_variante);
CREATE UNIQUE INDEX ak_historial_precio ON historial_precio (id_presentacion, hpr_vigente_desde);
CREATE INDEX ix_lote_variante ON lote (id_variante);
CREATE INDEX ix_lote_origen ON lote (id_lote_origen);
CREATE INDEX ix_detmov_lote ON detalle_movimiento (id_lote);
CREATE INDEX ix_detmov_movimiento ON detalle_movimiento (id_movimiento);
CREATE INDEX ix_detmov_doc ON detalle_movimiento (id_detalle_orden_compra);
CREATE INDEX ix_hep_pedido ON historial_estado_pedido (id_pedido, hep_fechahora);
CREATE INDEX ix_detped_pedido ON detalle_pedido (id_pedido, id_presentacion);
CREATE INDEX ix_detped_presentacion ON detalle_pedido (id_presentacion);
CREATE INDEX ix_doc_variante ON detalle_orden_compra (id_variante);
BEGIN DBMS_STATS.GATHER_SCHEMA_STATS('SIMULA'); END;
/
SELECT 'simula: ' || (SELECT COUNT(*) FROM producto) || ' productos, ' || (SELECT COUNT(*) FROM detalle_movimiento) || ' movimientos, '
       || (SELECT COUNT(*) FROM detalle_pedido) || ' lineas de pedido' AS estado FROM dual;
EXIT
