/*==============================================================*/
/* Migracion: OUTBOX del catalogo para la cache Redis           */
/*                                                              */
/* La tienda lee el catalogo de Redis (principal) y de Oracle   */
/* (respaldo). Oracle sigue siendo la fuente de verdad: cada    */
/* cambio que altera lo que muestra v_catalogo anota en         */
/* catalogo_cambio QUE producto cambio, dentro de la MISMA      */
/* transaccion (si hay ROLLBACK, no queda nada que sincronizar).*/
/* El worker de la API lee la outbox, reconstruye solo esos     */
/* productos y borra lo procesado.                              */
/*                                                              */
/* Lo que cambia solo con el tiempo (sin ninguna escritura): un */
/* job cada minuto anota los productos cuya oferta empieza o    */
/* vence, cuyo precio programado entra en vigencia o que dejan  */
/* de ser novedad (30 dias).                                    */
/*                                                              */
/* Medido a 50.000 productos (db/bench/simulacion): +0,016 ms   */
/* por fila de kardex; retraso commit -> Redis p95 0,3 s.       */
/* Se puede correr mas de una vez.                              */
/*==============================================================*/
SET DEFINE OFF
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
ALTER SESSION SET CURRENT_SCHEMA = produccion;

DECLARE
    v_n NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_n FROM all_tables WHERE owner = 'PRODUCCION' AND table_name = 'CATALOGO_CAMBIO';
    IF v_n = 0 THEN
        EXECUTE IMMEDIATE q'[
            CREATE TABLE produccion.catalogo_cambio (
                id_cambio   NUMBER GENERATED ALWAYS AS IDENTITY,
                id_producto NUMBER NOT NULL,
                cam_origen  VARCHAR2(30) NOT NULL,
                cam_fecha   TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
                CONSTRAINT pk_catalogo_cambio PRIMARY KEY (id_cambio)
            )]';
        EXECUTE IMMEDIATE q'[COMMENT ON TABLE produccion.catalogo_cambio IS
            'Outbox: productos cuyo documento de catalogo en Redis hay que reconstruir. La escriben triggers y el job JOB_CATALOGO_VENCIMIENTOS; la consume (y borra) el worker de la API de la tienda.']';
    END IF;
    SELECT COUNT(*) INTO v_n FROM all_tables WHERE owner = 'PRODUCCION' AND table_name = 'CATALOGO_RELOJ';
    IF v_n = 0 THEN
        EXECUTE IMMEDIATE q'[
            CREATE TABLE produccion.catalogo_reloj (
                id_reloj  NUMBER(1) DEFAULT 1 NOT NULL,
                ultimo    TIMESTAMP NOT NULL,
                CONSTRAINT pk_catalogo_reloj PRIMARY KEY (id_reloj),
                CONSTRAINT ck_catalogo_reloj_unico CHECK (id_reloj = 1)
            )]';
        EXECUTE IMMEDIATE 'INSERT INTO produccion.catalogo_reloj (id_reloj, ultimo) VALUES (1, LOCALTIMESTAMP)';
    END IF;
END;
/

-- Anotar uno o varios productos (lo usan todos los triggers)
CREATE OR REPLACE PROCEDURE pr_catalogo_cambio(p_id_producto NUMBER, p_origen VARCHAR2) IS
BEGIN
    IF p_id_producto IS NOT NULL THEN
        INSERT INTO catalogo_cambio (id_producto, cam_origen) VALUES (p_id_producto, p_origen);
    END IF;
END;
/

---------------------------------------------------------------- stock (kardex)
-- El de mas volumen: COMPUESTO, junta los lotes de la sentencia y anota cada
-- producto UNA vez por sentencia (una recepcion de 50 lineas = pocas filas).
CREATE OR REPLACE TRIGGER tr_catalogo_kardex
FOR INSERT ON detalle_movimiento
COMPOUND TRIGGER
    TYPE t_ids IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    lotes t_ids;
    AFTER EACH ROW IS
    BEGIN
        lotes(lotes.COUNT + 1) := :NEW.id_lote;
    END AFTER EACH ROW;
    AFTER STATEMENT IS
        v_ids SYS.ODCINUMBERLIST := SYS.ODCINUMBERLIST();
    BEGIN
        FOR i IN 1 .. lotes.COUNT LOOP
            v_ids.EXTEND;
            v_ids(v_ids.COUNT) := lotes(i);
        END LOOP;
        INSERT INTO catalogo_cambio (id_producto, cam_origen)
        SELECT DISTINCT v.id_producto, 'kardex'
        FROM lote l JOIN variante v ON v.id_variante = l.id_variante
        WHERE l.id_lote IN (SELECT column_value FROM TABLE(v_ids));
        lotes.DELETE;
    END AFTER STATEMENT;
END;
/

---------------------------------------------------------------- precios
CREATE OR REPLACE TRIGGER tr_catalogo_precio
AFTER INSERT ON historial_precio FOR EACH ROW
DECLARE
    v_id NUMBER;
BEGIN
    SELECT MAX(v.id_producto) INTO v_id FROM presentacion pr JOIN variante v ON v.id_variante = pr.id_variante
    WHERE pr.id_presentacion = :NEW.id_presentacion;
    pr_catalogo_cambio(v_id, 'precio');
END;
/

---------------------------------------------------------------- reservas
-- Una linea de pedido reserva stock (y a veces una pieza concreta)
CREATE OR REPLACE TRIGGER tr_catalogo_reserva
AFTER INSERT OR UPDATE OR DELETE ON detalle_pedido FOR EACH ROW
DECLARE
    v_id NUMBER;
BEGIN
    SELECT MAX(v.id_producto) INTO v_id FROM presentacion pr JOIN variante v ON v.id_variante = pr.id_variante
    WHERE pr.id_presentacion = NVL(:NEW.id_presentacion, :OLD.id_presentacion);
    pr_catalogo_cambio(v_id, 'reserva');
END;
/

-- Pagar, cancelar o entregar un pedido confirma o libera sus reservas
CREATE OR REPLACE TRIGGER tr_catalogo_estado_pedido
AFTER INSERT ON historial_estado_pedido FOR EACH ROW
BEGIN
    INSERT INTO catalogo_cambio (id_producto, cam_origen)
    SELECT DISTINCT v.id_producto, 'estado pedido'
    FROM detalle_pedido d
    JOIN presentacion pr ON pr.id_presentacion = d.id_presentacion
    JOIN variante v      ON v.id_variante = pr.id_variante
    WHERE d.id_pedido = :NEW.id_pedido;
END;
/

---------------------------------------------------------------- datos del producto
CREATE OR REPLACE TRIGGER tr_catalogo_producto
AFTER INSERT OR UPDATE ON producto FOR EACH ROW
BEGIN
    pr_catalogo_cambio(:NEW.id_producto, 'producto');
END;
/
CREATE OR REPLACE TRIGGER tr_catalogo_variante
AFTER INSERT OR UPDATE ON variante FOR EACH ROW
BEGIN
    pr_catalogo_cambio(:NEW.id_producto, 'variante');
END;
/
CREATE OR REPLACE TRIGGER tr_catalogo_presentacion
AFTER INSERT OR UPDATE ON presentacion FOR EACH ROW
DECLARE
    v_id NUMBER;
BEGIN
    SELECT MAX(id_producto) INTO v_id FROM variante WHERE id_variante = :NEW.id_variante;
    pr_catalogo_cambio(v_id, 'presentacion');
END;
/
CREATE OR REPLACE TRIGGER tr_catalogo_caracteristica
AFTER INSERT OR UPDATE OR DELETE ON variante_valor FOR EACH ROW
DECLARE
    v_id NUMBER;
BEGIN
    SELECT MAX(id_producto) INTO v_id FROM variante WHERE id_variante = NVL(:NEW.id_variante, :OLD.id_variante);
    pr_catalogo_cambio(v_id, 'caracteristica');
END;
/
CREATE OR REPLACE TRIGGER tr_catalogo_oferta
AFTER INSERT OR UPDATE ON oferta FOR EACH ROW
BEGIN
    pr_catalogo_cambio(:NEW.id_producto, 'oferta');
END;
/
CREATE OR REPLACE TRIGGER tr_catalogo_descuento
AFTER INSERT OR UPDATE ON descuento_volumen FOR EACH ROW
BEGIN
    pr_catalogo_cambio(:NEW.id_producto, 'descuento');
END;
/

---------------------------------------------------------------- catalogos (cambian a muchos productos)
-- Categoria: sus productos y los de sus subcategorias (la "linea" es la padre).
-- COMPUESTO: un trigger por fila no puede consultar categoria (ORA-04091).
CREATE OR REPLACE TRIGGER tr_catalogo_categoria
FOR UPDATE OF cat_nombre, cat_codigo, cat_activa, id_categoria_padre ON categoria
COMPOUND TRIGGER
    v_ids SYS.ODCINUMBERLIST := SYS.ODCINUMBERLIST();
    AFTER EACH ROW IS
    BEGIN
        v_ids.EXTEND;
        v_ids(v_ids.COUNT) := :NEW.id_categoria;
    END AFTER EACH ROW;
    AFTER STATEMENT IS
    BEGIN
        INSERT INTO catalogo_cambio (id_producto, cam_origen)
        SELECT p.id_producto, 'categoria' FROM producto p
        WHERE p.id_categoria IN (SELECT column_value FROM TABLE(v_ids))
           OR p.id_categoria IN (SELECT c.id_categoria FROM categoria c
                                 WHERE c.id_categoria_padre IN (SELECT column_value FROM TABLE(v_ids)));
        v_ids.DELETE;
    END AFTER STATEMENT;
END;
/
CREATE OR REPLACE TRIGGER tr_catalogo_marca
AFTER UPDATE OF mar_nombre, mar_activa ON marca FOR EACH ROW
BEGIN
    INSERT INTO catalogo_cambio (id_producto, cam_origen)
    SELECT id_producto, 'marca' FROM producto WHERE id_marca = :NEW.id_marca;
END;
/
CREATE OR REPLACE TRIGGER tr_catalogo_tarifa_iva
AFTER UPDATE OF tiv_porcentaje ON tarifa_iva FOR EACH ROW
BEGIN
    INSERT INTO catalogo_cambio (id_producto, cam_origen)
    SELECT id_producto, 'tarifa iva' FROM producto WHERE id_tarifa_iva = :NEW.id_tarifa_iva;
END;
/
CREATE OR REPLACE TRIGGER tr_catalogo_unidad
AFTER UPDATE OF umd_nombre ON unidad_medida FOR EACH ROW
BEGIN
    INSERT INTO catalogo_cambio (id_producto, cam_origen)
    SELECT id_producto, 'unidad' FROM producto WHERE id_unidad_medida = :NEW.id_unidad_medida;
END;
/

---------------------------------------------------------------- lo que cambia con el tiempo
-- Anota los productos con un "vencimiento" entre la ultima pasada y ahora:
-- ofertas que empiezan/terminan, precios programados que entran en vigencia y
-- productos que dejan de ser novedad (v_catalogo: creados hace <= 30 dias).
CREATE OR REPLACE PROCEDURE pr_catalogo_vencimientos IS
    v_desde TIMESTAMP;
    v_hasta TIMESTAMP := LOCALTIMESTAMP;
BEGIN
    SELECT ultimo INTO v_desde FROM catalogo_reloj WHERE id_reloj = 1 FOR UPDATE;
    INSERT INTO catalogo_cambio (id_producto, cam_origen)
    SELECT DISTINCT id_producto, origen FROM (
        SELECT o.id_producto, 'oferta (fecha)' AS origen FROM oferta o
        WHERE (o.ofe_desde > v_desde AND o.ofe_desde <= v_hasta) OR (o.ofe_hasta > v_desde AND o.ofe_hasta <= v_hasta)
        UNION ALL
        SELECT v.id_producto, 'precio (fecha)' FROM historial_precio h
        JOIN presentacion pr ON pr.id_presentacion = h.id_presentacion
        JOIN variante v      ON v.id_variante = pr.id_variante
        WHERE h.hpr_vigente_desde > v_desde AND h.hpr_vigente_desde <= v_hasta
        UNION ALL
        SELECT p.id_producto, 'novedad (fecha)' FROM producto p
        WHERE CAST(TRUNC(CAST(p.prd_fecha_creacion AS DATE)) + 31 AS TIMESTAMP) > v_desde
          AND CAST(TRUNC(CAST(p.prd_fecha_creacion AS DATE)) + 31 AS TIMESTAMP) <= v_hasta);
    UPDATE catalogo_reloj SET ultimo = v_hasta WHERE id_reloj = 1;
    COMMIT;
END;
/

BEGIN
    BEGIN DBMS_SCHEDULER.DROP_JOB('PRODUCCION.JOB_CATALOGO_VENCIMIENTOS', force => TRUE); EXCEPTION WHEN OTHERS THEN NULL; END;
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'PRODUCCION.JOB_CATALOGO_VENCIMIENTOS',
        job_type        => 'STORED_PROCEDURE',
        job_action      => 'PRODUCCION.PR_CATALOGO_VENCIMIENTOS',
        repeat_interval => 'FREQ=MINUTELY;INTERVAL=1',
        enabled         => TRUE,
        comments        => 'Anota en catalogo_cambio los productos cuya oferta, precio o novedad cambio con el tiempo');
END;
/

---------------------------------------------------------------- permisos
-- La API de la tienda (rol ELITE_ECOMMERCE) lee la outbox y borra lo procesado.
-- No puede insertar ni modificar: eso solo lo hacen los triggers y el job.
GRANT SELECT, DELETE ON catalogo_cambio TO elite_ecommerce;

SELECT object_name || ' ' || object_type || ' ' || status FROM all_objects
WHERE owner = 'PRODUCCION' AND (object_name LIKE 'TR_CATALOGO%' OR object_name LIKE 'PR_CATALOGO%' OR object_name IN ('CATALOGO_CAMBIO', 'CATALOGO_RELOJ'))
ORDER BY object_type, object_name;
SELECT 'job: ' || job_name || ' ' || state || ' ' || enabled FROM dba_scheduler_jobs WHERE owner = 'PRODUCCION' AND job_name = 'JOB_CATALOGO_VENCIMIENTOS';
EXIT
