/*==============================================================*/
/* Q8: la MISMA estructura que produccion.v_stock_variante      */
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
        WITH saldos AS (
            SELECT l.id_variante, SUM(dm.dmo_cantidad * m.signo) AS stock
            FROM lote l JOIN detalle_movimiento dm ON dm.id_lote = l.id_lote
            JOIN movimiento_inventario m ON m.id_movimiento = dm.id_movimiento
            GROUP BY l.id_variante
        ), estado AS (
            SELECT id_pedido, MAX(id_estado_pedido) KEEP (DENSE_RANK LAST ORDER BY hep_fechahora) AS estado
            FROM historial_estado_pedido GROUP BY id_pedido
        ), reservas AS (
            SELECT p2.id_variante, SUM(d.dpe_cantidad * p2.pre_factor) AS reservado
            FROM detalle_pedido d JOIN presentacion p2 ON p2.id_presentacion = d.id_presentacion
            JOIN estado e ON e.id_pedido = d.id_pedido
            WHERE e.estado IN ('PEN', 'PAG')
            GROUP BY p2.id_variante
        ), en_camino AS (
            SELECT id_variante, SUM(dco_cantidad - recibido) AS en_camino FROM detalle_orden_compra GROUP BY id_variante
        )
        SELECT NVL(s.stock, 0) - NVL(r.reservado, 0) + NVL(c.en_camino, 0)
        FROM variante v JOIN producto p ON p.id_producto = v.id_producto
        LEFT JOIN saldos s ON s.id_variante = v.id_variante
        LEFT JOIN reservas r ON r.id_variante = v.id_variante
        LEFT JOIN en_camino c ON c.id_variante = v.id_variante
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
    DBMS_OUTPUT.PUT_LINE('MEDIDA|' || fase || '|Q8 Stock con la estructura de la vista real|'
        || TO_CHAR((DBMS_UTILITY.GET_TIME - t0) * 10 / N, 'FM99990.00') || '|' || ROUND((lecturas - l0) / N) || '|' || ROUND(filas / N, 1));
END;
/
EXIT
