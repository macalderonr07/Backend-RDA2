/*==============================================================*/
/* Migracion: codigo de lote AUTOMATICO en la recepcion         */
/*                                                              */
/* El usuario ya no escribe codigos de lote: si la linea no     */
/* trae uno, la base lo genera como OC<orden>-<n>, correlativo  */
/* dentro de cada orden de compra (sigue la numeracion en las   */
/* recepciones parciales). En el cuero cada banda es un lote:   */
/* ese codigo es el que identifica la banda en la venta y en la */
/* tienda (OC21-1, OC21-2...).                                  */
/* La API puede seguir enviando el codigo del proveedor (si lo  */
/* hubiera); el panel de administracion ya no lo pide.          */
/*                                                              */
/* Se puede correr mas de una vez (CREATE OR REPLACE).          */
/*==============================================================*/
SET DEFINE OFF
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
ALTER SESSION SET CURRENT_SCHEMA = produccion;

-- C11. Recepcion de mercaderia (total o parcial). Cada linea crea un lote
--      con el costo real (si no se indica, el pactado en la OC) y su codigo
--      (si no se indica, OC<orden>-<n>).
CREATE OR REPLACE FUNCTION fn_recepcionar_compra(p_orden IN NUMBER, p_usuario IN NUMBER, p_lineas IN CLOB,
                                                 p_comprobante_compra IN NUMBER DEFAULT NULL,
                                                 p_fechahora IN TIMESTAMP DEFAULT LOCALTIMESTAMP)
RETURN NUMBER IS
    v_movimiento NUMBER;
    v_lote       NUMBER;
    v_bloqueo    NUMBER;
    v_n          NUMBER;
    d            v_orden_compra_detalle%ROWTYPE;
BEGIN
    fn_exigir_permiso(p_usuario, 'INV_RECEPCIONAR');
    SELECT MAX(id_orden_compra) INTO v_bloqueo FROM orden_compra WHERE id_orden_compra = p_orden;
    IF v_bloqueo IS NOT NULL THEN
        SELECT id_orden_compra INTO v_bloqueo FROM orden_compra WHERE id_orden_compra = p_orden FOR UPDATE;
    END IF;

    INSERT INTO movimiento_inventario (id_tipo_movimiento, mov_fechahora, id_usuario, id_orden_compra, id_comprobante_compra)
    VALUES ('COM', p_fechahora, p_usuario, p_orden, p_comprobante_compra)
    RETURNING id_movimiento INTO v_movimiento;

    -- lotes ya recibidos de esta OC: el codigo automatico sigue desde ahi
    SELECT COUNT(DISTINCT dm.id_lote) INTO v_n
    FROM detalle_movimiento dm
    JOIN detalle_orden_compra doc ON doc.id_detalle_orden_compra = dm.id_detalle_orden_compra
    WHERE doc.id_orden_compra = p_orden;

    FOR r IN (SELECT j.*
              FROM JSON_TABLE(p_lineas, '$[*]' COLUMNS (
                       id_detalle_orden_compra NUMBER        PATH '$.id_detalle_orden_compra',
                       cantidad                NUMBER        PATH '$.cantidad',
                       costo_unitario          NUMBER        PATH '$.costo_unitario',
                       fecha_vencimiento       VARCHAR2(10)  PATH '$.fecha_vencimiento',
                       codigo_lote             VARCHAR2(30)  PATH '$.codigo_lote')) j) LOOP
        BEGIN
            SELECT * INTO d FROM v_orden_compra_detalle
            WHERE id_detalle_orden_compra = r.id_detalle_orden_compra AND id_orden_compra = p_orden;
        EXCEPTION WHEN NO_DATA_FOUND THEN
            pr_error('La línea ' || r.id_detalle_orden_compra || ' no pertenece a la OC ' || p_orden);
        END;
        IF r.cantidad > d.cantidad_pendiente THEN
            pr_error('Se intenta recibir ' || r.cantidad || ' de ' || d.var_sku || ', pero solo quedan '
                     || d.cantidad_pendiente || ' pendientes');
        END IF;

        v_n := v_n + 1;
        INSERT INTO lote (id_variante, lot_costo_unitario, lot_fecha_vencimiento, lot_codigo_proveedor)
        VALUES (d.id_variante, NVL(r.costo_unitario, d.costo_pactado), TO_DATE(r.fecha_vencimiento, 'YYYY-MM-DD'),
                NVL(TRIM(r.codigo_lote), 'OC' || p_orden || '-' || v_n))
        RETURNING id_lote INTO v_lote;

        INSERT INTO detalle_movimiento (id_movimiento, id_lote, dmo_cantidad, id_detalle_orden_compra)
        VALUES (v_movimiento, v_lote, r.cantidad, r.id_detalle_orden_compra);
    END LOOP;

    RETURN v_movimiento;
END fn_recepcionar_compra;
/

SELECT object_name || ' ' || status FROM all_objects WHERE owner = 'PRODUCCION' AND object_name = 'FN_RECEPCIONAR_COMPRA';
EXIT
