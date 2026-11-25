/*==============================================================*/
/* Migracion: hora de Ecuador en el job del catalogo            */
/*                                                              */
/* Las APIs ahora fijan su sesion en America/Guayaquil, asi los */
/* DEFAULT LOCALTIMESTAMP guardan la hora de Ecuador aunque el  */
/* servidor corra en UTC. El job JOB_CATALOGO_VENCIMIENTOS no   */
/* pasa por las APIs: corre en una sesion de la base (UTC). Con */
/* LOCALTIMESTAMP comparaba la hora UTC contra ofertas y precios*/
/* guardados en hora de Ecuador (5 horas de diferencia). Ahora  */
/* usa la hora de Ecuador de forma explicita.                   */
/*                                                              */
/* Se puede correr mas de una vez.                              */
/*==============================================================*/
SET DEFINE OFF
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
ALTER SESSION SET CURRENT_SCHEMA = produccion;

CREATE OR REPLACE PROCEDURE pr_catalogo_vencimientos IS
    v_desde TIMESTAMP;
    -- hora de Ecuador, sin depender de la zona de la sesion del job
    v_hasta TIMESTAMP := CAST(SYSTIMESTAMP AT TIME ZONE 'America/Guayaquil' AS TIMESTAMP);
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

-- El reloj guardaba la ultima pasada en hora UTC: se lleva a la hora de Ecuador
-- (lo que venza en ese lapso lo cubre la reconstruccion completa de la API).
UPDATE catalogo_reloj SET ultimo = CAST(SYSTIMESTAMP AT TIME ZONE 'America/Guayaquil' AS TIMESTAMP) WHERE id_reloj = 1;
COMMIT;

SELECT object_name || ' ' || status FROM all_objects WHERE owner = 'PRODUCCION' AND object_name = 'PR_CATALOGO_VENCIMIENTOS';
EXIT
