/*==============================================================*/
/* Banco de pruebas de rendimiento (NO toca produccion).        */
/* Crea el esquema BENCH con las tablas del catalogo, el stock  */
/* y los clientes, con la MISMA estructura de columnas e        */
/* indices que produccion, y un volumen de crecimiento:         */
/*   5.000 productos, 20.000 variantes, 40.000 presentaciones,  */
/*   120.000 precios, 60.000 lotes, 200.000 movimientos,        */
/*   20.000 clientes, 100.000 pedidos, 300.000 lineas,          */
/*   30.000 lineas de orden de compra.                          */
/* Se borra con 99_borrar_bench.sql.                            */
/*==============================================================*/
SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT FAILURE
BEGIN EXECUTE IMMEDIATE 'DROP USER bench CASCADE'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
-- cuenta solo-esquema: nadie puede ingresar con ella (no tiene clave)
CREATE USER bench NO AUTHENTICATION QUOTA UNLIMITED ON users DEFAULT TABLESPACE users;
ALTER SESSION SET CURRENT_SCHEMA = bench;

CREATE TABLE categoria (id_categoria NUMBER PRIMARY KEY, cat_nombre VARCHAR2(80), id_categoria_padre NUMBER);
CREATE TABLE producto (id_producto NUMBER PRIMARY KEY, id_categoria NUMBER NOT NULL, prd_codigo VARCHAR2(80) NOT NULL,
                       prd_nombre VARCHAR2(150) NOT NULL, prd_publicado NUMBER(1) DEFAULT 1, id_marca NUMBER);
CREATE TABLE variante (id_variante NUMBER PRIMARY KEY, id_producto NUMBER NOT NULL, var_sku VARCHAR2(80) NOT NULL, var_activa NUMBER(1) DEFAULT 1);
CREATE TABLE variante_valor (id_variante NUMBER, id_atributo NUMBER, id_valor_atributo NUMBER, PRIMARY KEY (id_variante, id_atributo));
CREATE TABLE presentacion (id_presentacion NUMBER PRIMARY KEY, id_variante NUMBER NOT NULL, pre_descripcion VARCHAR2(40), pre_factor NUMBER);
CREATE TABLE historial_precio (id_historial NUMBER PRIMARY KEY, id_presentacion NUMBER NOT NULL, hpr_precio NUMBER(12,2), hpr_vigente_desde TIMESTAMP);
CREATE TABLE lote (id_lote NUMBER PRIMARY KEY, id_variante NUMBER NOT NULL, lot_costo_unitario NUMBER(12,4));
CREATE TABLE movimiento_inventario (id_movimiento NUMBER PRIMARY KEY, id_tipo_movimiento VARCHAR2(3), signo NUMBER(1));
CREATE TABLE detalle_movimiento (id_detalle NUMBER PRIMARY KEY, id_movimiento NUMBER NOT NULL, id_lote NUMBER NOT NULL, dmo_cantidad NUMBER);
CREATE TABLE cliente (id_cliente NUMBER PRIMARY KEY, cli_nombres VARCHAR2(100), cli_apellidos VARCHAR2(100), cli_correo VARCHAR2(120));
CREATE TABLE datos_facturacion (id_datos_facturacion NUMBER PRIMARY KEY, id_cliente NUMBER NOT NULL, id_tipo_identificacion CHAR(2), dfa_identificacion VARCHAR2(20), dfa_razon_social VARCHAR2(150));
CREATE TABLE telefono (id_telefono NUMBER PRIMARY KEY, id_cliente NUMBER NOT NULL, tel_numero VARCHAR2(15));
CREATE TABLE pedido (id_pedido NUMBER PRIMARY KEY, id_cliente NUMBER NOT NULL, id_canal_venta VARCHAR2(3), ped_fechahora TIMESTAMP);
CREATE TABLE historial_estado_pedido (id_historial NUMBER PRIMARY KEY, id_pedido NUMBER NOT NULL, id_estado_pedido VARCHAR2(3), hep_fechahora TIMESTAMP);
CREATE TABLE detalle_pedido (id_detalle_pedido NUMBER PRIMARY KEY, id_pedido NUMBER NOT NULL, id_presentacion NUMBER NOT NULL, dpe_cantidad NUMBER);
CREATE TABLE detalle_orden_compra (id_detalle NUMBER PRIMARY KEY, id_orden_compra NUMBER, id_variante NUMBER NOT NULL, dco_cantidad NUMBER, recibido NUMBER);

-- Datos (aleatorios pero reproducibles)
EXEC DBMS_RANDOM.SEED(2026);
INSERT INTO categoria SELECT LEVEL, 'Categoria ' || LEVEL, CASE WHEN LEVEL > 10 THEN MOD(LEVEL, 10) + 1 END FROM dual CONNECT BY LEVEL <= 40;
INSERT INTO producto SELECT LEVEL, 11 + MOD(LEVEL, 30), 'CE-' || (10000 + LEVEL),
       INITCAP(DBMS_RANDOM.STRING('l', 6)) || ' ' || CASE MOD(LEVEL, 6) WHEN 0 THEN 'suela' WHEN 1 THEN 'cuero' WHEN 2 THEN 'hebilla' WHEN 3 THEN 'hilo' WHEN 4 THEN 'pega' ELSE 'cierre' END || ' ' || LEVEL,
       1, MOD(LEVEL, 12) + 1 FROM dual CONNECT BY LEVEL <= 5000;
INSERT INTO variante SELECT LEVEL, CEIL(LEVEL / 4), 'CE-' || (10000 + CEIL(LEVEL / 4)) || '-' || MOD(LEVEL, 4), 1 FROM dual CONNECT BY LEVEL <= 20000;
INSERT INTO variante_valor SELECT id_variante, 1, 1 + MOD(id_variante, 8) FROM variante;
INSERT INTO presentacion SELECT LEVEL, CEIL(LEVEL / 2), CASE MOD(LEVEL, 2) WHEN 0 THEN 'Unidad' ELSE 'Docena' END, CASE MOD(LEVEL, 2) WHEN 0 THEN 1 ELSE 12 END FROM dual CONNECT BY LEVEL <= 40000;
INSERT INTO historial_precio SELECT LEVEL, CEIL(LEVEL / 3), ROUND(DBMS_RANDOM.VALUE(1, 60), 2), SYSTIMESTAMP - NUMTODSINTERVAL(MOD(LEVEL, 3) * 90, 'DAY') FROM dual CONNECT BY LEVEL <= 120000;
INSERT INTO lote SELECT LEVEL, CEIL(LEVEL / 3), ROUND(DBMS_RANDOM.VALUE(0.5, 30), 4) FROM dual CONNECT BY LEVEL <= 60000;
INSERT INTO movimiento_inventario SELECT LEVEL, CASE WHEN MOD(LEVEL, 3) = 0 THEN 'VEN' ELSE 'REC' END, CASE WHEN MOD(LEVEL, 3) = 0 THEN -1 ELSE 1 END FROM dual CONNECT BY LEVEL <= 70000;
INSERT INTO detalle_movimiento SELECT LEVEL, 1 + MOD(LEVEL * 7, 70000), 1 + MOD(LEVEL, 60000), ROUND(DBMS_RANDOM.VALUE(1, 40)) FROM dual CONNECT BY LEVEL <= 200000;
INSERT INTO cliente SELECT LEVEL, INITCAP(DBMS_RANDOM.STRING('l', 7)), INITCAP(DBMS_RANDOM.STRING('l', 8)), 'cliente' || LEVEL || '@correo.ec' FROM dual CONNECT BY LEVEL <= 20000;
INSERT INTO datos_facturacion SELECT LEVEL, LEVEL, '05', TO_CHAR(1700000000 + LEVEL * 37), 'RAZON ' || LEVEL FROM dual CONNECT BY LEVEL <= 20000;
INSERT INTO telefono SELECT LEVEL, LEVEL, '09' || LPAD(TO_CHAR(10000000 + LEVEL * 13), 8, '0') FROM dual CONNECT BY LEVEL <= 20000;
INSERT INTO pedido SELECT LEVEL, 1 + MOD(LEVEL * 11, 20000), CASE MOD(LEVEL, 3) WHEN 0 THEN 'WEB' WHEN 1 THEN 'TDA' ELSE 'WSP' END, SYSTIMESTAMP - NUMTODSINTERVAL(MOD(LEVEL, 700), 'DAY') FROM dual CONNECT BY LEVEL <= 100000;
INSERT INTO historial_estado_pedido SELECT LEVEL, CEIL(LEVEL / 2.5), CASE MOD(LEVEL, 5) WHEN 0 THEN 'PEN' WHEN 1 THEN 'PAG' WHEN 2 THEN 'FAC' WHEN 3 THEN 'ENT' ELSE 'CAN' END, SYSTIMESTAMP - NUMTODSINTERVAL(MOD(LEVEL, 700), 'DAY') FROM dual CONNECT BY LEVEL <= 250000;
INSERT INTO detalle_pedido SELECT LEVEL, CEIL(LEVEL / 3), 1 + MOD(LEVEL * 17, 40000), ROUND(DBMS_RANDOM.VALUE(1, 10)) FROM dual CONNECT BY LEVEL <= 300000;
INSERT INTO detalle_orden_compra SELECT LEVEL, CEIL(LEVEL / 5), 1 + MOD(LEVEL * 7, 20000), ROUND(DBMS_RANDOM.VALUE(10, 200)), 0 FROM dual CONNECT BY LEVEL <= 30000;
COMMIT;

-- Indices QUE YA EXISTEN en produccion (mismas columnas)
CREATE UNIQUE INDEX ak_producto_codigo ON producto (prd_codigo);
CREATE INDEX ix_producto_categoria ON producto (id_categoria);
CREATE INDEX ix_producto_marca ON producto (id_marca);
CREATE UNIQUE INDEX ak_variante_sku ON variante (var_sku);
CREATE INDEX ix_variante_producto ON variante (id_producto);
CREATE INDEX ix_presentacion_variante ON presentacion (id_variante);
CREATE UNIQUE INDEX ak_historial_precio ON historial_precio (id_presentacion, hpr_vigente_desde);
CREATE INDEX ix_lote_variante ON lote (id_variante);
CREATE INDEX ix_detmov_lote ON detalle_movimiento (id_lote);
CREATE INDEX ix_detmov_movimiento ON detalle_movimiento (id_movimiento);
CREATE INDEX ix_df_cliente ON datos_facturacion (id_cliente);
CREATE UNIQUE INDEX ak_telefono ON telefono (id_cliente, tel_numero);
CREATE INDEX ix_pedido_cliente ON pedido (id_cliente, ped_fechahora);
CREATE INDEX ix_hep_pedido ON historial_estado_pedido (id_pedido, hep_fechahora);
CREATE UNIQUE INDEX ak_detalle_pedido ON detalle_pedido (id_pedido, id_presentacion);

BEGIN DBMS_STATS.GATHER_SCHEMA_STATS('BENCH'); END;
/
SELECT 'bench listo: ' || (SELECT COUNT(*) FROM producto) || ' productos, ' || (SELECT COUNT(*) FROM detalle_movimiento) || ' movimientos, '
       || (SELECT COUNT(*) FROM detalle_pedido) || ' lineas de pedido' AS estado FROM dual;
EXIT
