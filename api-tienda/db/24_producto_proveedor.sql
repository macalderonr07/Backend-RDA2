/*==============================================================*/
/* Migracion: PROVEEDORES de cada producto (muchos a muchos)    */
/*                                                              */
/* Un producto se relaciona con uno o mas proveedores (quien lo */
/* vende). Opcionalmente, con el codigo que usa ese proveedor.  */
/* La orden de compra muestra primero los productos del         */
/* proveedor elegido.                                           */
/* Datos iniciales: los pares proveedor-producto que ya salen   */
/* de las ordenes de compra registradas.                        */
/*                                                              */
/* Se puede correr mas de una vez.                              */
/*==============================================================*/
SET DEFINE OFF
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
ALTER SESSION SET CURRENT_SCHEMA = produccion;

DECLARE
    v_n NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_n FROM all_tables WHERE owner = 'PRODUCCION' AND table_name = 'PRODUCTO_PROVEEDOR';
    IF v_n = 0 THEN
        EXECUTE IMMEDIATE q'[
            CREATE TABLE produccion.producto_proveedor (
                id_producto          NUMBER NOT NULL,
                id_proveedor         NUMBER NOT NULL,
                ppv_codigo_proveedor VARCHAR2(40 CHAR),
                ppv_fecha_registro   TIMESTAMP DEFAULT LOCALTIMESTAMP NOT NULL,
                CONSTRAINT pk_producto_proveedor PRIMARY KEY (id_producto, id_proveedor),
                CONSTRAINT fk_ppv_producto FOREIGN KEY (id_producto) REFERENCES produccion.producto (id_producto),
                CONSTRAINT fk_ppv_proveedor FOREIGN KEY (id_proveedor) REFERENCES produccion.proveedor (id_proveedor)
            )]';
        EXECUTE IMMEDIATE 'CREATE INDEX produccion.ix_ppv_proveedor ON produccion.producto_proveedor (id_proveedor)';
        EXECUTE IMMEDIATE q'[COMMENT ON TABLE produccion.producto_proveedor IS 'Proveedores de cada producto (un producto puede tener varios)']';
    END IF;
END;
/

MERGE INTO producto_proveedor x
USING (SELECT DISTINCT v.id_producto, oc.id_proveedor
       FROM orden_compra oc
       JOIN detalle_orden_compra d ON d.id_orden_compra = oc.id_orden_compra
       JOIN variante v             ON v.id_variante = d.id_variante) n
ON (x.id_producto = n.id_producto AND x.id_proveedor = n.id_proveedor)
WHEN NOT MATCHED THEN INSERT (id_producto, id_proveedor) VALUES (n.id_producto, n.id_proveedor);
COMMIT;

GRANT SELECT, INSERT, UPDATE, DELETE ON producto_proveedor TO elite_produccion;

SELECT 'relaciones producto-proveedor: ' || COUNT(*) FROM producto_proveedor;
EXIT
