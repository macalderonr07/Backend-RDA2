/*==============================================================*/
/* COMERCIAL ELITE - Prueba de humo (versión Oracle 19c / 21c)  */
/* 3. PRUEBA: recorre el flujo completo con datos de ejemplo y  */
/*    comprueba los resultados y las reglas que deben rechazar. */
/*                                                              */
/* Se ejecuta después de los scripts 1 y 2, con el mismo        */
/* usuario (SYSTEM o un DBA):                                   */
/*    sqlplus system@//localhost:1521/XEPDB1 @ComercialElite_Oracle_3_prueba.sql */
/*                                                              */
/* Al final muestra "PRUEBA ORACLE: n de m OK" y DESHACE todo   */
/* (ROLLBACK): la base queda limpia. Para conservar los datos   */
/* de ejemplo cambie el ROLLBACK final por COMMIT.              */
/*==============================================================*/

SET DEFINE OFF
WHENEVER SQLERROR CONTINUE
SET SQLBLANKLINES ON
SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF
ALTER SESSION SET CURRENT_SCHEMA = produccion;

DECLARE
    v_ok      NUMBER := 0;
    v_total   NUMBER := 0;
    v_paso    VARCHAR2(200);

    -- personas, lugares y catálogo
    u_admin   NUMBER;  u_carla  NUMBER;  u_diego  NUMBER;  u_luis   NUMBER;  u_sistema NUMBER;
    c_perez   NUMBER;  c_cf     NUMBER;  c_maria  NUMBER;
    d_perez   NUMBER;  d_cf     NUMBER;  d_maria  NUMBER;
    v_quito   NUMBER;  v_ambato NUMBER;  v_dir    NUMBER;
    p_tienda  NUMBER;  p_web    NUMBER;
    m_efec    NUMBER;  m_trf    NUMBER;  m_web    NUMBER;
    v_cat     NUMBER;  v_prd_sin NUMBER; v_prd_peg NUMBER;
    v_neg     NUMBER;  v_peg    NUMBER;
    pr_neg_m  NUMBER;  pr_peg_u NUMBER;
    v_prov    NUMBER;  v_prov2  NUMBER;

    -- documentos
    v_oc      NUMBER;  v_dco    NUMBER;  v_cco    NUMBER;  v_cco_nv NUMBER;  v_cco_rec NUMBER;
    v_mov     NUMBER;  v_ped    NUMBER;  v_ped_cf NUMBER;  v_ped_web NUMBER; v_ped_cr NUMBER;
    v_comp    NUMBER;  v_comp_nv NUMBER; v_nc     NUMBER;  v_nc_nv  NUMBER;  v_oferta NUMBER;
    v_cuenta  NUMBER;  v_carrito NUMBER; v_linea  NUMBER;  v_n      NUMBER;  v_x      NUMBER;
    v_ped_tda NUMBER;  mo_defecto NUMBER; mo_insatisfecho NUMBER;
    v_lotes   SYS.ODCINUMBERLIST;

    PROCEDURE ok(p_condicion IN BOOLEAN, p_nombre IN VARCHAR2) IS
    BEGIN
        v_total := v_total + 1;
        IF p_condicion THEN
            v_ok := v_ok + 1;
            DBMS_OUTPUT.PUT_LINE('OK     ' || LPAD(v_total, 2) || '. ' || p_nombre);
        ELSE
            DBMS_OUTPUT.PUT_LINE('FALLA  ' || LPAD(v_total, 2) || '. ' || p_nombre);
        END IF;
    END ok;

    -- Ejecuta un bloque que la base debe rechazar y deshace lo que alcanzó a hacer
    PROCEDURE rechazo(p_nombre IN VARCHAR2, p_bloque IN VARCHAR2, p_codigo IN NUMBER DEFAULT -20001) IS
        v_codigo  NUMBER;
        v_mensaje VARCHAR2(4000);
    BEGIN
        SAVEPOINT antes_del_rechazo;
        EXECUTE IMMEDIATE 'BEGIN ' || p_bloque || ' END;';
        ROLLBACK TO antes_del_rechazo;
        ok(FALSE, p_nombre || ' (no fue rechazado)');
    EXCEPTION WHEN OTHERS THEN
        v_codigo  := SQLCODE;
        v_mensaje := SUBSTR(SQLERRM, 1, 150);
        ROLLBACK TO antes_del_rechazo;
        ok(v_codigo = p_codigo, p_nombre || ' -> ' || v_mensaje);
    END rechazo;

    FUNCTION total_pedido(p_pedido IN NUMBER) RETURN NUMBER IS
        v NUMBER;
    BEGIN
        SELECT total INTO v FROM v_pedido_totales WHERE id_pedido = p_pedido;
        RETURN v;
    END total_pedido;

    FUNCTION stock(p_variante IN NUMBER) RETURN NUMBER IS
        v NUMBER;
    BEGIN
        SELECT NVL(MAX(stock_fisico), 0) INTO v FROM v_stock_variante WHERE id_variante = p_variante;
        RETURN v;
    END stock;
BEGIN
    -- ================================================================
    v_paso := '1. Configuración';
    -- ================================================================
    INSERT INTO provincia (pvc_nombre) VALUES ('Pichincha');
    INSERT INTO provincia (pvc_nombre) VALUES ('Tungurahua');
    INSERT INTO ciudad (id_provincia, ciu_nombre)
    SELECT id_provincia, 'Quito' FROM provincia WHERE pvc_nombre = 'Pichincha';
    INSERT INTO ciudad (id_provincia, ciu_nombre)
    SELECT id_provincia, 'Ambato' FROM provincia WHERE pvc_nombre = 'Tungurahua';
    SELECT id_ciudad INTO v_quito  FROM ciudad WHERE ciu_nombre = 'Quito';
    SELECT id_ciudad INTO v_ambato FROM ciudad WHERE ciu_nombre = 'Ambato';

    INSERT INTO direccion (id_ciudad, dir_calle_principal, dir_numero, dir_referencia)
    VALUES (v_quito, 'Av. Principal de ejemplo', 'N1-23', 'Matriz (dato de prueba)')
    RETURNING id_direccion INTO v_dir;
    INSERT INTO empresa (emp_ruc, emp_razon_social, emp_nombre_comercial, emp_correo, id_direccion_matriz)
    VALUES ('1799999999001', 'COMERCIAL ELITE (PRUEBA)', 'Comercial Elite', 'ventas@comercialelite.ec', v_dir);

    INSERT INTO punto_emision (pem_establecimiento, pem_punto, pem_descripcion)
    VALUES ('001', '001', 'Tienda matriz') RETURNING id_punto_emision INTO p_tienda;
    INSERT INTO punto_emision (pem_establecimiento, pem_punto, pem_descripcion)
    VALUES ('001', '002', 'E-commerce') RETURNING id_punto_emision INTO p_web;

    INSERT INTO usuario (usu_correo, usu_hash_clave) VALUES ('admin@comercialelite.ec', '$2b$12$hash.prueba.admin')
    RETURNING id_usuario INTO u_admin;
    INSERT INTO usuario (usu_correo, usu_hash_clave) VALUES ('carla@comercialelite.ec', '$2b$12$hash.prueba.carla')
    RETURNING id_usuario INTO u_carla;
    INSERT INTO usuario (usu_correo, usu_hash_clave) VALUES ('diego@comercialelite.ec', '$2b$12$hash.prueba.diego')
    RETURNING id_usuario INTO u_diego;
    INSERT INTO usuario (usu_correo, usu_hash_clave) VALUES ('luis@comercialelite.ec', '$2b$12$hash.prueba.luis')
    RETURNING id_usuario INTO u_luis;
    SELECT id_usuario INTO u_sistema FROM usuario WHERE usu_correo = 'sistema@comercialelite.local';

    INSERT INTO empleado (id_usuario, id_tipo_identificacion, epl_identificacion, epl_nombres, epl_apellidos)
    VALUES (u_admin, '05', '1700000001', 'Patricia', 'Vela');
    INSERT INTO empleado (id_usuario, id_tipo_identificacion, epl_identificacion, epl_nombres, epl_apellidos)
    VALUES (u_carla, '05', '1700000002', 'Carla', 'Ruiz');
    INSERT INTO empleado (id_usuario, id_tipo_identificacion, epl_identificacion, epl_nombres, epl_apellidos)
    VALUES (u_diego, '05', '1700000003', 'Diego', 'Andrade');
    INSERT INTO empleado (id_usuario, id_tipo_identificacion, epl_identificacion, epl_nombres, epl_apellidos)
    VALUES (u_luis, '05', '1700000004', 'Luis', 'Paredes');

    INSERT INTO usuario_rol (id_usuario, id_rol) SELECT u_admin, id_rol FROM rol WHERE rol_codigo = 'ADMIN';
    INSERT INTO usuario_rol (id_usuario, id_rol) SELECT u_carla, id_rol FROM rol WHERE rol_codigo = 'VENDEDOR';
    INSERT INTO usuario_rol (id_usuario, id_rol) SELECT u_diego, id_rol FROM rol WHERE rol_codigo = 'BODEGA';
    INSERT INTO usuario_rol (id_usuario, id_rol) SELECT u_luis,  id_rol FROM rol WHERE rol_codigo = 'COMPRAS';

    SELECT id_metodo_pago INTO m_efec FROM metodo_pago WHERE mpa_nombre = 'Efectivo';
    SELECT id_metodo_pago INTO m_trf  FROM metodo_pago WHERE mpa_nombre = 'Transferencia bancaria';
    SELECT id_metodo_pago INTO m_web  FROM metodo_pago WHERE mpa_nombre = 'Pago en línea (pasarela)';
    SELECT id_motivo_devolucion INTO mo_defecto      FROM motivo_devolucion WHERE mde_nombre = 'Producto defectuoso';
    SELECT id_motivo_devolucion INTO mo_insatisfecho FROM motivo_devolucion WHERE mde_nombre = 'Cliente no satisfecho';

    -- ================================================================
    v_paso := '2. Clientes';
    -- ================================================================
    SELECT id_cliente INTO c_cf FROM cliente WHERE cli_nombres = 'CONSUMIDOR FINAL';
    SELECT id_datos_facturacion INTO d_cf FROM datos_facturacion WHERE id_cliente = c_cf;

    INSERT INTO cliente (cli_nombres, cli_correo, cli_limite_credito)
    VALUES ('Taller Calzado Pérez', 'tallerperez@correo.ec', 300) RETURNING id_cliente INTO c_perez;
    INSERT INTO telefono (id_cliente, tel_numero) VALUES (c_perez, '0990000002');
    INSERT INTO direccion (id_cliente, id_ciudad, dir_calle_principal, dir_numero, dir_referencia)
    VALUES (c_perez, v_ambato, 'Calle de ejemplo 2', '56-78', 'Junto al parque') RETURNING id_direccion INTO v_dir;
    INSERT INTO datos_facturacion (id_cliente, id_tipo_identificacion, dfa_identificacion, dfa_razon_social, dfa_correo, id_direccion)
    VALUES (c_perez, '04', '1899999999001', 'TALLER CALZADO PÉREZ', 'tallerperez@correo.ec', v_dir)
    RETURNING id_datos_facturacion INTO d_perez;

    -- María se registra en la tienda en línea: el cliente nace en producción
    -- y la cuenta queda en el nodo e-commerce
    v_cuenta := ecommerce.fn_registrar_cuenta_web('María', 'López', 'Maria.Lopez@correo.ec',
                                                  '$2b$12$hash.prueba.maria', '0990000001', '190.152.0.10');
    SELECT id_cliente INTO c_maria FROM ecommerce.cuenta_web WHERE id_cuenta_web = v_cuenta;
    INSERT INTO datos_facturacion (id_cliente, id_tipo_identificacion, dfa_identificacion, dfa_razon_social, dfa_correo)
    VALUES (c_maria, '05', '1800000001', 'MARÍA LÓPEZ', 'maria.lopez@correo.ec')
    RETURNING id_datos_facturacion INTO d_maria;
    ok(ecommerce.fn_registrar_acceso_web('maria.lopez@correo.ec', 1, 'sesion-1', '190.152.0.10', 'Firefox') = v_cuenta,
       'Cuenta web creada en el nodo e-commerce y acceso registrado (correo en minúsculas)');

    -- ================================================================
    v_paso := '3. Catálogo';
    -- ================================================================
    INSERT INTO categoria (cat_codigo, cat_nombre) VALUES ('CUE', 'Cueros y sintéticos');
    INSERT INTO categoria (cat_codigo, cat_nombre) VALUES ('QUI', 'Químicos y pegamentos');
    INSERT INTO categoria (id_categoria_padre, cat_codigo, cat_nombre)
    SELECT id_categoria, 'CUE-SIN', 'Sintéticos' FROM categoria WHERE cat_codigo = 'CUE';

    INSERT INTO atributo (atr_nombre, atr_tipo_dato) VALUES ('Color', 'COLOR');
    INSERT INTO atributo (atr_nombre, atr_tipo_dato) VALUES ('Tipo', 'TEXTO');
    INSERT INTO categoria_atributo (id_categoria, id_atributo)
    SELECT c.id_categoria, a.id_atributo FROM categoria c, atributo a WHERE c.cat_codigo = 'CUE' AND a.atr_nombre = 'Color';
    INSERT INTO categoria_atributo (id_categoria, id_atributo)
    SELECT c.id_categoria, a.id_atributo FROM categoria c, atributo a WHERE c.cat_codigo = 'QUI' AND a.atr_nombre = 'Tipo';
    INSERT INTO valor_atributo (id_atributo, val_valor) SELECT id_atributo, 'Negro' FROM atributo WHERE atr_nombre = 'Color';
    INSERT INTO valor_atributo (id_atributo, val_valor) SELECT id_atributo, 'Poliuretano' FROM atributo WHERE atr_nombre = 'Tipo';

    SELECT id_categoria INTO v_cat FROM categoria WHERE cat_codigo = 'CUE-SIN';
    INSERT INTO producto (id_categoria, id_unidad_medida, id_tarifa_iva, prd_codigo, prd_nombre, prd_uso, prd_publicado)
    VALUES (v_cat, 'm', '4', 'SIN-NAPA', 'Sintético napa', 'Capelladas y forros', 1) RETURNING id_producto INTO v_prd_sin;
    SELECT id_categoria INTO v_cat FROM categoria WHERE cat_codigo = 'QUI';
    INSERT INTO producto (id_categoria, id_unidad_medida, id_tarifa_iva, prd_codigo, prd_nombre, prd_uso, prd_publicado)
    VALUES (v_cat, 'u', '4', 'PEG-PU', 'Pegamento PU de contacto', 'Pegado de suelas', 1) RETURNING id_producto INTO v_prd_peg;

    INSERT INTO variante (id_producto, var_sku, var_stock_minimo) VALUES (v_prd_sin, 'SIN-NAPA-NEG', 40)
    RETURNING id_variante INTO v_neg;
    INSERT INTO variante (id_producto, var_sku, var_stock_minimo) VALUES (v_prd_peg, 'PEG-PU-1L', 6)
    RETURNING id_variante INTO v_peg;
    -- El color se hereda de la categoría padre CUE
    INSERT INTO variante_valor (id_variante, id_atributo, id_valor_atributo)
    SELECT v_neg, va.id_atributo, va.id_valor_atributo FROM valor_atributo va WHERE va.val_valor = 'Negro';
    INSERT INTO variante_valor (id_variante, id_atributo, id_valor_atributo)
    SELECT v_peg, va.id_atributo, va.id_valor_atributo FROM valor_atributo va WHERE va.val_valor = 'Poliuretano';

    INSERT INTO presentacion (id_variante, pre_descripcion, pre_factor, pre_cantidad_minima)
    VALUES (v_neg, 'Metro', 1, 0.5) RETURNING id_presentacion INTO pr_neg_m;
    INSERT INTO presentacion (id_variante, pre_descripcion, pre_factor, pre_cantidad_minima)
    VALUES (v_peg, 'Unidad 1 L', 1, 1) RETURNING id_presentacion INTO pr_peg_u;

    -- Precios sin IVA vigentes desde hace 90 días
    v_x := fn_registrar_precio(pr_neg_m, 6.50, u_admin, LOCALTIMESTAMP - INTERVAL '90' DAY);
    v_x := fn_registrar_precio(pr_peg_u, 9.80, u_admin, LOCALTIMESTAMP - INTERVAL '90' DAY);
    -- Cambio programado: aún no rige
    v_x := fn_registrar_precio(pr_neg_m, 6.90, u_admin, LOCALTIMESTAMP + INTERVAL '10' DAY);
    SELECT precio INTO v_x FROM v_precio_vigente WHERE id_presentacion = pr_neg_m;
    ok(v_x = 6.50, 'El precio programado no rige antes de su fecha (vigente 6.50)');

    -- ================================================================
    v_paso := '4. Compras e inventario';
    -- ================================================================
    INSERT INTO proveedor (id_tipo_identificacion, prv_identificacion, prv_razon_social, prv_correo)
    VALUES ('04', '1899999998001', 'CURTIEMBRE ANDINA (PRUEBA) S.A.', 'ventas@curtiembre.demo')
    RETURNING id_proveedor INTO v_prov;
    INSERT INTO proveedor (id_tipo_identificacion, prv_identificacion, prv_razon_social)
    VALUES ('04', '1712345678001', 'FERRETERÍA DE BARRIO (PRUEBA, RIMPE)')
    RETURNING id_proveedor INTO v_prov2;

    v_mov := fn_registrar_ajuste(v_peg, 'INI', 10, 'Inventario inicial', u_diego, 6.80, TRUNC(SYSDATE) + 150,
                                 NULL, LOCALTIMESTAMP - INTERVAL '75' DAY);

    INSERT INTO orden_compra (id_proveedor, id_usuario_crea, oc_fecha, oc_fecha_entrega_esperada, oc_observacion)
    VALUES (v_prov, u_luis, TRUNC(SYSDATE) - 50, TRUNC(SYSDATE) - 40, 'OC-PRUEBA-1') RETURNING id_orden_compra INTO v_oc;
    INSERT INTO detalle_orden_compra (id_orden_compra, id_variante, dco_cantidad, dco_costo_unitario)
    VALUES (v_oc, v_neg, 120, 4.10) RETURNING id_detalle_orden_compra INTO v_dco;
    fn_cambiar_estado_oc(v_oc, 'EMITIDA', u_luis);

    -- Factura del proveedor (tipo 01): número SRI, IVA desglosado
    v_cco := fn_registrar_comprobante_compra(v_prov, '01', '001-002-000004512', TRUNC(SYSDATE) - 45, TRUNC(SYSDATE) - 15,
                                             0, 492.00, 73.80, u_luis);
    v_mov := fn_recepcionar_compra(v_oc, u_diego,
                 '[{"id_detalle_orden_compra": ' || v_dco || ', "cantidad": 90, "costo_unitario": 4.10, "codigo_lote": "CA-2201"}]',
                 v_cco, LOCALTIMESTAMP - INTERVAL '45' DAY);
    ok(stock(v_neg) = 90 AND stock(v_peg) = 10, 'Recepción parcial (90 de 120 m) e inventario inicial en el kárdex');

    -- Compras menores sin factura: nota de venta RIMPE (02) y recibo (00), sin IVA
    v_cco_nv  := fn_registrar_comprobante_compra(v_prov2, '02', '001-001-000000123', TRUNC(SYSDATE), TRUNC(SYSDATE) + 15,
                                                 18.00, 0, 0, u_luis);
    v_cco_rec := fn_registrar_comprobante_compra(v_prov2, '00', 'REC-0007', TRUNC(SYSDATE), TRUNC(SYSDATE),
                                                 25.00, 0, 0, u_luis);
    SELECT COUNT(*), SUM(saldo) INTO v_n, v_x FROM v_cuentas_por_pagar
    WHERE id_comprobante_compra IN (v_cco, v_cco_nv, v_cco_rec);
    ok(v_n = 3 AND v_x = 565.80 + 18 + 25, 'Cuentas por pagar con factura, nota de venta y recibo (608.80)');

    INSERT INTO pago_proveedor (id_comprobante_compra, id_metodo_pago, ppr_monto, ppr_fecha, ppr_referencia, id_usuario_registra)
    VALUES (v_cco, m_trf, 400.00, TRUNC(SYSDATE) - 30, 'TRF-1001', u_luis);
    SELECT saldo INTO v_x FROM v_cuentas_por_pagar WHERE id_comprobante_compra = v_cco;
    ok(v_x = 165.80, 'Abono a la factura del proveedor (saldo 165.80)');

    -- ================================================================
    v_paso := '5. Venta en tienda con factura';
    -- ================================================================
    v_ped := fn_crear_pedido(c_perez, 'TDA', '[{"id_presentacion": ' || pr_neg_m || ', "cantidad": 10}]', u_carla, 'TDA-PEREZ');
    v_ped_tda := v_ped;
    ok(total_pedido(v_ped) = 74.75, 'Pedido en tienda: 10 m a 6.50 + IVA 15% = 74.75');
    v_x := fn_registrar_pago(v_ped, m_efec, 74.75, u_carla);
    v_comp := fn_facturar_pedido(v_ped, d_perez, p_tienda, u_carla);
    SELECT COUNT(*) INTO v_n FROM comprobante_venta
    WHERE id_comprobante_venta = v_comp AND id_tipo_comprobante = '01' AND cve_estado = 'PENDIENTE'
      AND LENGTH(cve_clave_acceso) = 49;
    ok(v_n = 1, 'Factura emitida con clave de acceso de 49 dígitos, pendiente del SRI');
    SELECT COUNT(*) INTO v_n FROM v_cola_sri WHERE tipo = 'FACTURA' AND id = v_comp;
    ok(v_n = 1 AND stock(v_neg) = 80, 'La factura entra a la cola del SRI y descarga 10 m del lote');
    fn_registrar_respuesta_sri('FACTURA', v_comp, 'AUTORIZADA', u_sistema);
    SELECT COUNT(*) INTO v_n FROM v_cola_sri WHERE tipo = 'FACTURA' AND id = v_comp;
    ok(v_n = 0, 'Respuesta del SRI registrada: la factura sale de la cola');
    fn_cambiar_estado_pedido(v_ped, 'ENT', u_diego, 'Entregado en mostrador');

    -- ================================================================
    v_paso := '6. Venta con nota de venta';
    -- ================================================================
    v_ped_cf := fn_crear_pedido(c_cf, 'TDA', '[{"id_presentacion": ' || pr_peg_u || ', "cantidad": 1}]', u_carla, 'TDA-NOTA-VENTA');
    v_x := fn_registrar_pago(v_ped_cf, m_efec, total_pedido(v_ped_cf), u_carla);
    v_comp_nv := fn_emitir_nota_venta(v_ped_cf, p_tienda, u_carla, 351);
    SELECT COUNT(*) INTO v_n FROM v_comprobante_venta
    WHERE id_comprobante_venta = v_comp_nv AND id_tipo_comprobante = '02' AND estado_sri = 'EMITIDA'
      AND clave_acceso IS NULL AND iva IS NULL AND total = 11.27 AND numero = '001-001-000000351';
    ok(v_n = 1, 'Nota de venta 001-001-000000351: sin clave, sin SRI y sin IVA desglosado (total 11.27)');
    SELECT COUNT(*) INTO v_n FROM v_cola_sri WHERE id = v_comp_nv AND tipo = 'FACTURA';
    ok(v_n = 0, 'La nota de venta no entra a la cola del SRI');

    -- ================================================================
    v_paso := '7. Negociación por WhatsApp';
    -- ================================================================
    v_ped := fn_crear_pedido(c_perez, 'WSP', '[{"id_presentacion": ' || pr_peg_u || ', "cantidad": 2, "valor_final": 20.00}]',
                             u_carla, 'WSP-NEGOCIADO');
    ok(total_pedido(v_ped) = 20.00, 'Negociación desde el valor final: 2 pegamentos (22.54) quedan en 20.00 exactos');
    v_x := fn_registrar_pago(v_ped, m_trf, 20.00, u_carla, 'TRF-77');
    v_x := fn_facturar_pedido(v_ped, d_perez, p_tienda, u_carla);

    -- ================================================================
    v_paso := '8. Oferta y compra en el e-commerce';
    -- ================================================================
    v_oferta := fn_registrar_oferta(v_prd_peg, 10, u_admin, LOCALTIMESTAMP - INTERVAL '1' MINUTE, NULL, 'Promoción pegamento');
    SELECT precio_final_con_iva INTO v_x FROM ecommerce.v_catalogo_web WHERE id_presentacion = pr_peg_u;
    ok(v_x = 10.14, 'El catálogo web muestra el pegamento con 10% de oferta (10.14 con IVA)');

    INSERT INTO ecommerce.carrito (id_cliente) VALUES (c_maria) RETURNING id_carrito INTO v_carrito;
    INSERT INTO ecommerce.item_carrito (id_carrito, id_presentacion, ica_cantidad) VALUES (v_carrito, pr_peg_u, 1);
    v_ped_web := ecommerce.fn_crear_pedido_desde_carrito(v_carrito, 'WEB-MARIA', 'sesion-1', '190.152.0.10');
    SELECT COUNT(*) INTO v_n FROM v_detalle_pedido_valor
    WHERE id_pedido = v_ped_web AND id_oferta = v_oferta AND descuento_oferta = 0.98 AND dpe_descuento = 0;
    ok(v_n = 1 AND total_pedido(v_ped_web) = 10.14, 'Pedido web con la oferta aplicada por la base (descuento 0.98, total 10.14)');
    v_x := fn_registrar_pago(v_ped_web, m_web, 10.14, u_sistema, 'PASARELA-1');
    v_x := fn_facturar_pedido(v_ped_web, d_maria, p_web, u_sistema);
    SELECT COUNT(*) INTO v_n FROM ecommerce.v_pedido_web WHERE id_pedido = v_ped_web AND estado = 'FAC' AND comprobante_venta LIKE '001-002-%';
    ok(v_n = 1, 'El e-commerce ve su pedido facturado desde el punto 001-002');

    -- ================================================================
    v_paso := '9. Notas de crédito';
    -- ================================================================
    SELECT id_detalle_pedido INTO v_linea FROM detalle_pedido WHERE id_pedido = v_ped_tda;
    v_nc := fn_emitir_nota_credito(v_comp, mo_defecto, u_admin, p_tienda,
                                   '[{"id_detalle_pedido": ' || v_linea || ', "cantidad": 1, "reingresa": true}]', 'Falla en el material');
    SELECT COUNT(*) INTO v_n FROM v_nota_credito
    WHERE id_nota_credito = v_nc AND total = 7.48 AND estado_sri = 'PENDIENTE';
    ok(v_n = 1 AND stock(v_neg) = 81, 'NC sobre factura: electrónica (pendiente del SRI), 7.48, y el metro vuelve a su lote');

    SELECT id_detalle_pedido INTO v_linea FROM detalle_pedido WHERE id_pedido = v_ped_cf;
    v_nc_nv := fn_emitir_nota_credito(v_comp_nv, mo_insatisfecho, u_admin, p_tienda,
                                      '[{"id_detalle_pedido": ' || v_linea || ', "cantidad": 1, "reingresa": false}]');
    SELECT COUNT(*) INTO v_n FROM nota_credito
    WHERE id_nota_credito = v_nc_nv AND ncr_estado = 'EMITIDA' AND ncr_clave_acceso IS NULL;
    ok(v_n = 1, 'NC sobre nota de venta: se registra sin clave ni SRI; lo dañado no reingresa');

    -- ================================================================
    v_paso := '10. Venta a crédito y abonos';
    -- ================================================================
    v_ped_cr := fn_crear_pedido(c_perez, 'TDA', '[{"id_presentacion": ' || pr_neg_m || ', "cantidad": 20}]', u_carla, 'TDA-CREDITO');
    v_x := fn_registrar_pago(v_ped_cr, m_efec, 20.00, u_carla);
    v_x := fn_facturar_a_credito(v_ped_cr, 30, d_perez, p_tienda, u_admin);
    SELECT deuda_total INTO v_x FROM v_estado_cuenta_cliente WHERE id_cliente = c_perez;
    ok(v_x = 129.50, 'Venta a crédito: 149.50 - 20 de entrada = 129.50 de deuda, con factura en el acto');
    v_n := fn_abonar_cliente(c_perez, 29.50, m_trf, u_admin, 'TRF-ABONO-1');
    SELECT deuda_total INTO v_x FROM v_estado_cuenta_cliente WHERE id_cliente = c_perez;
    ok(v_x = 100.00, 'Abono del cliente: la deuda baja a 100.00');

    -- ================================================================
    v_paso := '11. Inventario: fraccionar una pieza';
    -- ================================================================
    SELECT MIN(id_lote) INTO v_x FROM v_lote_saldo WHERE id_variante = v_neg AND saldo > 0;
    v_lotes := fn_fraccionar_lote(v_x, '[11.20, 11.20]', u_diego);
    ok(v_lotes.COUNT = 2 AND stock(v_neg) = 61, 'Fraccionamiento: dos paquetes nuevos y el stock total no cambia (61)');

    -- ================================================================
    v_paso := '12. Bitácora y auditoría';
    -- ================================================================
    SELECT COUNT(*) INTO v_n FROM log_evento WHERE lev_evento IN ('FACTURA_EMITIDA', 'NOTA_VENTA_EMITIDA', 'NC_EMITIDA');
    ok(v_n >= 5, 'Bitácora: facturas, nota de venta y notas de crédito registradas (' || v_n || ')');
    SELECT COUNT(*) INTO v_n FROM auditoria WHERE aud_tabla = 'oferta' AND aud_operacion = 'I' AND id_usuario = u_admin;
    ok(v_n = 1, 'Auditoría: la oferta queda con el usuario de la aplicación que la registró');
    SELECT COUNT(*) INTO v_n FROM auditoria
    WHERE aud_tabla = 'usuario' AND (DBMS_LOB.INSTR(aud_valores_nuevos, '$2b$') > 0 OR DBMS_LOB.INSTR(aud_valores_anteriores, '$2b$') > 0);
    ok(v_n = 0, 'Auditoría: nunca guarda el hash de la clave');
    SELECT COUNT(*) INTO v_n FROM ecommerce.log_evento_web WHERE lew_evento IN ('REGISTRO', 'LOGIN_OK', 'CHECKOUT');
    ok(v_n = 3, 'Bitácora del e-commerce: registro, acceso y confirmación del carrito');

    -- ================================================================
    v_paso := '13. Reglas que deben rechazar';
    -- ================================================================
    rechazo('El kárdex no se edita',
            'UPDATE detalle_movimiento SET dmo_cantidad = 1 WHERE ROWNUM = 1;');
    rechazo('Un vendedor no registra comprobantes de compra (sin permiso)',
            'DECLARE x NUMBER; BEGIN x := fn_registrar_comprobante_compra(' || v_prov || ', ''01'', ''001-002-000009999'', TRUNC(SYSDATE), TRUNC(SYSDATE), 0, 10, 1.5, ' || u_carla || '); END;',
            -20003);
    rechazo('Una nota de venta de compra no lleva IVA',
            'DECLARE x NUMBER; BEGIN x := fn_registrar_comprobante_compra(' || v_prov2 || ', ''02'', ''001-001-000000124'', TRUNC(SYSDATE), TRUNC(SYSDATE), 0, 10, 1.5, ' || u_luis || '); END;',
            -2290);
    rechazo('Un recibo no admite nota de crédito del proveedor',
            'DECLARE x NUMBER; BEGIN x := fn_registrar_nc_proveedor(' || v_cco_rec || ', ''001-001-000000001'', TRUNC(SYSDATE), 5, 0, 0, ''x'', ' || u_luis || '); END;');
    rechazo('No se aplica un descuento negociado en el e-commerce',
            'DECLARE x NUMBER; BEGIN x := fn_crear_pedido(' || c_maria || ', ''WEB'', ''[{"id_presentacion": ' || pr_peg_u || ', "cantidad": 1, "descuento": 1}]''); END;');
    rechazo('No se vende más de lo que hay en stock',
            'DECLARE x NUMBER; BEGIN x := fn_crear_pedido(' || c_perez || ', ''TDA'', ''[{"id_presentacion": ' || pr_neg_m || ', "cantidad": 1000}]'', ' || u_carla || '); END;');
    rechazo('Dos ofertas activas del mismo producto no se solapan',
            'DECLARE x NUMBER; BEGIN x := fn_registrar_oferta(' || v_prd_peg || ', 20, ' || u_admin || '); END;');
    rechazo('Una oferta ya usada en ventas no cambia su porcentaje',
            'UPDATE oferta SET ofe_porcentaje = 50 WHERE id_oferta = ' || v_oferta || ';');
    rechazo('Un carrito ya convertido en pedido no se modifica',
            'INSERT INTO ecommerce.item_carrito (id_carrito, id_presentacion, ica_cantidad) VALUES (' || v_carrito || ', ' || pr_neg_m || ', 1);');
    rechazo('Un comprobante emitido no cambia su número',
            'UPDATE comprobante_venta SET cve_secuencial = 999 WHERE id_comprobante_venta = ' || v_comp || ';');
    rechazo('Un pedido entregado no vuelve a pendiente',
            'fn_cambiar_estado_pedido(' || v_ped_tda || ', ''PEN'');');

    -- Consumidor final por más de USD 50: la factura exige identificar al
    -- comprador; la misma venta sí puede ir con nota de venta
    v_ped := fn_crear_pedido(c_cf, 'TDA', '[{"id_presentacion": ' || pr_neg_m || ', "cantidad": 10}]', u_carla, 'TDA-CF-GRANDE');
    v_x := fn_registrar_pago(v_ped, m_efec, total_pedido(v_ped), u_carla);
    rechazo('Factura a consumidor final por más de USD 50',
            'DECLARE x NUMBER; BEGIN x := fn_facturar_pedido(' || v_ped || ', ' || d_cf || ', ' || p_tienda || ', ' || u_carla || '); END;');
    rechazo('Una nota de venta no repite el número del talonario',
            'DECLARE x NUMBER; BEGIN x := fn_emitir_nota_venta(' || v_ped || ', ' || p_tienda || ', ' || u_carla || ', 351); END;');
    v_x := fn_emitir_nota_venta(v_ped, p_tienda, u_carla, 352);
    SELECT COUNT(*) INTO v_n FROM comprobante_venta WHERE id_comprobante_venta = v_x AND id_tipo_comprobante = '02';
    ok(v_n = 1, 'La misma venta de 74.75 a consumidor final sí sale con nota de venta 352');

    DBMS_OUTPUT.PUT_LINE('------------------------------------------------------------');
    DBMS_OUTPUT.PUT_LINE('PRUEBA ORACLE: ' || v_ok || ' de ' || v_total || ' OK');
EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('------------------------------------------------------------');
    DBMS_OUTPUT.PUT_LINE('ERROR INESPERADO en el paso "' || v_paso || '": ' || SQLERRM);
    DBMS_OUTPUT.PUT_LINE(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
    DBMS_OUTPUT.PUT_LINE('Llevaba ' || v_ok || ' de ' || v_total || ' comprobaciones OK');
END;
/

-- Deja la base limpia (cambie por COMMIT para conservar los datos de ejemplo)
ROLLBACK;
