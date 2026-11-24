/*==============================================================*/
/* Mide las consultas del catalogo y de clientes en BENCH.      */
/* Uso: @02_medir.sql <fase>   (fase = sin | con)               */
/* Cada consulta corre 50 veces con valores distintos (los      */
/* mismos en las dos fases) y se informa:                       */
/*   ms   = tiempo promedio por consulta                         */
/*   lect = lecturas logicas promedio (bloques que Oracle tuvo   */
/*          que leer; la medida estable del trabajo)            */
/*==============================================================*/
SET SERVEROUTPUT ON SIZE UNLIMITED FEEDBACK OFF
ALTER SESSION SET CURRENT_SCHEMA = bench;
DECLARE
    fase     CONSTANT VARCHAR2(5) := '&1';
    N        CONSTANT PLS_INTEGER := 50;
    c        SYS_REFCURSOR;
    v_n      NUMBER;
    v_t0     NUMBER;
    v_l0     NUMBER;
    FUNCTION lecturas RETURN NUMBER IS
        r NUMBER;
    BEGIN
        SELECT s.value INTO r FROM v$mystat s JOIN v$statname n ON n.statistic# = s.statistic#
        WHERE n.name = 'session logical reads';
        RETURN r;
    END;
    PROCEDURE medir(nombre IN VARCHAR2, sql_texto IN VARCHAR2, generar IN VARCHAR2) IS
        v_bind VARCHAR2(100);
        v_filas NUMBER := 0;
        x NUMBER;
    BEGIN
        DBMS_RANDOM.SEED(7);  -- mismos valores en las dos fases
        -- calentamiento: 3 corridas (el plan y la cache no cuentan en la medicion)
        FOR i IN 1 .. 3 LOOP
            EXECUTE IMMEDIATE 'SELECT ' || generar || ' FROM dual' INTO v_bind;
            OPEN c FOR sql_texto USING v_bind;
            LOOP FETCH c INTO x; EXIT WHEN c%NOTFOUND; END LOOP;
            CLOSE c;
        END LOOP;
        DBMS_RANDOM.SEED(11);
        v_t0 := DBMS_UTILITY.GET_TIME;
        v_l0 := lecturas;
        FOR i IN 1 .. N LOOP
            EXECUTE IMMEDIATE 'SELECT ' || generar || ' FROM dual' INTO v_bind;
            OPEN c FOR sql_texto USING v_bind;
            LOOP FETCH c INTO x; EXIT WHEN c%NOTFOUND; v_filas := v_filas + 1; END LOOP;
            CLOSE c;
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('MEDIDA|' || fase || '|' || nombre || '|'
            || TO_CHAR((DBMS_UTILITY.GET_TIME - v_t0) * 10 / N, 'FM99990.00') || '|'
            || ROUND((lecturas - v_l0) / N) || '|' || ROUND(v_filas / N, 1));
    END;
BEGIN
    -- Q1 ficha de producto por codigo: precio vigente + stock + reservado + en camino por presentacion
    medir('Q1 Ficha de producto (por código)', q'[
        SELECT (SELECT MAX(hp.hpr_precio) KEEP (DENSE_RANK LAST ORDER BY hp.hpr_vigente_desde) FROM historial_precio hp
                WHERE hp.id_presentacion = pr.id_presentacion AND hp.hpr_vigente_desde <= SYSTIMESTAMP)
             + (SELECT NVL(SUM(dm.dmo_cantidad * m.signo), 0) FROM lote l JOIN detalle_movimiento dm ON dm.id_lote = l.id_lote
                JOIN movimiento_inventario m ON m.id_movimiento = dm.id_movimiento WHERE l.id_variante = v.id_variante)
             - (SELECT NVL(SUM(d.dpe_cantidad * p2.pre_factor), 0) FROM detalle_pedido d JOIN presentacion p2 ON p2.id_presentacion = d.id_presentacion
                WHERE p2.id_variante = v.id_variante)
             + (SELECT NVL(SUM(o.dco_cantidad - o.recibido), 0) FROM detalle_orden_compra o WHERE o.id_variante = v.id_variante)
        FROM producto p JOIN variante v ON v.id_producto = p.id_producto JOIN presentacion pr ON pr.id_variante = v.id_variante
        WHERE p.prd_codigo = :c]', q'['CE-' || (10000 + TRUNC(DBMS_RANDOM.VALUE(1, 5001)))]');

    -- Q2 listado de una linea (primera pagina de 20 productos) con lo mismo
    medir('Q2 Listado por categoría (20 productos)', q'[
        SELECT (SELECT MAX(hp.hpr_precio) KEEP (DENSE_RANK LAST ORDER BY hp.hpr_vigente_desde) FROM historial_precio hp
                WHERE hp.id_presentacion = pr.id_presentacion AND hp.hpr_vigente_desde <= SYSTIMESTAMP)
             - (SELECT NVL(SUM(d.dpe_cantidad * p2.pre_factor), 0) FROM detalle_pedido d JOIN presentacion p2 ON p2.id_presentacion = d.id_presentacion
                WHERE p2.id_variante = v.id_variante)
             + (SELECT NVL(SUM(o.dco_cantidad - o.recibido), 0) FROM detalle_orden_compra o WHERE o.id_variante = v.id_variante)
        FROM (SELECT * FROM producto WHERE id_categoria = TO_NUMBER(:c) ORDER BY prd_codigo FETCH FIRST 20 ROWS ONLY) p
        JOIN variante v ON v.id_producto = p.id_producto JOIN presentacion pr ON pr.id_variante = v.id_variante]',
        q'[TO_CHAR(11 + TRUNC(DBMS_RANDOM.VALUE(0, 30)))]');

    -- Q3 busqueda por nombre (contiene): un indice B-tree no sirve para '%texto%'
    medir('Q3 Búsqueda por nombre (contiene)', q'[
        SELECT id_producto FROM producto WHERE INSTR(LOWER(prd_nombre), LOWER(:q)) > 0 FETCH FIRST 30 ROWS ONLY]',
        q'['suela ' || TRUNC(DBMS_RANDOM.VALUE(1, 500))]');

    -- Q3b busqueda por el comienzo del nombre (autocompletar): aqui SI sirve un indice
    medir('Q3b Búsqueda por inicio del nombre', q'[
        SELECT id_producto FROM producto WHERE UPPER(prd_nombre) LIKE UPPER(:q) || '%' FETCH FIRST 30 ROWS ONLY]',
        q'[(SELECT SUBSTR(prd_nombre, 1, 4) FROM producto WHERE id_producto = TRUNC(DBMS_RANDOM.VALUE(1, 5001)))]');

    -- Q4 cliente por cedula/RUC exacta (venta de mostrador)
    medir('Q4 Cliente por cédula exacta', q'[
        SELECT id_cliente FROM datos_facturacion WHERE dfa_identificacion = :x]',
        q'[TO_CHAR(1700000000 + TRUNC(DBMS_RANDOM.VALUE(1, 20001)) * 37)]');

    -- Q5 cliente por telefono exacto
    medir('Q5 Cliente por teléfono exacto', q'[
        SELECT id_cliente FROM telefono WHERE tel_numero = :t]',
        q'['09' || LPAD(TO_CHAR(10000000 + TRUNC(DBMS_RANDOM.VALUE(1, 20001)) * 13), 8, '0')]');

    -- Q6 pedidos de un cliente con su estado actual (ya indexado: control)
    medir('Q6 Pedidos de un cliente (control)', q'[
        SELECT LENGTH((SELECT MAX(h.id_estado_pedido) KEEP (DENSE_RANK LAST ORDER BY h.hep_fechahora) FROM historial_estado_pedido h WHERE h.id_pedido = p.id_pedido))
        FROM pedido p WHERE p.id_cliente = TO_NUMBER(:c)]', q'[TO_CHAR(TRUNC(DBMS_RANDOM.VALUE(1, 20001)))]');

    -- Q7 cuantas variantes de un color (filtro por atributo)
    medir('Q7 Variantes de un color', q'[
        SELECT COUNT(*) FROM variante_valor WHERE id_valor_atributo = TO_NUMBER(:v)]', q'[TO_CHAR(1 + TRUNC(DBMS_RANDOM.VALUE(0, 8)))]');
END;
/
EXIT
