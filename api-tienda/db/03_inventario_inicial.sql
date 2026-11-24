/*==============================================================*/
/* Inventario inicial de Comercial Elite (datos de desarrollo)  */
/*                                                              */
/* Como SYSTEM/SYSDBA en la PDB, despues de 02_catalogo_inicial:*/
/*   sqlplus system@//localhost:1521/FREEPDB1 @03_inventario_inicial.sql */
/*                                                              */
/* Sigue el flujo "Inventario dia a dia > Arranque" de la       */
/* documentacion: un ajuste INI por variante con su costo, por  */
/* la funcion oficial fn_registrar_ajuste (crea el movimiento,  */
/* el lote y el detalle del kardex, y deja bitacora).           */
/*                                                              */
/* La funcion exige INV_AJUSTAR: se crea un usuario tecnico de  */
/* bodega (sin clave utilizable, como el usuario SISTEMA).      */
/*                                                              */
/* Las variantes que no aparecen aqui quedan en 0 a proposito   */
/* (agotadas), para probar el selector de la tienda:            */
/*   CE-1042-03 Miel, CE-2011-02 Camel, CE-7002-03 Negro y      */
/*   CE-8002-01 (el producto entero agotado).                   */
/*                                                              */
/* Se puede correr mas de una vez: una variante que ya tiene    */
/* lotes no recibe otro inventario inicial.                     */
/*==============================================================*/
SET DEFINE OFF
SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
ALTER SESSION SET CURRENT_SCHEMA = produccion;

DECLARE
    TYPE t_stock IS TABLE OF NUMBER INDEX BY VARCHAR2(30);
    v_stock   t_stock;
    v_usuario NUMBER;
    v_sku     VARCHAR2(30);
    v_var     NUMBER;
    v_costo   NUMBER;
    v_factor  NUMBER;
    v_n       NUMBER;
    v_mov     NUMBER;
    v_cargas  PLS_INTEGER := 0;
BEGIN
    -- Cantidad en PRESENTACIONES (bandas, rollos, conos, cajas...). Se registra en
    -- el kardex en la UNIDAD BASE del producto: presentaciones x factor
    -- (12 bandas x 23.5 pie2 = 282 pie2; 40 conos x 500 m = 20 000 m).
    v_stock('CE-1042-01') := 12;  v_stock('CE-1042-02') := 8;
    v_stock('CE-1043-01') := 10;  v_stock('CE-1043-02') := 6;   v_stock('CE-1043-03') := 3;
    v_stock('CE-2010-01') := 15;  v_stock('CE-2010-02') := 9;   v_stock('CE-2010-03') := 4;
    v_stock('CE-2011-01') := 7;
    v_stock('CE-3005-01') := 120;
    v_stock('CE-3006-01') := 80;  v_stock('CE-3006-02') := 4;
    v_stock('CE-4001-01') := 200;
    v_stock('CE-4002-01') := 150;
    v_stock('CE-5001-01') := 40;  v_stock('CE-5001-02') := 25;  v_stock('CE-5001-03') := 18;
    v_stock('CE-5002-01') := 30;  v_stock('CE-5002-02') := 5;
    v_stock('CE-6001-01') := 24;
    v_stock('CE-6002-01') := 2;
    v_stock('CE-7001-01') := 60;  v_stock('CE-7001-02') := 45;
    v_stock('CE-7002-01') := 35;  v_stock('CE-7002-02') := 20;
    v_stock('CE-8001-01') := 14;

    -- Usuario tecnico de bodega (rol BODEGA -> INV_AJUSTAR)
    SELECT MAX(id_usuario) INTO v_usuario FROM usuario WHERE usu_correo = 'inventario@comercialelite.local';
    IF v_usuario IS NULL THEN
        INSERT INTO usuario (usu_correo, usu_hash_clave) VALUES ('inventario@comercialelite.local', '!sin-acceso')
        RETURNING id_usuario INTO v_usuario;
        INSERT INTO usuario_rol (id_usuario, id_rol)
        SELECT v_usuario, id_rol FROM rol WHERE rol_codigo = 'BODEGA';
    END IF;

    v_sku := v_stock.FIRST;
    WHILE v_sku IS NOT NULL LOOP
        SELECT id_variante INTO v_var FROM variante WHERE var_sku = v_sku;
        SELECT COUNT(*) INTO v_n FROM lote WHERE id_variante = v_var;
        IF v_n = 0 THEN
            -- Costo de desarrollo por UNIDAD BASE: 60 % del precio sin IVA de la
            -- presentacion, dividido para lo que trae (su factor)
            SELECT MIN(pr.pre_factor) KEEP (DENSE_RANK FIRST ORDER BY pr.id_presentacion),
                   ROUND(MIN(pv.precio / pr.pre_factor) * 0.6, 4)
              INTO v_factor, v_costo
            FROM presentacion pr JOIN v_precio_vigente pv ON pv.id_presentacion = pr.id_presentacion
            WHERE pr.id_variante = v_var;
            v_mov := fn_registrar_ajuste(v_var, 'INI', v_stock(v_sku) * v_factor, 'Inventario inicial (desarrollo)',
                                         v_usuario, v_costo);
            v_cargas := v_cargas + 1;
        END IF;
        v_sku := v_stock.NEXT(v_sku);
    END LOOP;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Inventario inicial: ' || v_cargas || ' variantes cargadas.');
END;
/
EXIT
