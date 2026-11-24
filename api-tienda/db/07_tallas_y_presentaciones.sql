/*==============================================================*/
/* Migracion: tallas (suelas y plantillas) y presentaciones     */
/*            de venta (hebillas, ojalillos, galon)             */
/*                                                              */
/* Casos de uso del negocio:                                    */
/*  1. SUELAS y PLANTILLAS se manejan POR TALLA: atributo       */
/*     "Talla" y una variante por color x talla (el stock se    */
/*     controla por variante, regla del modelo). El inventario  */
/*     de la variante vieja "sin talla" se redistribuye por el  */
/*     kardex (AJN en la vieja + INI por talla, con el costo    */
/*     del lote original) y la vieja se desactiva.              */
/*  2. HEBILLAS: ademas de la caja x 100, se venden por Unidad, */
/*     1/2 docena y Docena (precio por volumen).                */
/*  3. OJALILLOS: se venden por Ciento o por Millar; la "Bolsa  */
/*     x 1000 u" se desactiva (el Millar la reemplaza).         */
/*  4. GALON (pegamento): se vende el Galon o por Litro, 1/2 y  */
/*     1/4 de litro. SIN venta por pieza: el inventario esta en */
/*     litros y disponible = FLOOR(saldo/factor), asi que al    */
/*     consumirse parte de un galon el contador de galones baja */
/*     solo y el resto queda vendible como litros (la regla     */
/*     "un galon abierto se vende por litros"). Marcarlo por    */
/*     pieza limitaria cada linea a UN galon (una linea = una   */
/*     pieza), y los galones cerrados si se venden de a varios. */
/*                                                              */
/* Se puede correr mas de una vez: cada paso verifica su estado.*/
/*                                                              */
/* Como SYSTEM/SYSDBA en la PDB:                                */
/*   sqlplus system@//localhost:1521/FREEPDB1 @07_tallas_y_presentaciones.sql */
/*==============================================================*/
SET DEFINE OFF
SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

ALTER SESSION SET CURRENT_SCHEMA = produccion;

DECLARE
    v_sistema NUMBER;
    v_bodega  NUMBER;
    v_talla   NUMBER;  -- id del atributo Talla

    -- Presentacion nueva con su precio (vigente desde ayer: ver 06, zona horaria)
    PROCEDURE pres(p_variante IN NUMBER, p_desc IN VARCHAR2, p_factor IN NUMBER,
                   p_minima IN NUMBER, p_precio IN NUMBER) IS
        v_pre NUMBER;
    BEGIN
        SELECT MAX(id_presentacion) INTO v_pre
        FROM presentacion WHERE id_variante = p_variante AND pre_descripcion = p_desc;
        IF v_pre IS NULL THEN
            INSERT INTO presentacion (id_variante, pre_descripcion, pre_factor, pre_cantidad_minima)
            VALUES (p_variante, p_desc, p_factor, p_minima)
            RETURNING id_presentacion INTO v_pre;
            INSERT INTO historial_precio (id_presentacion, hpr_precio, hpr_vigente_desde, id_usuario)
            VALUES (v_pre, p_precio, CAST(SYSDATE - 1 AS TIMESTAMP), v_sistema);
        END IF;
    END;

    FUNCTION valor_talla(p_talla IN VARCHAR2) RETURN NUMBER IS
        v_val NUMBER;
    BEGIN
        SELECT MAX(id_valor_atributo) INTO v_val
        FROM valor_atributo WHERE id_atributo = v_talla AND val_valor = p_talla;
        IF v_val IS NULL THEN
            INSERT INTO valor_atributo (id_atributo, val_valor) VALUES (v_talla, p_talla)
            RETURNING id_valor_atributo INTO v_val;
        END IF;
        RETURN v_val;
    END;

    -- Divide una variante "sin talla" en una variante por talla.
    -- p_cant(i) = pares de la talla (p_desde + i - 1); su suma debe ser el saldo actual.
    PROCEDURE tallas(p_sku IN VARCHAR2, p_desde IN PLS_INTEGER, p_cant IN SYS.ODCINUMBERLIST) IS
        v_old      NUMBER;
        v_prod     NUMBER;
        v_precio   NUMBER;
        v_costo    NUMBER;
        v_saldo    NUMBER;
        v_color    NUMBER;
        v_nueva    NUMBER;
        v_mov      NUMBER;
        v_valtalla NUMBER;
        v_tallatxt VARCHAR2(10);
    BEGIN
        SELECT MAX(id_variante) INTO v_old FROM variante WHERE var_sku = p_sku AND var_activa = 1;
        IF v_old IS NULL THEN
            DBMS_OUTPUT.PUT_LINE('  = ' || p_sku || ': ya migrada a tallas');
            RETURN;
        END IF;
        SELECT id_producto INTO v_prod FROM variante WHERE id_variante = v_old;
        SELECT MAX(pv.precio) INTO v_precio
        FROM presentacion pr JOIN v_precio_vigente pv ON pv.id_presentacion = pr.id_presentacion
        WHERE pr.id_variante = v_old;
        SELECT MAX(lot_costo_unitario) INTO v_costo
        FROM v_lote_saldo WHERE id_variante = v_old AND saldo > 0;
        SELECT disponible INTO v_saldo FROM v_stock_variante WHERE id_variante = v_old;
        SELECT MAX(vv.id_valor_atributo) INTO v_color
        FROM variante_valor vv JOIN atributo a ON a.id_atributo = vv.id_atributo
        WHERE vv.id_variante = v_old AND a.atr_nombre = 'Color';

        FOR i IN 1 .. p_cant.COUNT LOOP
            v_tallatxt := TO_CHAR(p_desde + i - 1);
            INSERT INTO variante (id_producto, var_sku, var_stock_minimo)
            VALUES (v_prod, p_sku || '-T' || v_tallatxt, 2)
            RETURNING id_variante INTO v_nueva;
            IF v_color IS NOT NULL THEN
                INSERT INTO variante_valor (id_variante, id_atributo, id_valor_atributo)
                SELECT v_nueva, id_atributo, v_color FROM valor_atributo WHERE id_valor_atributo = v_color;
            END IF;
            v_valtalla := valor_talla(v_tallatxt);
            INSERT INTO variante_valor (id_variante, id_atributo, id_valor_atributo)
            VALUES (v_nueva, v_talla, v_valtalla);
            pres(v_nueva, 'Par', 1, 1, v_precio);
            IF p_cant(i) > 0 AND v_costo IS NOT NULL THEN
                v_mov := fn_registrar_ajuste(v_nueva, 'INI', p_cant(i),
                                             'Inventario inicial de la talla ' || v_tallatxt ||
                                             ' (redistribucion de ' || p_sku || ')',
                                             v_bodega, v_costo);
            END IF;
        END LOOP;

        IF v_saldo > 0 THEN
            v_mov := fn_registrar_ajuste(v_old, 'AJN', v_saldo,
                                         'Redistribucion del inventario por tallas', v_bodega);
        END IF;
        UPDATE variante SET var_activa = 0 WHERE id_variante = v_old;
        DBMS_OUTPUT.PUT_LINE('  + ' || p_sku || ': ' || p_cant.COUNT || ' tallas desde la ' || p_desde);
    END;
BEGIN
    SELECT id_usuario INTO v_sistema FROM usuario WHERE usu_correo = 'sistema@comercialelite.local';
    SELECT MAX(id_usuario) INTO v_bodega FROM usuario WHERE usu_correo = 'inventario@comercialelite.local';
    IF v_bodega IS NULL THEN
        RAISE_APPLICATION_ERROR(-20000, 'Falta el usuario de bodega: correr antes 03_inventario_inicial.sql');
    END IF;
    fn_usuario_sesion(v_bodega);

    -- 1. Atributo Talla, asociado a las lineas de suelas y plantillas
    SELECT MAX(id_atributo) INTO v_talla FROM atributo WHERE atr_nombre = 'Talla';
    IF v_talla IS NULL THEN
        INSERT INTO atributo (atr_nombre) VALUES ('Talla') RETURNING id_atributo INTO v_talla;
    END IF;
    INSERT INTO categoria_atributo (id_categoria, id_atributo)
    SELECT c.id_categoria, v_talla
    FROM categoria c
    WHERE c.cat_codigo IN ('suelas', 'plantillas')
      AND NOT EXISTS (SELECT 1 FROM categoria_atributo ca
                      WHERE ca.id_categoria = c.id_categoria AND ca.id_atributo = v_talla);

    -- Suelas: SR-220 tallas 35-44; EVA 34-42. Plantillas: 34-45.
    -- Las cantidades suman el saldo actual de cada variante (campana por talla).
    tallas('CE-3005-01', 35, SYS.ODCINUMBERLIST(6, 10, 14, 16, 18, 18, 14, 12, 8, 4));          -- 120
    tallas('CE-3006-01', 34, SYS.ODCINUMBERLIST(4, 6, 10, 12, 14, 12, 10, 8, 4));               -- 80
    tallas('CE-3006-02', 34, SYS.ODCINUMBERLIST(0, 0, 0, 1, 2, 1, 0, 0, 0));                    -- 4
    tallas('CE-4001-01', 34, SYS.ODCINUMBERLIST(8, 12, 16, 20, 24, 26, 24, 22, 18, 14, 10, 6)); -- 200
    tallas('CE-4002-01', 34, SYS.ODCINUMBERLIST(6, 8, 12, 14, 18, 20, 18, 16, 14, 12, 8, 4));   -- 150

    -- 2. Hebillas (CE-7002): Unidad, 1/2 docena y Docena ademas de la caja
    FOR v IN (SELECT v.id_variante FROM variante v
              JOIN producto p ON p.id_producto = v.id_producto
              WHERE p.prd_codigo = 'CE-7002' AND v.var_activa = 1) LOOP
        pres(v.id_variante, 'Unidad',     1,  1, 0.04);
        pres(v.id_variante, '1/2 docena', 6,  1, 0.20);
        pres(v.id_variante, 'Docena',     12, 1, 0.36);
    END LOOP;

    -- 3. Ojalillos (CE-7001): Ciento o Millar; la bolsa x 1000 se desactiva
    FOR v IN (SELECT v.id_variante FROM variante v
              JOIN producto p ON p.id_producto = v.id_producto
              WHERE p.prd_codigo = 'CE-7001' AND v.var_activa = 1) LOOP
        UPDATE presentacion SET pre_activa = 0
        WHERE id_variante = v.id_variante AND pre_descripcion LIKE 'Bolsa%' AND pre_activa = 1;
        pres(v.id_variante, 'Ciento', 100,  1, 0.10);
        pres(v.id_variante, 'Millar', 1000, 1, 0.78);
    END LOOP;

    -- 4. Galon (CE-6001): Litro, 1/2 litro y 1/4 de litro ademas del galon
    FOR v IN (SELECT v.id_variante FROM variante v
              JOIN producto p ON p.id_producto = v.id_producto
              WHERE p.prd_codigo = 'CE-6001' AND v.var_activa = 1) LOOP
        pres(v.id_variante, 'Litro',      1,    1, 3.80);
        pres(v.id_variante, '1/2 litro',  0.5,  1, 2.00);
        pres(v.id_variante, '1/4 litro',  0.25, 1, 1.10);
    END LOOP;

    COMMIT;
END;
/

SELECT owner, object_name, object_type FROM dba_objects
WHERE owner IN ('PRODUCCION', 'ECOMMERCE') AND status <> 'VALID';
PROMPT (si la consulta anterior no devolvio filas, todo quedo valido)
EXIT
