/*==============================================================*/
/* Q8b: la vista REESCRITA para calcular solo las variantes pedidas  */
/* (subconsultas correlacionadas por variante; el estado actual se   */
/* busca por el indice de historial). Antes, Q8: la MISMA estructura que produccion.v_stock_variante      */
/* (bloques WITH agrupados por variante + LEFT JOIN, reservas   */
/* de pedidos PEN/PAG segun su estado actual, en camino de OC)  */
/* filtrada por el codigo de un producto. Uso: @04 <fase>       */
/*==============================================================*/
SET SERVEROUTPUT ON SIZE UNLIMITED FEEDBACK OFF
ALTER SESSION SET CURRENT_SCHEMA = bench;
DECLARE
    fase CONSTANT VARCHAR2(5) := '&1';
    N    CONSTANT PLS_INTEGER := 30;
    c    SYS_REFCURSOR;
    x    NUMBER;
    t0   NUMBER;
    l0   NUMBER;
    filas NUMBER := 0;
    sql_q CONSTANT VARCHAR2(4000) := q'[
        SELECT (SELECT NVL(SUM(dm.dmo_cantidad * m.signo), 0) FROM lote l JOIN detalle_movimiento dm ON dm.id_lote = l.id_lote
                JOIN movimiento_inventario m ON m.id_movimiento = dm.id_movimiento WHERE l.id_variante = v.id_variante)
             - (SELECT NVL(SUM(d.dpe_cantidad * p2.pre_factor), 0) FROM detalle_pedido d JOIN presentacion p2 ON p2.id_presentacion = d.id_presentacion
                WHERE p2.id_variante = v.id_variante
                  AND (SELECT MAX(h.id_estado_pedido) KEEP (DENSE_RANK LAST ORDER BY h.hep_fechahora)
                       FROM historial_estado_pedido h WHERE h.id_pedido = d.id_pedido) IN ('PEN', 'PAG'))
             + (SELECT NVL(SUM(o.dco_cantidad - o.recibido), 0) FROM detalle_orden_compra o WHERE o.id_variante = v.id_variante)
        FROM variante v JOIN producto p ON p.id_producto = v.id_producto
        WHERE p.prd_codigo = :c]';
    FUNCTION lecturas RETURN NUMBER IS
        r NUMBER;
    BEGIN
        SELECT s.value INTO r FROM v$mystat s JOIN v$statname n ON n.statistic# = s.statistic# WHERE n.name = 'session logical reads';
        RETURN r;
    END;
BEGIN
    DBMS_RANDOM.SEED(11);
    OPEN c FOR sql_q USING 'CE-10001';
    LOOP FETCH c INTO x; EXIT WHEN c%NOTFOUND; END LOOP;
    CLOSE c;
    t0 := DBMS_UTILITY.GET_TIME;
    l0 := lecturas;
    FOR i IN 1 .. N LOOP
        OPEN c FOR sql_q USING 'CE-' || (10000 + TRUNC(DBMS_RANDOM.VALUE(1, 5001)));
        LOOP FETCH c INTO x; EXIT WHEN c%NOTFOUND; filas := filas + 1; END LOOP;
        CLOSE c;
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('MEDIDA|' || fase || '|Q8b Stock con la vista reescrita|'
        || TO_CHAR((DBMS_UTILITY.GET_TIME - t0) * 10 / N, 'FM99990.00') || '|' || ROUND((lecturas - l0) / N) || '|' || ROUND(filas / N, 1));
END;
/
EXIT
