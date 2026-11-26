/*==============================================================*/
/* Migracion: COTIZACIONES (ventas por confirmar)               */
/*                                                              */
/* Lo que el cliente envia desde la tienda ya no crea un pedido */
/* (que reservaba stock): crea una COTIZACION, aparte de los    */
/* pedidos y las ventas.                                        */
/*  - No reserva stock.                                         */
/*  - El personal la ve en la administracion, la edita          */
/*    (cantidades, lineas) y la CONFIRMA: ahi se convierte en   */
/*    pedido con fn_crear_pedido (que valida y reserva el stock;*/
/*    si falta, avisa que falta).                               */
/*  - Vence a los 14 dias: un job la elimina si no se confirmo. */
/*                                                              */
/* Se puede correr mas de una vez.                              */
/*==============================================================*/
SET DEFINE OFF
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
ALTER SESSION SET CURRENT_SCHEMA = produccion;

DECLARE
    v_n NUMBER;
    PROCEDURE ddl(p VARCHAR2) IS BEGIN EXECUTE IMMEDIATE p; END;
BEGIN
    SELECT COUNT(*) INTO v_n FROM all_tables WHERE owner = 'PRODUCCION' AND table_name = 'COTIZACION';
    IF v_n = 0 THEN
        ddl(q'[CREATE TABLE produccion.cotizacion (
                  id_cotizacion       NUMBER GENERATED ALWAYS AS IDENTITY,
                  id_cliente          NUMBER NOT NULL,
                  id_canal_venta      VARCHAR2(3 CHAR) DEFAULT 'WEB' NOT NULL,
                  cot_observacion     VARCHAR2(300 CHAR),
                  cot_fecha           TIMESTAMP DEFAULT LOCALTIMESTAMP NOT NULL,
                  cot_vence           TIMESTAMP NOT NULL,
                  cot_estado          VARCHAR2(12 CHAR) DEFAULT 'PENDIENTE' NOT NULL,
                  id_pedido           NUMBER,
                  id_usuario_confirma NUMBER,
                  cot_confirmada      TIMESTAMP,
                  CONSTRAINT pk_cotizacion PRIMARY KEY (id_cotizacion),
                  CONSTRAINT fk_cot_cliente FOREIGN KEY (id_cliente) REFERENCES produccion.cliente (id_cliente),
                  CONSTRAINT fk_cot_canal FOREIGN KEY (id_canal_venta) REFERENCES produccion.canal_venta (id_canal_venta),
                  CONSTRAINT fk_cot_pedido FOREIGN KEY (id_pedido) REFERENCES produccion.pedido (id_pedido),
                  CONSTRAINT ck_cot_estado CHECK (cot_estado IN ('PENDIENTE', 'CONFIRMADA')),
                  CONSTRAINT ck_cot_confirmada CHECK ((cot_estado = 'PENDIENTE' AND id_pedido IS NULL) OR (cot_estado = 'CONFIRMADA' AND id_pedido IS NOT NULL)))]');
        ddl('CREATE INDEX produccion.ix_cot_estado_vence ON produccion.cotizacion (cot_estado, cot_vence)');
        ddl('CREATE INDEX produccion.ix_cot_cliente ON produccion.cotizacion (id_cliente)');
        ddl(q'[COMMENT ON TABLE produccion.cotizacion IS 'Venta por confirmar (cotizacion de la tienda): no reserva stock; se confirma como pedido o vence a los 14 dias']');
        ddl(q'[CREATE TABLE produccion.cotizacion_linea (
                  id_cotizacion_linea NUMBER GENERATED ALWAYS AS IDENTITY,
                  id_cotizacion       NUMBER NOT NULL,
                  id_presentacion     NUMBER NOT NULL,
                  col_cantidad        NUMBER(12,3) NOT NULL,
                  id_lote             NUMBER,
                  CONSTRAINT pk_cotizacion_linea PRIMARY KEY (id_cotizacion_linea),
                  CONSTRAINT fk_col_cotizacion FOREIGN KEY (id_cotizacion) REFERENCES produccion.cotizacion (id_cotizacion) ON DELETE CASCADE,
                  CONSTRAINT fk_col_presentacion FOREIGN KEY (id_presentacion) REFERENCES produccion.presentacion (id_presentacion),
                  CONSTRAINT fk_col_lote FOREIGN KEY (id_lote) REFERENCES produccion.lote (id_lote),
                  CONSTRAINT ck_col_cantidad CHECK (col_cantidad > 0))]');
        ddl('CREATE INDEX produccion.ix_col_cotizacion ON produccion.cotizacion_linea (id_cotizacion)');
    END IF;
END;
/

-- Una cotizacion confirmada ya es un pedido: sus lineas no se tocan.
CREATE OR REPLACE TRIGGER tr_cotizacion_linea_editable
BEFORE INSERT OR UPDATE OR DELETE ON cotizacion_linea
FOR EACH ROW
DECLARE
    -- al borrar la cotizacion (solo se borran pendientes) sus lineas se borran en
    -- cascada y la tabla padre esta "mutando": ahi no hay nada que proteger
    e_mutante EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_mutante, -4091);
    v_estado VARCHAR2(12);
BEGIN
    SELECT MAX(cot_estado) INTO v_estado FROM cotizacion WHERE id_cotizacion = NVL(:NEW.id_cotizacion, :OLD.id_cotizacion);
    IF v_estado = 'CONFIRMADA' THEN
        pr_error('La cotización ya se confirmó como pedido: no se puede modificar');
    END IF;
EXCEPTION
    WHEN e_mutante THEN
        NULL;
END;
/

/* Ahora en Ecuador (el job corre en una sesion UTC de la base). */
CREATE OR REPLACE FUNCTION fn_ahora_ecuador RETURN TIMESTAMP IS
BEGIN
    RETURN CAST(SYSTIMESTAMP AT TIME ZONE 'America/Guayaquil' AS TIMESTAMP);
END fn_ahora_ecuador;
/

/* Crea una cotizacion. p_lineas: '[{"id_presentacion": 1, "cantidad": 2, "id_lote": null}]'.
   NO reserva stock: solo valida que cada forma de venta exista y este activa. */
CREATE OR REPLACE FUNCTION fn_crear_cotizacion(p_cliente IN NUMBER, p_canal IN VARCHAR2, p_lineas IN CLOB,
                                               p_observacion IN VARCHAR2 DEFAULT NULL)
RETURN NUMBER IS
    v_cot    NUMBER;
    v_activa NUMBER;
    v_n      NUMBER := 0;
BEGIN
    INSERT INTO cotizacion (id_cliente, id_canal_venta, cot_observacion, cot_vence)
    VALUES (p_cliente, NVL(p_canal, 'WEB'), p_observacion, fn_ahora_ecuador + INTERVAL '14' DAY)
    RETURNING id_cotizacion INTO v_cot;
    FOR r IN (SELECT j.* FROM JSON_TABLE(p_lineas, '$[*]' COLUMNS (
                  id_presentacion NUMBER PATH '$.id_presentacion',
                  cantidad        NUMBER PATH '$.cantidad',
                  id_lote         NUMBER PATH '$.id_lote')) j) LOOP
        SELECT MAX(pre_activa) INTO v_activa FROM presentacion WHERE id_presentacion = r.id_presentacion;
        IF NVL(v_activa, 0) <> 1 THEN
            pr_error('La forma de venta ' || r.id_presentacion || ' no existe o ya no se ofrece');
        END IF;
        IF NVL(r.cantidad, 0) <= 0 THEN
            pr_error('Cantidad no válida en la cotización');
        END IF;
        INSERT INTO cotizacion_linea (id_cotizacion, id_presentacion, col_cantidad, id_lote)
        VALUES (v_cot, r.id_presentacion, r.cantidad, NULLIF(r.id_lote, 0));
        v_n := v_n + 1;
    END LOOP;
    IF v_n = 0 THEN
        pr_error('La cotización no tiene productos');
    END IF;
    RETURN v_cot;
END fn_crear_cotizacion;
/

/* Confirma una cotizacion pendiente: crea el pedido (fn_crear_pedido valida y
   reserva el stock; si falta, dice que falta) y la deja CONFIRMADA. */
CREATE OR REPLACE FUNCTION fn_confirmar_cotizacion(p_cotizacion IN NUMBER, p_usuario IN NUMBER, p_vendedor IN NUMBER DEFAULT NULL)
RETURN NUMBER IS
    c        cotizacion%ROWTYPE;
    v_lineas CLOB;
    v_pedido NUMBER;
BEGIN
    fn_exigir_permiso(p_usuario, 'VENTA_REGISTRAR');
    BEGIN
        SELECT * INTO c FROM cotizacion WHERE id_cotizacion = p_cotizacion FOR UPDATE;
    EXCEPTION WHEN NO_DATA_FOUND THEN
        pr_error('La cotización ' || p_cotizacion || ' no existe (pudo haber vencido)');
    END;
    IF c.cot_estado <> 'PENDIENTE' THEN
        pr_error('La cotización ya se confirmó como el pedido ' || c.id_pedido);
    END IF;
    IF c.cot_vence < fn_ahora_ecuador THEN
        pr_error('La cotización venció: crea una venta nueva');
    END IF;
    SELECT JSON_ARRAYAGG(JSON_OBJECT('id_presentacion' VALUE id_presentacion, 'cantidad' VALUE col_cantidad, 'id_lote' VALUE id_lote)
                         ORDER BY id_cotizacion_linea RETURNING CLOB)
      INTO v_lineas
    FROM cotizacion_linea WHERE id_cotizacion = p_cotizacion;
    IF v_lineas IS NULL THEN
        pr_error('La cotización no tiene productos');
    END IF;
    v_pedido := fn_crear_pedido(c.id_cliente, c.id_canal_venta, v_lineas, p_vendedor,
                                SUBSTR('Cotización COT-' || LPAD(p_cotizacion, 6, '0') || NVL2(c.cot_observacion, ': ' || c.cot_observacion, ''), 1, 300));
    UPDATE cotizacion SET cot_estado = 'CONFIRMADA', id_pedido = v_pedido, id_usuario_confirma = p_usuario, cot_confirmada = fn_ahora_ecuador
    WHERE id_cotizacion = p_cotizacion;
    RETURN v_pedido;
END fn_confirmar_cotizacion;
/

/* Elimina las cotizaciones pendientes vencidas (las confirmadas quedan como historial del pedido). */
CREATE OR REPLACE PROCEDURE pr_eliminar_cotizaciones_vencidas IS
BEGIN
    DELETE FROM cotizacion WHERE cot_estado = 'PENDIENTE' AND cot_vence < fn_ahora_ecuador;
    COMMIT;
END pr_eliminar_cotizaciones_vencidas;
/

BEGIN
    BEGIN DBMS_SCHEDULER.DROP_JOB('PRODUCCION.JOB_COTIZACIONES_VENCIDAS', force => TRUE); EXCEPTION WHEN OTHERS THEN NULL; END;
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'PRODUCCION.JOB_COTIZACIONES_VENCIDAS',
        job_type        => 'STORED_PROCEDURE',
        job_action      => 'PRODUCCION.PR_ELIMINAR_COTIZACIONES_VENCIDAS',
        repeat_interval => 'FREQ=HOURLY;INTERVAL=1',
        enabled         => TRUE,
        comments        => 'Elimina las cotizaciones pendientes que pasaron sus 14 dias');
END;
/

GRANT SELECT, INSERT, UPDATE, DELETE ON cotizacion TO elite_produccion;
GRANT SELECT, INSERT, UPDATE, DELETE ON cotizacion_linea TO elite_produccion;
GRANT EXECUTE ON fn_confirmar_cotizacion TO elite_produccion;
GRANT EXECUTE ON fn_crear_cotizacion TO elite_produccion;
-- el nodo e-commerce crea cotizaciones desde el carrito (funcion con derechos del dueno)
GRANT EXECUTE ON fn_crear_cotizacion TO ecommerce;
GRANT SELECT ON cotizacion TO ecommerce WITH GRANT OPTION;

-- ---------------------------------------------------------------- nodo e-commerce
ALTER SESSION SET CURRENT_SCHEMA = ecommerce;

DECLARE
    v_n NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_n FROM all_tab_columns WHERE owner = 'ECOMMERCE' AND table_name = 'CARRITO' AND column_name = 'ID_COTIZACION';
    IF v_n = 0 THEN
        EXECUTE IMMEDIATE 'ALTER TABLE ecommerce.carrito ADD (id_cotizacion NUMBER)';
    END IF;
END;
/

/* Checkout de la tienda: el carrito se envia como COTIZACION (no reserva stock). */
CREATE OR REPLACE FUNCTION fn_crear_cotizacion_desde_carrito(p_carrito IN NUMBER, p_observacion IN VARCHAR2 DEFAULT NULL,
                                                             p_sesion IN VARCHAR2 DEFAULT NULL, p_ip IN VARCHAR2 DEFAULT NULL)
RETURN NUMBER IS
    c        carrito%ROWTYPE;
    v_cuenta NUMBER;
    v_activa NUMBER;
    v_lineas CLOB;
    v_cot    NUMBER;
BEGIN
    BEGIN
        SELECT * INTO c FROM carrito WHERE id_carrito = p_carrito FOR UPDATE;
    EXCEPTION WHEN NO_DATA_FOUND THEN
        pr_error('El carrito ' || p_carrito || ' no existe');
    END;
    IF c.id_cotizacion IS NOT NULL OR c.id_pedido IS NOT NULL THEN
        pr_error('El carrito ' || p_carrito || ' ya se envió');
    END IF;
    IF c.id_cliente IS NULL THEN
        pr_error('Identifique al cliente (cuenta o datos de invitado) antes de enviar la cotización');
    END IF;
    SELECT MAX(id_cuenta_web), MAX(cwe_activa) INTO v_cuenta, v_activa FROM cuenta_web WHERE id_cliente = c.id_cliente;
    IF v_activa = 0 THEN
        pr_error('La cuenta web del cliente está desactivada');
    END IF;
    SELECT JSON_ARRAYAGG(JSON_OBJECT('id_presentacion' VALUE id_presentacion, 'cantidad' VALUE ica_cantidad,
                                     'id_lote' VALUE NULLIF(ica_pieza, 0))
                         ORDER BY id_presentacion, ica_pieza RETURNING CLOB)
      INTO v_lineas
    FROM item_carrito WHERE id_carrito = p_carrito;
    IF v_lineas IS NULL THEN
        pr_error('El carrito ' || p_carrito || ' está vacío');
    END IF;

    v_cot := produccion.fn_crear_cotizacion(c.id_cliente, 'WEB', v_lineas, p_observacion);

    UPDATE carrito SET id_cotizacion = v_cot WHERE id_carrito = p_carrito;
    pr_log_web('INFO', 'COTIZACION', 'Carrito ' || p_carrito || ' enviado como cotización ' || v_cot,
               v_cuenta, NVL(p_sesion, c.car_token), p_ip, NULL,
               '{"id_carrito": ' || p_carrito || ', "id_cotizacion": ' || v_cot || '}');
    RETURN v_cot;
END fn_crear_cotizacion_desde_carrito;
/

-- Un carrito enviado (como cotizacion o, antes, como pedido) ya no se modifica
CREATE OR REPLACE TRIGGER tr_carrito_actividad
AFTER INSERT OR UPDATE OR DELETE ON item_carrito
FOR EACH ROW
DECLARE
    e_mutante EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_mutante, -4091);
    v_carrito NUMBER := CASE WHEN DELETING THEN :OLD.id_carrito ELSE :NEW.id_carrito END;
    v_pedido  NUMBER;
    v_cot     NUMBER;
BEGIN
    SELECT MAX(id_pedido), MAX(id_cotizacion) INTO v_pedido, v_cot FROM carrito WHERE id_carrito = v_carrito;
    IF v_pedido IS NOT NULL THEN
        pr_error('El carrito ' || v_carrito || ' ya se convirtió en el pedido ' || v_pedido || ' y no se modifica');
    ELSIF v_cot IS NOT NULL THEN
        pr_error('El carrito ' || v_carrito || ' ya se envió como la cotización ' || v_cot || ' y no se modifica');
    END IF;
    UPDATE carrito SET car_actualizado = LOCALTIMESTAMP WHERE id_carrito = v_carrito;
EXCEPTION
    WHEN e_mutante THEN
        NULL;
END;
/

-- El pedido y la cotizacion de un carrito se fijan una sola vez
CREATE OR REPLACE TRIGGER tr_carrito_pedido
BEFORE UPDATE OF id_pedido, id_cotizacion ON carrito
FOR EACH ROW
BEGIN
    IF :OLD.id_pedido IS NOT NULL AND (:NEW.id_pedido IS NULL OR :NEW.id_pedido <> :OLD.id_pedido) THEN
        pr_error('El carrito ' || :OLD.id_carrito || ' ya se convirtió en el pedido ' || :OLD.id_pedido);
    END IF;
    IF :OLD.id_cotizacion IS NOT NULL AND (:NEW.id_cotizacion IS NULL OR :NEW.id_cotizacion <> :OLD.id_cotizacion) THEN
        pr_error('El carrito ' || :OLD.id_carrito || ' ya se envió como la cotización ' || :OLD.id_cotizacion);
    END IF;
END;
/

/* Lo que la tienda puede ver de su cotizacion. */
CREATE OR REPLACE VIEW v_cotizacion_web AS
SELECT ca.car_token, co.id_cotizacion, 'COT-' || LPAD(co.id_cotizacion, 6, '0') AS numero, co.cot_fecha AS fecha,
       co.cot_vence AS vence, co.cot_estado AS estado, co.id_pedido
FROM carrito ca
JOIN produccion.cotizacion co ON co.id_cotizacion = ca.id_cotizacion;

GRANT EXECUTE ON fn_crear_cotizacion_desde_carrito TO elite_ecommerce;
GRANT SELECT ON v_cotizacion_web TO elite_ecommerce;

BEGIN
    DBMS_UTILITY.COMPILE_SCHEMA(schema => 'PRODUCCION', compile_all => FALSE);
    DBMS_UTILITY.COMPILE_SCHEMA(schema => 'ECOMMERCE', compile_all => FALSE);
END;
/
SELECT owner, object_name, object_type FROM dba_objects WHERE owner IN ('PRODUCCION', 'ECOMMERCE') AND status <> 'VALID';
PROMPT (si la consulta anterior no devolvio filas, todo quedo valido)
EXIT
