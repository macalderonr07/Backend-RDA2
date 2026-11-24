/*==============================================================*/
/* Indices candidatos (los que faltan en produccion). En BENCH  */
/* se crean para medir; mide tambien su tamano y lo que cuestan */
/* al escribir (insertar 20.000 lineas de pedido).              */
/*==============================================================*/
SET SERVEROUTPUT ON FEEDBACK OFF
ALTER SESSION SET CURRENT_SCHEMA = bench;

-- costo de escritura ANTES (sin los indices nuevos): insertar 20.000 lineas y deshacer
DECLARE
    t0 NUMBER := DBMS_UTILITY.GET_TIME;
BEGIN
    INSERT INTO detalle_pedido SELECT 1000000 + LEVEL, 200000 + LEVEL, 1 + MOD(LEVEL * 31, 40000), 1 FROM dual CONNECT BY LEVEL <= 20000;
    DBMS_OUTPUT.PUT_LINE('ESCRITURA|sin|20000 lineas de pedido|' || (DBMS_UTILITY.GET_TIME - t0) * 10);
    ROLLBACK;
END;
/

-- reservado por variante (stock)
CREATE INDEX ix_detped_presentacion ON detalle_pedido (id_presentacion);
-- en camino por variante (stock)
CREATE INDEX ix_doc_variante ON detalle_orden_compra (id_variante);
-- cliente por cedula/RUC
CREATE INDEX ix_df_identificacion ON datos_facturacion (dfa_identificacion);
-- cliente por telefono
CREATE INDEX ix_telefono_numero ON telefono (tel_numero);
-- filtro por color/talla
CREATE INDEX ix_varval_valor ON variante_valor (id_valor_atributo);
-- busqueda por inicio del nombre
CREATE INDEX ix_producto_nombre_up ON producto (UPPER(prd_nombre));
BEGIN DBMS_STATS.GATHER_SCHEMA_STATS('BENCH'); END;
/

DECLARE
    t0 NUMBER := DBMS_UTILITY.GET_TIME;
BEGIN
    INSERT INTO detalle_pedido SELECT 1000000 + LEVEL, 200000 + LEVEL, 1 + MOD(LEVEL * 31, 40000), 1 FROM dual CONNECT BY LEVEL <= 20000;
    DBMS_OUTPUT.PUT_LINE('ESCRITURA|con|20000 lineas de pedido|' || (DBMS_UTILITY.GET_TIME - t0) * 10);
    ROLLBACK;
END;
/
SELECT 'TAMANO|' || segment_name || '|' || ROUND(bytes / 1024) FROM dba_segments
WHERE owner = 'BENCH' AND segment_name IN ('IX_DETPED_PRESENTACION','IX_DOC_VARIANTE','IX_DF_IDENTIFICACION','IX_TELEFONO_NUMERO','IX_VARVAL_VALOR','IX_PRODUCTO_NOMBRE_UP')
UNION ALL
SELECT 'TAMANO_TABLAS|total|' || ROUND(SUM(bytes) / 1024) FROM dba_segments WHERE owner = 'BENCH' AND segment_type = 'TABLE';
EXIT
