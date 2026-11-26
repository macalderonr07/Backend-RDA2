/*==============================================================*/
/* Migracion: todo lote tiene codigo                            */
/*                                                              */
/* 1. Una sola vez: completa el codigo de los lotes que no lo   */
/*    tienen (se recibieron antes de la migracion 19, o nacieron*/
/*    de un ajuste). Es lo que identifica cada banda de cuero   */
/*    en la venta y en la tienda.                               */
/*      - de una orden de compra: OC<orden>-<n>, en el mismo    */
/*        orden que numera fn_recepcionar_compra (no choca con  */
/*        los ya generados);                                    */
/*      - de un ajuste (INI/AJP): <tipo>-<movimiento>;          */
/*      - cualquier otro: L<id> (como el fraccionamiento).      */
/*    EXCEPCION documentada a la regla "los lotes no se         */
/*    modifican": se desactiva tr_lote_inmutable SOLO para este */
/*    UPDATE de la columna del codigo (nunca cantidad ni costo) */
/*    y se vuelve a activar aunque algo falle.                  */
/* 2. Desde ahora, los lotes de un ajuste (inventario inicial o */
/*    sobrante) nacen con codigo <tipo>-<movimiento>, como los  */
/*    de una recepcion (OC<n>-<k>) y los de un corte (padre-k). */
/*                                                              */
/* Se puede correr mas de una vez.                              */
/*==============================================================*/
SET DEFINE OFF
SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
ALTER SESSION SET CURRENT_SCHEMA = produccion;

DECLARE
    v_n NUMBER := 0;
BEGIN
    EXECUTE IMMEDIATE 'ALTER TRIGGER produccion.tr_lote_inmutable DISABLE';
    BEGIN
        MERGE INTO lote l
        USING (
            SELECT id_lote, codigo FROM (
                -- de una orden de compra: posicion del lote dentro de su orden
                SELECT x.id_lote, 'OC' || x.id_orden_compra || '-' ||
                       ROW_NUMBER() OVER (PARTITION BY x.id_orden_compra ORDER BY x.id_lote) AS codigo
                FROM (SELECT DISTINCT dm.id_lote, doc.id_orden_compra
                      FROM detalle_movimiento dm
                      JOIN detalle_orden_compra doc ON doc.id_detalle_orden_compra = dm.id_detalle_orden_compra) x
                UNION ALL
                -- de un ajuste: el movimiento que lo creo
                SELECT l2.id_lote, MIN(m.id_tipo_movimiento || '-' || m.id_movimiento) KEEP (DENSE_RANK FIRST ORDER BY m.id_movimiento)
                FROM lote l2
                JOIN detalle_movimiento dm ON dm.id_lote = l2.id_lote
                JOIN movimiento_inventario m ON m.id_movimiento = dm.id_movimiento
                WHERE m.id_tipo_movimiento IN ('INI', 'AJP') AND dm.id_detalle_orden_compra IS NULL
                  AND NOT EXISTS (SELECT 1 FROM detalle_movimiento d2 WHERE d2.id_lote = l2.id_lote AND d2.id_detalle_orden_compra IS NOT NULL)
                GROUP BY l2.id_lote)
        ) n
        ON (l.id_lote = n.id_lote)
        WHEN MATCHED THEN UPDATE SET l.lot_codigo_proveedor = n.codigo WHERE l.lot_codigo_proveedor IS NULL;
        v_n := SQL%ROWCOUNT;
        -- los demas (sin orden ni ajuste conocido): como el fraccionamiento
        UPDATE lote SET lot_codigo_proveedor = 'L' || id_lote WHERE lot_codigo_proveedor IS NULL;
        v_n := v_n + SQL%ROWCOUNT;
        COMMIT;
    EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        EXECUTE IMMEDIATE 'ALTER TRIGGER produccion.tr_lote_inmutable ENABLE';
        RAISE;
    END;
    EXECUTE IMMEDIATE 'ALTER TRIGGER produccion.tr_lote_inmutable ENABLE';
    DBMS_OUTPUT.PUT_LINE('Lotes que recibieron su codigo: ' || v_n);
END;
/

-- C13 (codigo automatico en los lotes que crea un ajuste)
CREATE OR REPLACE FUNCTION fn_registrar_ajuste(p_variante IN NUMBER, p_tipo IN VARCHAR2, p_cantidad IN NUMBER,
                                               p_motivo IN VARCHAR2, p_usuario IN NUMBER,
                                               p_costo_unitario IN NUMBER DEFAULT NULL,
                                               p_fecha_vencimiento IN DATE DEFAULT NULL,
                                               p_lote IN NUMBER DEFAULT NULL,
                                               p_fechahora IN TIMESTAMP DEFAULT LOCALTIMESTAMP)
RETURN NUMBER IS
    v_movimiento NUMBER;
    v_lote       NUMBER;
    v_costo      NUMBER := p_costo_unitario;
    v_n          NUMBER;
BEGIN
    fn_exigir_permiso(p_usuario, 'INV_AJUSTAR');
    IF p_tipo IS NULL OR p_tipo NOT IN ('INI', 'AJP', 'AJN', 'MER') THEN
        pr_error('Tipo de ajuste no válido: ' || p_tipo);
    END IF;
    IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
        pr_error('La cantidad del ajuste debe ser mayor que cero');
    END IF;

    INSERT INTO movimiento_inventario (id_tipo_movimiento, mov_fechahora, id_usuario, mov_motivo)
    VALUES (p_tipo, p_fechahora, p_usuario, p_motivo)
    RETURNING id_movimiento INTO v_movimiento;

    IF p_tipo IN ('INI', 'AJP') THEN
        IF v_costo IS NULL AND p_tipo = 'AJP' THEN
            SELECT MAX(lot_costo_unitario) KEEP (DENSE_RANK LAST ORDER BY id_lote) INTO v_costo
            FROM lote WHERE id_variante = p_variante;
        END IF;
        IF v_costo IS NULL THEN
            pr_error('Indique el costo unitario del ingreso');
        END IF;
        INSERT INTO lote (id_variante, lot_costo_unitario, lot_fecha_vencimiento, lot_codigo_proveedor)
        VALUES (p_variante, v_costo, p_fecha_vencimiento, p_tipo || '-' || v_movimiento)
        RETURNING id_lote INTO v_lote;
        INSERT INTO detalle_movimiento (id_movimiento, id_lote, dmo_cantidad)
        VALUES (v_movimiento, v_lote, p_cantidad);
    ELSIF p_lote IS NOT NULL THEN
        SELECT COUNT(*) INTO v_n FROM lote WHERE id_lote = p_lote AND id_variante = p_variante;
        IF v_n = 0 THEN
            pr_error('El lote ' || p_lote || ' no pertenece a la variante indicada');
        END IF;
        INSERT INTO detalle_movimiento (id_movimiento, id_lote, dmo_cantidad)
        VALUES (v_movimiento, p_lote, p_cantidad);
    ELSE
        fn_consumir_lotes(v_movimiento, p_variante, p_cantidad);
    END IF;

    pr_log(CASE WHEN p_tipo IN ('AJN', 'MER') THEN 'AVISO' ELSE 'INFO' END, 'INVENTARIO', 'AJUSTE_INVENTARIO',
           p_tipo || ' de ' || p_cantidad || ' (variante ' || p_variante || '): ' || p_motivo,
           p_usuario, '{"id_movimiento": ' || v_movimiento || '}');
    RETURN v_movimiento;
END fn_registrar_ajuste;
/

SELECT 'lotes sin codigo: ' || COUNT(*) FROM lote WHERE lot_codigo_proveedor IS NULL;
SELECT 'trigger tr_lote_inmutable: ' || status FROM all_triggers WHERE owner = 'PRODUCCION' AND trigger_name = 'TR_LOTE_INMUTABLE';
SELECT object_name || ' ' || status FROM all_objects WHERE owner = 'PRODUCCION' AND object_name = 'FN_REGISTRAR_AJUSTE';
EXIT
