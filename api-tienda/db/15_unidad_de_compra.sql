/*==============================================================*/
/* Migracion: UNIDAD DE COMPRA de cada producto                 */
/*                                                              */
/* Se compra siempre en la unidad mas grande del proveedor y se */
/* vende en partes: el velcro y el sintetico llegan en ROLLOS y */
/* se venden por metro (o cuarto de metro); la fibra llega en   */
/* PLANCHAS; el cuero en PAQUETES de bandas que se miden una a  */
/* una. El inventario sigue en la unidad base (m, pie2): esto   */
/* solo dice como se cuenta lo que se compra y lo que hay.      */
/*                                                              */
/*  producto.prd_compra_descripcion  "Rollo × 30 m", "Plancha", */
/*                                   "Paquete de bandas"        */
/*  producto.prd_compra_factor       contenido en unidad base   */
/*                                   (30, 12); NULL = cada      */
/*                                   pieza se mide al recibir   */
/*                                   (solo venta por pieza)     */
/*  Sin descripcion: se compra en la unidad base (unidades).    */
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
    WHERE owner = 'PRODUCCION' AND table_name = 'PRODUCTO' AND column_name = 'PRD_COMPRA_DESCRIPCION';
    IF v_n = 0 THEN
        EXECUTE IMMEDIATE 'ALTER TABLE produccion.producto ADD (prd_compra_descripcion VARCHAR2(40) NULL, prd_compra_factor NUMBER(12,3) NULL)';
        EXECUTE IMMEDIATE q'[ALTER TABLE produccion.producto ADD CONSTRAINT ck_producto_compra CHECK (
            (prd_compra_descripcion IS NULL AND prd_compra_factor IS NULL)
            OR (prd_compra_descripcion IS NOT NULL AND prd_compra_factor > 0)
            OR (prd_compra_descripcion IS NOT NULL AND prd_compra_factor IS NULL AND prd_venta_por_pieza = 1))]';
        EXECUTE IMMEDIATE q'[COMMENT ON COLUMN produccion.producto.prd_compra_descripcion IS 'Unidad en que se compra al proveedor (Rollo × 30 m, Plancha, Paquete de bandas). NULL = se compra en la unidad base.']';
        EXECUTE IMMEDIATE q'[COMMENT ON COLUMN produccion.producto.prd_compra_factor IS 'Contenido de la unidad de compra en unidad base (30 m, 12 pie2). NULL con descripcion = piezas de medida variable que se miden al recibir (bandas de cuero).']';
        DBMS_OUTPUT.PUT_LINE('  + producto.prd_compra_descripcion / prd_compra_factor');
    END IF;
END;
/

-- Unidades de compra de los productos de la demo (solo si no tienen una)
DECLARE
    PROCEDURE fijar(p_codigo VARCHAR2, p_desc VARCHAR2, p_factor NUMBER) IS
    BEGIN
        UPDATE producto SET prd_compra_descripcion = p_desc, prd_compra_factor = p_factor
        WHERE prd_codigo = p_codigo AND prd_compra_descripcion IS NULL;
    END;
BEGIN
    fijar('CE-1042', 'Paquete de bandas', NULL);   -- cada banda se mide al recibir
    fijar('CE-1043', 'Paquete de bandas', NULL);
    fijar('CE-2010', 'Rollo × 30 m', 30);          -- se vende por metro, 1/2 y 1/4
    fijar('CE-2011', 'Rollo × 30 m', 30);
    fijar('CE-10001', 'Rollo × 25 m', 25);         -- velcro
    fijar('CE-9101', 'Plancha (12 pie²)', 12);     -- cada plancha es una pieza
    fijar('CE-9001', 'Rollo × 100 m', 100);        -- cierre
    fijar('CE-5001', 'Cono × 500 m', 500);
    fijar('CE-5002', 'Cono × 1000 m', 1000);
    fijar('CE-6001', 'Galón × 3,7 L', 3.7);
    fijar('CE-7001', 'Millar', 1000);              -- ojalillos
    fijar('CE-7002', 'Caja × 100 u', 100);         -- hebillas
    fijar('CE-9002', 'Ciento', 100);               -- llaves de cierre
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('  ~ unidades de compra de la demo');
END;
/
EXIT
