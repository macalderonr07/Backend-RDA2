/*==============================================================*/
/* Migracion: precio y costo POR VARIANTE solo cuando el        */
/* producto lo pide                                             */
/*                                                              */
/* Por defecto un producto vale lo mismo en todos sus colores   */
/* y tallas (el cuero negro y el cafe cuestan igual). Solo      */
/* algunos modelos (ciertas suelas) tienen un color con otro    */
/* precio o costo: eso se marca al crear el producto.           */
/*                                                              */
/*  producto.prd_precio_por_variante (0/1, por defecto 0).      */
/*  Con 0, la administracion registra precios y costos para     */
/*  TODAS las variantes a la vez; con 1 deja fijarlos por       */
/*  variante.                                                   */
/*                                                              */
/* Se puede correr mas de una vez.                              */
/*==============================================================*/
SET DEFINE OFF
SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
ALTER SESSION SET CURRENT_SCHEMA = produccion;

DECLARE
    v_n NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_n FROM all_tab_columns
    WHERE owner = 'PRODUCCION' AND table_name = 'PRODUCTO' AND column_name = 'PRD_PRECIO_POR_VARIANTE';
    IF v_n = 0 THEN
        EXECUTE IMMEDIATE 'ALTER TABLE produccion.producto ADD prd_precio_por_variante NUMBER(1) DEFAULT 0 NOT NULL';
        EXECUTE IMMEDIATE 'ALTER TABLE produccion.producto ADD CONSTRAINT ck_producto_precio_variante CHECK (prd_precio_por_variante IN (0, 1))';
        EXECUTE IMMEDIATE q'[COMMENT ON COLUMN produccion.producto.prd_precio_por_variante IS 'Con 1, cada variante (color, talla) puede tener su propio precio y costo (ciertas suelas). Con 0, todas las variantes valen lo mismo.']';
        DBMS_OUTPUT.PUT_LINE('  + producto.prd_precio_por_variante');
    END IF;
END;
/
-- Las suelas de la demo: un color puede costar distinto
UPDATE producto SET prd_precio_por_variante = 1 WHERE prd_codigo IN ('CE-3005', 'CE-3006') AND prd_precio_por_variante = 0;
COMMIT;
EXIT
