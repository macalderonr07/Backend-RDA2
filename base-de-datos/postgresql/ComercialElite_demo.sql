-- =====================================================================
--  COMERCIAL ELITE · Modelo físico corregido
--  Escenario de prueba (opcional)
--  Requiere: ComercialElite_PDM.sql y ComercialElite_logica.sql recién
--  ejecutados en una base limpia.
--  Recomendado: ejecutarlo con psql para ver los avisos y las consultas
--      psql -d <base> -f ComercialElite_demo.sql
-- =====================================================================
--  Recorre el flujo completo con datos ficticios:
--    1. Configuración: ubicación, empresa, puntos de emisión, personal
--    2. Clientes: con cuenta, invitado, taller con límite de crédito
--    3. Catálogo: categorías, atributos, productos, variantes, precios
--    4. Compras: órdenes de compra, recepciones parciales, factura y pago
--       al proveedor, inventario inicial
--    5. Ventas: web con cuenta, web como invitado, tienda y WhatsApp,
--       negociación de precio desde el valor final pactado, oferta
--       preestablecida aplicada a una compra web y venta con nota de venta
--    6. Devoluciones: notas de crédito con y sin reingreso, reembolso
--    7. Venta a crédito, avance de dinero y abonos
--    8. Cuero por bandas: precio por banda o por pie, piezas y paquetes
--    9. Ajustes, merma, devolución a proveedor, factura que llega
--       después de la mercadería, nota de crédito del proveedor y
--       compras menores con nota de venta o sin comprobante
--   10. Pruebas que deben ser rechazadas
--   11. Consultas de resultado (incluye bitácora, auditoría y vistas
--       del nodo e-commerce)
--  Para las 141 pruebas automáticas use ComercialElite_pruebas.sql
-- =====================================================================

SET client_min_messages TO notice;
-- Utilidades de la demo en public; las tablas están en los esquemas de cada nodo
SET search_path = public, produccion, ecommerce;

-- Utilidades solo para leer el escenario (se eliminan al final)
CREATE FUNCTION demo_usuario(p_correo TEXT) RETURNS INTEGER LANGUAGE sql AS
$$ SELECT id_usuario FROM usuario WHERE usu_correo = p_correo $$;
CREATE FUNCTION demo_cliente(p_nombres TEXT) RETURNS INTEGER LANGUAGE sql AS
$$ SELECT id_cliente FROM cliente WHERE cli_nombres = p_nombres $$;
CREATE FUNCTION demo_pres(p_sku TEXT, p_desc TEXT) RETURNS INTEGER LANGUAGE sql AS
$$ SELECT pr.id_presentacion FROM presentacion pr JOIN variante v USING (id_variante)
   WHERE v.var_sku = p_sku AND pr.pre_descripcion = p_desc $$;
CREATE FUNCTION demo_variante(p_sku TEXT) RETURNS INTEGER LANGUAGE sql AS
$$ SELECT id_variante FROM variante WHERE var_sku = p_sku $$;
CREATE FUNCTION demo_oc(p_obs TEXT) RETURNS INTEGER LANGUAGE sql AS
$$ SELECT id_orden_compra FROM orden_compra WHERE oc_observacion = p_obs $$;
CREATE FUNCTION demo_dco(p_obs TEXT, p_sku TEXT) RETURNS INTEGER LANGUAGE sql AS
$$ SELECT d.id_detalle_orden_compra FROM detalle_orden_compra d
   JOIN orden_compra o USING (id_orden_compra) JOIN variante v USING (id_variante)
   WHERE o.oc_observacion = p_obs AND v.var_sku = p_sku $$;
CREATE FUNCTION demo_pedido(p_obs TEXT) RETURNS INTEGER LANGUAGE sql AS
$$ SELECT id_pedido FROM pedido WHERE ped_observacion = p_obs $$;
CREATE FUNCTION demo_linea(p_obs TEXT, p_sku TEXT, p_desc TEXT) RETURNS INTEGER LANGUAGE sql AS
$$ SELECT d.id_detalle_pedido FROM detalle_pedido d
   WHERE d.id_pedido = demo_pedido(p_obs) AND d.id_presentacion = demo_pres(p_sku, p_desc) $$;
CREATE FUNCTION demo_comprobante(p_obs TEXT) RETURNS INTEGER LANGUAGE sql AS
$$ SELECT id_comprobante_venta FROM comprobante_venta WHERE id_pedido = demo_pedido(p_obs) $$;
CREATE FUNCTION demo_punto(p_punto TEXT) RETURNS INTEGER LANGUAGE sql AS
$$ SELECT id_punto_emision::INTEGER FROM punto_emision WHERE pem_establecimiento = '001' AND pem_punto = p_punto $$;
CREATE FUNCTION demo_metodo(p_nombre TEXT) RETURNS INTEGER LANGUAGE sql AS
$$ SELECT id_metodo_pago::INTEGER FROM metodo_pago WHERE mpa_nombre = p_nombre $$;
CREATE FUNCTION demo_motivo(p_nombre TEXT) RETURNS INTEGER LANGUAGE sql AS
$$ SELECT id_motivo_devolucion::INTEGER FROM motivo_devolucion WHERE mde_nombre = p_nombre $$;
CREATE FUNCTION demo_dfa(p_identificacion TEXT) RETURNS INTEGER LANGUAGE sql AS
$$ SELECT id_datos_facturacion FROM datos_facturacion WHERE dfa_identificacion = p_identificacion AND dfa_activo $$;
CREATE FUNCTION demo_total(p_obs TEXT) RETURNS NUMERIC LANGUAGE sql AS
$$ SELECT total FROM v_pedido_totales WHERE id_pedido = demo_pedido(p_obs) $$;


-- =====================================================================
-- 1. CONFIGURACIÓN
-- =====================================================================

INSERT INTO provincia (pvc_nombre) VALUES ('Pichincha'), ('Tungurahua'), ('Guayas');
INSERT INTO ciudad (id_provincia, ciu_nombre)
SELECT id_provincia, c FROM provincia, (VALUES ('Pichincha', 'Quito'), ('Tungurahua', 'Ambato'),
                                               ('Guayas', 'Guayaquil')) AS x(p, c)
WHERE pvc_nombre = x.p;

INSERT INTO direccion (id_ciudad, dir_calle_principal, dir_numero, dir_referencia)
SELECT id_ciudad, 'Av. Principal de ejemplo', 'N1-23', 'Matriz (dato de demostración)'
FROM ciudad WHERE ciu_nombre = 'Quito';

INSERT INTO empresa (emp_ruc, emp_razon_social, emp_nombre_comercial, emp_eslogan, emp_correo,
                     emp_telefono, id_direccion_matriz, emp_dias_devolucion)
SELECT '1799999999001', 'COMERCIAL ELITE (DEMO)', 'Comercial Elite',
       'Insumos para calzado y marroquinería', 'ventas@comercialelite.ec', '022000000',
       MIN(id_direccion), 30
FROM direccion;

INSERT INTO punto_emision (pem_establecimiento, pem_punto, pem_descripcion) VALUES
    ('001', '001', 'Tienda matriz'),
    ('001', '002', 'E-commerce');

-- Personal: credenciales (usuario) + datos personales (empleado) + rol
INSERT INTO usuario (usu_correo, usu_hash_clave) VALUES
    ('admin@comercialelite.ec',   '$2b$12$hash.de.demostracion.admin'),
    ('carla@comercialelite.ec',   '$2b$12$hash.de.demostracion.carla'),
    ('diego@comercialelite.ec',   '$2b$12$hash.de.demostracion.diego'),
    ('luis@comercialelite.ec',    '$2b$12$hash.de.demostracion.luis');

INSERT INTO empleado (id_usuario, id_tipo_identificacion, epl_identificacion, epl_nombres, epl_apellidos)
SELECT demo_usuario(c), '05', ced, n, a
FROM (VALUES ('admin@comercialelite.ec', '1700000001', 'Patricia', 'Vela'),
             ('carla@comercialelite.ec', '1700000002', 'Carla',    'Ruiz'),
             ('diego@comercialelite.ec', '1700000003', 'Diego',    'Andrade'),
             ('luis@comercialelite.ec',  '1700000004', 'Luis',     'Paredes')) AS x(c, ced, n, a);

INSERT INTO usuario_rol (id_usuario, id_rol)
SELECT demo_usuario(c), r.id_rol
FROM (VALUES ('admin@comercialelite.ec', 'ADMIN'),
             ('carla@comercialelite.ec', 'VENDEDOR'),
             ('diego@comercialelite.ec', 'BODEGA'),
             ('luis@comercialelite.ec',  'COMPRAS')) AS x(c, rol)
JOIN rol r ON r.rol_codigo = x.rol;

INSERT INTO transportista (tra_nombre, tra_telefono) VALUES ('Transportes del Centro (demo)', '032000000');


-- =====================================================================
-- 2. CLIENTES
-- =====================================================================

-- María: se registra en la tienda en línea. El cliente se crea en
-- producción y su cuenta queda en el nodo e-commerce
SELECT ecommerce.fn_registrar_cuenta_web('María', 'López', 'maria.lopez@correo.ec',
                                         '$2b$12$hash.de.demostracion.maria', NULL, '190.152.0.10');
SELECT ecommerce.fn_registrar_acceso_web('maria.lopez@correo.ec', TRUE, 'sesion-demo-1', '190.152.0.10', 'Firefox');
-- Taller Pérez: cliente atendido en tienda y por WhatsApp, sin cuenta
INSERT INTO cliente (cli_nombres, cli_apellidos, cli_correo)
VALUES ('Taller Calzado Pérez', NULL, 'tallerperez@correo.ec');
-- Jorge: compra en la web como invitado
INSERT INTO cliente (cli_nombres, cli_apellidos, cli_correo)
VALUES ('Jorge', 'Cevallos', 'jorge.cevallos@correo.ec');

INSERT INTO telefono (id_cliente, tel_numero) VALUES
    (demo_cliente('María'), '0990000001'),
    (demo_cliente('Taller Calzado Pérez'), '0990000002');

INSERT INTO direccion (id_cliente, id_ciudad, dir_calle_principal, dir_numero, dir_referencia)
SELECT demo_cliente(x.n), c.id_ciudad, x.calle, x.num, x.ref
FROM (VALUES ('María',                'Calle de ejemplo 1', '12-34', 'Casa esquinera'),
             ('Taller Calzado Pérez', 'Calle de ejemplo 2', '56-78', 'Junto al parque')) AS x(n, calle, num, ref)
JOIN ciudad c ON c.ciu_nombre = 'Ambato';

INSERT INTO datos_facturacion (id_cliente, id_tipo_identificacion, dfa_identificacion, dfa_razon_social, dfa_correo, id_direccion)
SELECT demo_cliente('María'), '05', '1800000001', 'MARÍA LÓPEZ', 'maria.lopez@correo.ec', d.id_direccion
FROM direccion d WHERE d.id_cliente = demo_cliente('María');
INSERT INTO datos_facturacion (id_cliente, id_tipo_identificacion, dfa_identificacion, dfa_razon_social, dfa_correo, id_direccion)
SELECT demo_cliente('Taller Calzado Pérez'), '04', '1899999999001', 'TALLER CALZADO PÉREZ', 'tallerperez@correo.ec', d.id_direccion
FROM direccion d WHERE d.id_cliente = demo_cliente('Taller Calzado Pérez');

-- Jorge factura con su cédula: su compra supera USD 50 y el SRI no permite
-- facturar a consumidor final por encima de ese monto
INSERT INTO datos_facturacion (id_cliente, id_tipo_identificacion, dfa_identificacion, dfa_razon_social, dfa_correo)
VALUES (demo_cliente('Jorge'), '05', '1700000005', 'JORGE CEVALLOS', 'jorge.cevallos@correo.ec');

-- El taller tiene crédito aprobado hasta USD 300 (ventas a crédito + avances)
UPDATE cliente SET cli_limite_credito = 300 WHERE cli_nombres = 'Taller Calzado Pérez';


-- =====================================================================
-- 3. CATÁLOGO
-- =====================================================================

INSERT INTO categoria (cat_codigo, cat_nombre) VALUES
    ('CUE', 'Cueros y sintéticos'),
    ('QUI', 'Químicos y pegamentos');
INSERT INTO categoria (id_categoria_padre, cat_codigo, cat_nombre)
SELECT id_categoria, 'CUE-SIN', 'Sintéticos' FROM categoria WHERE cat_codigo = 'CUE';

INSERT INTO atributo (atr_nombre, atr_tipo_dato) VALUES ('Color', 'COLOR'), ('Grosor', 'NUMERO'), ('Tipo', 'TEXTO');
INSERT INTO categoria_atributo
SELECT c.id_categoria, a.id_atributo
FROM (VALUES ('CUE', 'Color'), ('CUE', 'Grosor'), ('QUI', 'Tipo')) AS x(cat, atr)
JOIN categoria c ON c.cat_codigo = x.cat
JOIN atributo  a ON a.atr_nombre = x.atr;

INSERT INTO valor_atributo (id_atributo, val_valor)
SELECT a.id_atributo, x.val
FROM (VALUES ('Color', 'Negro'), ('Color', 'Café'), ('Grosor', '1.2 mm'), ('Tipo', 'Poliuretano')) AS x(atr, val)
JOIN atributo a ON a.atr_nombre = x.atr;

INSERT INTO producto (id_categoria, id_unidad_medida, id_tarifa_iva, prd_codigo, prd_nombre, prd_uso, prd_publicado, prd_fecha_creacion)
SELECT c.id_categoria, x.um, '4', x.cod, x.nom, x.uso, TRUE, CURRENT_TIMESTAMP - INTERVAL '120 days'
FROM (VALUES ('CUE-SIN', 'm', 'SIN-NAPA', 'Sintético napa',          'Capelladas y forros'),
             ('QUI',     'u', 'PEG-PU',   'Pegamento PU de contacto', 'Pegado de suelas')) AS x(cat, um, cod, nom, uso)
JOIN categoria c ON c.cat_codigo = x.cat;

INSERT INTO variante (id_producto, var_sku, var_stock_minimo)
SELECT p.id_producto, x.sku, x.minimo
FROM (VALUES ('SIN-NAPA', 'SIN-NAPA-NEG', 40), ('SIN-NAPA', 'SIN-NAPA-CAF', 40), ('PEG-PU', 'PEG-PU-1L', 6)) AS x(prd, sku, minimo)
JOIN producto p ON p.prd_codigo = x.prd;

-- Los atributos Color y Grosor se heredan de la categoría padre CUE
INSERT INTO variante_valor (id_variante, id_atributo, id_valor_atributo)
SELECT demo_variante(x.sku), va.id_atributo, va.id_valor_atributo
FROM (VALUES ('SIN-NAPA-NEG', 'Color', 'Negro'), ('SIN-NAPA-NEG', 'Grosor', '1.2 mm'),
             ('SIN-NAPA-CAF', 'Color', 'Café'),  ('SIN-NAPA-CAF', 'Grosor', '1.2 mm'),
             ('PEG-PU-1L',    'Tipo',  'Poliuretano')) AS x(sku, atr, val)
JOIN atributo a        ON a.atr_nombre = x.atr
JOIN valor_atributo va ON va.id_atributo = a.id_atributo AND va.val_valor = x.val;

INSERT INTO presentacion (id_variante, pre_descripcion, pre_factor, pre_cantidad_minima)
SELECT demo_variante(x.sku), x.descr, x.factor, x.minimo
FROM (VALUES ('SIN-NAPA-NEG', 'Metro',      1,  0.5),
             ('SIN-NAPA-NEG', 'Rollo 30 m', 30, 1),
             ('SIN-NAPA-CAF', 'Metro',      1,  0.5),
             ('SIN-NAPA-CAF', 'Rollo 30 m', 30, 1),
             ('PEG-PU-1L',    'Unidad 1 L', 1,  1),
             ('PEG-PU-1L',    'Caja x 4',   4,  1)) AS x(sku, descr, factor, minimo);

-- Precios (sin IVA) vigentes desde hace 90 días
SELECT fn_registrar_precio(demo_pres(x.sku, x.descr), x.precio, demo_usuario('admin@comercialelite.ec'),
                           (CURRENT_TIMESTAMP - INTERVAL '90 days')::TIMESTAMP)
FROM (VALUES ('SIN-NAPA-NEG', 'Metro', 6.50), ('SIN-NAPA-NEG', 'Rollo 30 m', 180.00),
             ('SIN-NAPA-CAF', 'Metro', 6.50), ('SIN-NAPA-CAF', 'Rollo 30 m', 180.00),
             ('PEG-PU-1L', 'Unidad 1 L', 9.80), ('PEG-PU-1L', 'Caja x 4', 36.00)) AS x(sku, descr, precio);

-- Cambio de precio programado: aún no rige, el catálogo sigue mostrando 6.50
SELECT fn_registrar_precio(demo_pres('SIN-NAPA-NEG', 'Metro'), 6.90, demo_usuario('admin@comercialelite.ec'),
                           (CURRENT_TIMESTAMP + INTERVAL '10 days')::TIMESTAMP);


-- =====================================================================
-- 4. COMPRAS E INVENTARIO INICIAL
-- =====================================================================

INSERT INTO proveedor (id_tipo_identificacion, prv_identificacion, prv_razon_social, prv_correo) VALUES
    ('04', '1899999998001', 'CURTIEMBRE ANDINA (DEMO) S.A.', 'ventas@curtiembre.demo'),
    ('04', '0999999998001', 'QUÍMICA INDUSTRIAL (DEMO) CÍA. LTDA.', 'ventas@quimica.demo');

-- Inventario inicial de pegamento hace 75 días (vence en 150 días)
SELECT fn_registrar_ajuste(demo_variante('PEG-PU-1L'), 'INI', 10, 'Inventario inicial',
                           demo_usuario('diego@comercialelite.ec'), 6.80, CURRENT_DATE + 150,
                           NULL, (CURRENT_TIMESTAMP - INTERVAL '75 days')::TIMESTAMP);

-- OC 1: sintéticos. Se reciben en dos entregas.
INSERT INTO orden_compra (id_proveedor, id_usuario_crea, oc_fecha, oc_fecha_entrega_esperada, oc_observacion)
SELECT id_proveedor, demo_usuario('luis@comercialelite.ec'), CURRENT_DATE - 50, CURRENT_DATE - 40, 'OC-DEMO-1'
FROM proveedor WHERE prv_identificacion = '1899999998001';
INSERT INTO detalle_orden_compra (id_orden_compra, id_variante, dco_cantidad, dco_costo_unitario) VALUES
    (demo_oc('OC-DEMO-1'), demo_variante('SIN-NAPA-NEG'), 120, 4.10),
    (demo_oc('OC-DEMO-1'), demo_variante('SIN-NAPA-CAF'),  60, 4.10);
SELECT fn_cambiar_estado_oc(demo_oc('OC-DEMO-1'), 'EMITIDA', demo_usuario('luis@comercialelite.ec'));

-- Factura del proveedor que llega con la primera entrega
INSERT INTO comprobante_compra (id_proveedor, cco_numero, cco_fecha_emision, cco_fecha_vencimiento,
                               cco_subtotal_gravado, cco_iva, id_usuario_registra)
SELECT id_proveedor, '001-002-000004512', CURRENT_DATE - 45, CURRENT_DATE - 15, 621.00, 93.15,
       demo_usuario('luis@comercialelite.ec')
FROM proveedor WHERE prv_identificacion = '1899999998001';

-- Recepción 1 (hace 45 días): 90 m negro y 60 m café (el café llegó a 4.20, no a 4.10)
SELECT fn_recepcionar_compra(
    demo_oc('OC-DEMO-1'), demo_usuario('diego@comercialelite.ec'),
    jsonb_build_array(
        jsonb_build_object('id_detalle_orden_compra', demo_dco('OC-DEMO-1', 'SIN-NAPA-NEG'), 'cantidad', 90,
                           'costo_unitario', 4.10, 'codigo_lote', 'CA-2201'),
        jsonb_build_object('id_detalle_orden_compra', demo_dco('OC-DEMO-1', 'SIN-NAPA-CAF'), 'cantidad', 60,
                           'costo_unitario', 4.20, 'codigo_lote', 'CA-2202')),
    (SELECT id_comprobante_compra FROM comprobante_compra WHERE cco_numero = '001-002-000004512'),
    (CURRENT_TIMESTAMP - INTERVAL '45 days')::TIMESTAMP);

-- Recepción 2 (hace 20 días): los 30 m negro que faltaban
SELECT fn_recepcionar_compra(
    demo_oc('OC-DEMO-1'), demo_usuario('diego@comercialelite.ec'),
    jsonb_build_array(
        jsonb_build_object('id_detalle_orden_compra', demo_dco('OC-DEMO-1', 'SIN-NAPA-NEG'), 'cantidad', 30,
                           'costo_unitario', 4.15, 'codigo_lote', 'CA-2290')),
    NULL, (CURRENT_TIMESTAMP - INTERVAL '20 days')::TIMESTAMP);

-- Abono parcial a la factura del proveedor
INSERT INTO pago_proveedor (id_comprobante_compra, id_metodo_pago, ppr_monto, ppr_fecha, ppr_referencia, id_usuario_registra)
SELECT id_comprobante_compra, demo_metodo('Transferencia bancaria'), 400.00, CURRENT_DATE - 30, 'TRF-1001',
       demo_usuario('luis@comercialelite.ec')
FROM comprobante_compra WHERE cco_numero = '001-002-000004512';

-- OC 2: pegamento; este lote vence ANTES que el inicial, así que se vende primero (FEFO)
INSERT INTO orden_compra (id_proveedor, id_usuario_crea, oc_fecha, oc_fecha_entrega_esperada, oc_observacion)
SELECT id_proveedor, demo_usuario('luis@comercialelite.ec'), CURRENT_DATE - 15, CURRENT_DATE - 10, 'OC-DEMO-2'
FROM proveedor WHERE prv_identificacion = '0999999998001';
INSERT INTO detalle_orden_compra (id_orden_compra, id_variante, dco_cantidad, dco_costo_unitario)
VALUES (demo_oc('OC-DEMO-2'), demo_variante('PEG-PU-1L'), 12, 7.20);
SELECT fn_cambiar_estado_oc(demo_oc('OC-DEMO-2'), 'EMITIDA', demo_usuario('luis@comercialelite.ec'));
SELECT fn_recepcionar_compra(
    demo_oc('OC-DEMO-2'), demo_usuario('diego@comercialelite.ec'),
    jsonb_build_array(jsonb_build_object('id_detalle_orden_compra', demo_dco('OC-DEMO-2', 'PEG-PU-1L'),
                                         'cantidad', 12, 'fecha_vencimiento', CURRENT_DATE + 60)),
    NULL, (CURRENT_TIMESTAMP - INTERVAL '10 days')::TIMESTAMP);

-- OC 3: reposición de café emitida y aún no recibida (queda "en camino" y atrasada)
INSERT INTO orden_compra (id_proveedor, id_usuario_crea, oc_fecha, oc_fecha_entrega_esperada, oc_observacion)
SELECT id_proveedor, demo_usuario('luis@comercialelite.ec'), CURRENT_DATE - 7, CURRENT_DATE - 2, 'OC-DEMO-3'
FROM proveedor WHERE prv_identificacion = '1899999998001';
INSERT INTO detalle_orden_compra (id_orden_compra, id_variante, dco_cantidad, dco_costo_unitario)
VALUES (demo_oc('OC-DEMO-3'), demo_variante('SIN-NAPA-CAF'), 100, 4.20);
SELECT fn_cambiar_estado_oc(demo_oc('OC-DEMO-3'), 'EMITIDA', demo_usuario('luis@comercialelite.ec'));


-- =====================================================================
-- 5. VENTAS
-- =====================================================================

-- 5.1 E-commerce con cuenta (María): carrito → pedido → envío → pago en
--     pasarela → factura automática (usuario SISTEMA, punto 001-002) →
--     despacho → entrega
INSERT INTO carrito (id_cliente, car_token)
VALUES (demo_cliente('María'), '11111111-1111-1111-1111-111111111111');
INSERT INTO item_carrito (id_carrito, id_presentacion, ica_cantidad)
SELECT c.id_carrito, demo_pres(x.sku, x.descr), x.cant
FROM carrito c, (VALUES ('SIN-NAPA-NEG', 'Rollo 30 m', 1), ('PEG-PU-1L', 'Unidad 1 L', 2)) AS x(sku, descr, cant)
WHERE c.car_token = '11111111-1111-1111-1111-111111111111';

SELECT fn_crear_pedido_desde_carrito(
    (SELECT id_carrito FROM carrito WHERE car_token = '11111111-1111-1111-1111-111111111111'),
    'DEMO-WEB-MARIA');

INSERT INTO envio (id_pedido, id_direccion, env_costo, id_tarifa_iva)
SELECT demo_pedido('DEMO-WEB-MARIA'), id_direccion, 5.00, '4'
FROM direccion WHERE id_cliente = demo_cliente('María');

SELECT fn_registrar_pago(demo_pedido('DEMO-WEB-MARIA'), demo_metodo('Pago en línea (pasarela)'),
                         demo_total('DEMO-WEB-MARIA'), demo_usuario('sistema@comercialelite.local'), 'PASARELA-88231');

SELECT fn_facturar_pedido(demo_pedido('DEMO-WEB-MARIA'), demo_dfa('1800000001'), demo_punto('002'),
                          demo_usuario('sistema@comercialelite.local'));

UPDATE envio SET id_transportista = (SELECT id_transportista FROM transportista LIMIT 1), env_guia = 'GUIA-55001'
WHERE id_pedido = demo_pedido('DEMO-WEB-MARIA');
SELECT fn_cambiar_estado_pedido(demo_pedido('DEMO-WEB-MARIA'), 'DES', demo_usuario('diego@comercialelite.ec'), 'Entregado al transportista');
SELECT fn_cambiar_estado_pedido(demo_pedido('DEMO-WEB-MARIA'), 'ENT', demo_usuario('diego@comercialelite.ec'), 'Confirmado por el transportista');

-- 5.2 E-commerce como invitado (Jorge): paga por transferencia, la vendedora
--     la valida, factura con su cédula y retira en tienda (sin envío)
INSERT INTO carrito (id_cliente, car_token)
VALUES (demo_cliente('Jorge'), '22222222-2222-2222-2222-222222222222');
INSERT INTO item_carrito (id_carrito, id_presentacion, ica_cantidad)
SELECT id_carrito, demo_pres('SIN-NAPA-CAF', 'Metro'), 8
FROM carrito WHERE car_token = '22222222-2222-2222-2222-222222222222';

SELECT fn_crear_pedido_desde_carrito(
    (SELECT id_carrito FROM carrito WHERE car_token = '22222222-2222-2222-2222-222222222222'),
    'DEMO-WEB-JORGE');

SELECT fn_registrar_pago(demo_pedido('DEMO-WEB-JORGE'), demo_metodo('Transferencia bancaria'),
                         demo_total('DEMO-WEB-JORGE'), demo_usuario('sistema@comercialelite.local'),
                         'TRF-CLIENTE-77', FALSE);                         -- queda pendiente de validar
SELECT fn_confirmar_pago((SELECT id_pago FROM pago WHERE pag_referencia = 'TRF-CLIENTE-77'), TRUE,
                         demo_usuario('carla@comercialelite.ec'));
SELECT fn_facturar_pedido(demo_pedido('DEMO-WEB-JORGE'), demo_dfa('1700000005'), demo_punto('002'),
                          demo_usuario('sistema@comercialelite.local'));
SELECT fn_cambiar_estado_pedido(demo_pedido('DEMO-WEB-JORGE'), 'ENT', demo_usuario('carla@comercialelite.ec'), 'Retiro en tienda');

-- 5.3 Venta física en tienda (Taller Pérez, atendido por Carla).
--     75 m de negro: el kárdex los toma 60 m del lote más antiguo y 15 del siguiente.
SELECT fn_crear_pedido(
    demo_cliente('Taller Calzado Pérez'), 'TDA',
    jsonb_build_array(
        jsonb_build_object('id_presentacion', demo_pres('SIN-NAPA-NEG', 'Metro'), 'cantidad', 75, 'descuento', 10.00),
        jsonb_build_object('id_presentacion', demo_pres('PEG-PU-1L', 'Caja x 4'), 'cantidad', 1)),
    demo_usuario('carla@comercialelite.ec'), 'DEMO-TDA-PEREZ');
SELECT fn_registrar_pago(demo_pedido('DEMO-TDA-PEREZ'), demo_metodo('Efectivo'),
                         demo_total('DEMO-TDA-PEREZ'), demo_usuario('carla@comercialelite.ec'));
SELECT fn_facturar_pedido(demo_pedido('DEMO-TDA-PEREZ'), demo_dfa('1899999999001'), demo_punto('001'),
                          demo_usuario('carla@comercialelite.ec'));
SELECT fn_cambiar_estado_pedido(demo_pedido('DEMO-TDA-PEREZ'), 'ENT', demo_usuario('carla@comercialelite.ec'), 'Entregado en mostrador');

-- 5.4 Venta por WhatsApp (mismo taller, segunda compra) con envío
SELECT fn_crear_pedido(
    demo_cliente('Taller Calzado Pérez'), 'WSP',
    jsonb_build_array(jsonb_build_object('id_presentacion', demo_pres('SIN-NAPA-CAF', 'Rollo 30 m'), 'cantidad', 1)),
    demo_usuario('carla@comercialelite.ec'), 'DEMO-WSP-PEREZ');
INSERT INTO envio (id_pedido, id_direccion, env_costo, id_tarifa_iva)
SELECT demo_pedido('DEMO-WSP-PEREZ'), id_direccion, 4.00, '4'
FROM direccion WHERE id_cliente = demo_cliente('Taller Calzado Pérez');
SELECT fn_registrar_pago(demo_pedido('DEMO-WSP-PEREZ'), demo_metodo('Transferencia bancaria'),
                         demo_total('DEMO-WSP-PEREZ'), demo_usuario('carla@comercialelite.ec'), 'TRF-TALLER-12');
SELECT fn_facturar_pedido(demo_pedido('DEMO-WSP-PEREZ'), demo_dfa('1899999999001'), demo_punto('001'),
                          demo_usuario('carla@comercialelite.ec'));
SELECT fn_cambiar_estado_pedido(demo_pedido('DEMO-WSP-PEREZ'), 'DES', demo_usuario('diego@comercialelite.ec'));
SELECT fn_cambiar_estado_pedido(demo_pedido('DEMO-WSP-PEREZ'), 'ENT', demo_usuario('diego@comercialelite.ec'));

-- 5.5 Negociación por WhatsApp: el cliente pide 2 pegamentos y Carla le
--     deja cada línea en un valor final; la base calcula el descuento.
--     Lista: 2 x 9.80 = 19.60 + IVA = 22.54  ->  pactado: 20.00 con IVA
SELECT fn_crear_pedido(
    demo_cliente('Taller Calzado Pérez'), 'WSP',
    jsonb_build_array(jsonb_build_object('id_presentacion', demo_pres('PEG-PU-1L', 'Unidad 1 L'), 'cantidad', 2,
                                         'valor_final', 20.00)),
    demo_usuario('carla@comercialelite.ec'), 'DEMO-NEG-WSP');
SELECT fn_registrar_pago(demo_pedido('DEMO-NEG-WSP'), demo_metodo('Transferencia bancaria'),
                         demo_total('DEMO-NEG-WSP'), demo_usuario('carla@comercialelite.ec'), 'TRF-NEG-01');
SELECT fn_facturar_pedido(demo_pedido('DEMO-NEG-WSP'), demo_dfa('1899999999001'), demo_punto('001'),
                          demo_usuario('carla@comercialelite.ec'));

-- 5.6 Negociación en tienda del total: "le dejo todo en 45 dólares".
--     Lista: 5 m sintético (37.38 con IVA) + 1 pegamento (11.27) = 48.65
SELECT fn_crear_pedido(
    demo_cliente('Taller Calzado Pérez'), 'TDA',
    jsonb_build_array(
        jsonb_build_object('id_presentacion', demo_pres('SIN-NAPA-NEG', 'Metro'), 'cantidad', 5),
        jsonb_build_object('id_presentacion', demo_pres('PEG-PU-1L', 'Unidad 1 L'), 'cantidad', 1)),
    demo_usuario('carla@comercialelite.ec'), 'DEMO-NEG-TDA');
SELECT fn_negociar_pedido(demo_pedido('DEMO-NEG-TDA'), 45.00, demo_usuario('carla@comercialelite.ec'));
SELECT fn_registrar_pago(demo_pedido('DEMO-NEG-TDA'), demo_metodo('Efectivo'),
                         demo_total('DEMO-NEG-TDA'), demo_usuario('carla@comercialelite.ec'));
SELECT fn_facturar_pedido(demo_pedido('DEMO-NEG-TDA'), demo_dfa('1899999999001'), demo_punto('001'),
                          demo_usuario('carla@comercialelite.ec'));

-- 5.7 Oferta preestablecida: la administradora publica el pegamento PU con
--     10 % de descuento por 15 días. María lo compra en la web: la oferta
--     se aplica sola al confirmar el carrito (el carrito no lleva descuentos)
SELECT fn_registrar_oferta((SELECT id_producto FROM producto WHERE prd_codigo = 'PEG-PU'), 10,
                           demo_usuario('admin@comercialelite.ec'), LOCALTIMESTAMP - INTERVAL '1 hour',
                           LOCALTIMESTAMP + INTERVAL '15 days', 'Pegamento PU: 10 % por quincena');
INSERT INTO carrito (id_cliente, car_token)
VALUES (demo_cliente('María'), '33333333-3333-3333-3333-333333333333');
INSERT INTO item_carrito (id_carrito, id_presentacion, ica_cantidad)
SELECT id_carrito, demo_pres('PEG-PU-1L', 'Unidad 1 L'), 3
FROM carrito WHERE car_token = '33333333-3333-3333-3333-333333333333';
SELECT ecommerce.fn_crear_pedido_desde_carrito(
    (SELECT id_carrito FROM carrito WHERE car_token = '33333333-3333-3333-3333-333333333333'),
    'DEMO-WEB-OFERTA', 'sesion-demo-1', '190.152.0.10');
SELECT fn_registrar_pago(demo_pedido('DEMO-WEB-OFERTA'), demo_metodo('Pago en línea (pasarela)'),
                         demo_total('DEMO-WEB-OFERTA'), demo_usuario('sistema@comercialelite.local'), 'PASARELA-90412');
SELECT fn_facturar_pedido(demo_pedido('DEMO-WEB-OFERTA'), demo_dfa('1800000001'), demo_punto('002'),
                          demo_usuario('sistema@comercialelite.local'));

-- 5.8 Venta en tienda con NOTA DE VENTA (no va al SRI): un cliente de paso
--     lleva 2 m de sintético café; Carla usa la nota 351 de su talonario
SELECT fn_crear_pedido(demo_cliente('CONSUMIDOR FINAL'), 'TDA',
    jsonb_build_array(jsonb_build_object('id_presentacion', demo_pres('SIN-NAPA-CAF', 'Metro'), 'cantidad', 2)),
    demo_usuario('carla@comercialelite.ec'), 'DEMO-NOTA-VENTA');
SELECT fn_registrar_pago(demo_pedido('DEMO-NOTA-VENTA'), demo_metodo('Efectivo'),
                         demo_total('DEMO-NOTA-VENTA'), demo_usuario('carla@comercialelite.ec'));
SELECT fn_emitir_nota_venta(demo_pedido('DEMO-NOTA-VENTA'), demo_punto('001'),
                            demo_usuario('carla@comercialelite.ec'), 351);


-- =====================================================================
-- 6. DEVOLUCIONES (política de la empresa: 30 días)
-- =====================================================================

-- María devuelve 1 pegamento en buen estado: vuelve a su lote de origen y se le reembolsa
SELECT fn_emitir_nota_credito(
    demo_comprobante('DEMO-WEB-MARIA'), demo_motivo('Cliente no satisfecho'), demo_usuario('admin@comercialelite.ec'),
    demo_punto('002'),
    jsonb_build_array(jsonb_build_object('id_detalle_pedido', demo_linea('DEMO-WEB-MARIA', 'PEG-PU-1L', 'Unidad 1 L'),
                                         'cantidad', 1, 'reingresa', TRUE)),
    'Devolución dentro del plazo');
INSERT INTO reembolso (id_nota_credito, id_metodo_pago, ree_monto, ree_referencia, id_usuario_registra)
SELECT n.id_nota_credito, demo_metodo('Pago en línea (pasarela)'), n.total, 'REV-88231', demo_usuario('admin@comercialelite.ec')
FROM v_nota_credito n WHERE n.id_comprobante_venta = demo_comprobante('DEMO-WEB-MARIA');

-- El taller devuelve 5 m de negro con fallas: se acreditan pero NO reingresan al stock
SELECT fn_emitir_nota_credito(
    demo_comprobante('DEMO-TDA-PEREZ'), demo_motivo('Producto defectuoso'), demo_usuario('admin@comercialelite.ec'),
    demo_punto('001'),
    jsonb_build_array(jsonb_build_object('id_detalle_pedido', demo_linea('DEMO-TDA-PEREZ', 'SIN-NAPA-NEG', 'Metro'),
                                         'cantidad', 5, 'reingresa', FALSE)),
    'Material con fallas de fábrica');


-- =====================================================================
-- 7. VENTA A CRÉDITO, AVANCE DE DINERO Y ABONOS
-- =====================================================================

-- El taller lleva 2 cajas de pegamento: paga USD 20 y el resto queda a
-- crédito a 30 días. La factura se emite en el momento: la entrega del
-- bien obliga a facturar aunque todavía no se haya cobrado todo.
SELECT fn_crear_pedido(
    demo_cliente('Taller Calzado Pérez'), 'TDA',
    jsonb_build_array(jsonb_build_object('id_presentacion', demo_pres('PEG-PU-1L', 'Caja x 4'), 'cantidad', 2)),
    demo_usuario('carla@comercialelite.ec'), 'DEMO-CREDITO-PEREZ');
SELECT fn_registrar_pago(demo_pedido('DEMO-CREDITO-PEREZ'), demo_metodo('Efectivo'), 20.00,
                         demo_usuario('carla@comercialelite.ec'));
SELECT fn_facturar_a_credito(demo_pedido('DEMO-CREDITO-PEREZ'), 30, demo_dfa('1899999999001'), demo_punto('001'),
                             demo_usuario('admin@comercialelite.ec'));

-- Necesita USD 15 para el pasaje de regreso: avance en efectivo a 15 días.
-- No va en la factura; queda como deuda del cliente sobre esa compra.
SELECT fn_registrar_avance(demo_pedido('DEMO-CREDITO-PEREZ'), 15.00, 'Pasaje de regreso a Ambato',
                           demo_metodo('Efectivo'), 15, demo_usuario('admin@comercialelite.ec'),
                           (SELECT id_motivo_avance FROM motivo_avance WHERE mav_nombre = 'Pasaje'));

-- Abona USD 40 por transferencia: se aplica primero a lo que vence antes
-- (el avance) y el resto al crédito
SELECT fn_abonar_cliente(demo_cliente('Taller Calzado Pérez'), 40.00, demo_metodo('Transferencia bancaria'),
                         demo_usuario('carla@comercialelite.ec'), 'TRF-ABONO-01');


-- =====================================================================
-- 8. CUERO POR BANDAS: PRECIO POR BANDA O POR PIE
-- =====================================================================

-- El cuero se lleva en pie² y se vende por pieza: cada banda es un lote con
-- su área medida, y una línea de venta sale de una sola banda.
INSERT INTO producto (id_categoria, id_unidad_medida, id_tarifa_iva, prd_codigo, prd_nombre, prd_uso,
                      prd_publicado, prd_venta_por_pieza, prd_fecha_creacion)
SELECT id_categoria, 'pie2', '4', 'CUE-NAPA', 'Cuero napa', 'Capelladas de calzado', TRUE, TRUE,
       CURRENT_TIMESTAMP - INTERVAL '60 days'
FROM categoria WHERE cat_codigo = 'CUE';
INSERT INTO variante (id_producto, var_sku, var_stock_minimo)
SELECT id_producto, 'CUE-NAPA-NEG', 20 FROM producto WHERE prd_codigo = 'CUE-NAPA';
INSERT INTO variante_valor (id_variante, id_atributo, id_valor_atributo)
SELECT demo_variante('CUE-NAPA-NEG'), va.id_atributo, va.id_valor_atributo
FROM valor_atributo va JOIN atributo a USING (id_atributo)
WHERE (a.atr_nombre, va.val_valor) IN (('Color', 'Negro'), ('Grosor', '1.2 mm'));

-- Dos precios por pie²: al detal, y precio de banda (más barato) desde 10 pie².
-- El criterio del vendedor es escoger cuál aplica; queda grabado en la venta.
INSERT INTO presentacion (id_variante, pre_descripcion, pre_factor, pre_cantidad_minima)
SELECT demo_variante('CUE-NAPA-NEG'), x.d, 1, x.m
FROM (VALUES ('Pie² al detal', 1), ('Pie² precio banda', 10)) AS x(d, m);
SELECT fn_registrar_precio(demo_pres('CUE-NAPA-NEG', x.d), x.p, demo_usuario('admin@comercialelite.ec'),
                           (CURRENT_TIMESTAMP - INTERVAL '60 days')::TIMESTAMP)
FROM (VALUES ('Pie² al detal', 3.20), ('Pie² precio banda', 2.80)) AS x(d, p);

-- Compra de 3 bandas (69.50 pie²): una línea de recepción por banda, con el
-- área sellada por la curtiembre
INSERT INTO orden_compra (id_proveedor, id_usuario_crea, oc_fecha, oc_fecha_entrega_esperada, oc_observacion)
SELECT id_proveedor, demo_usuario('luis@comercialelite.ec'), CURRENT_DATE - 35, CURRENT_DATE - 30, 'OC-DEMO-4'
FROM proveedor WHERE prv_identificacion = '1899999998001';
INSERT INTO detalle_orden_compra (id_orden_compra, id_variante, dco_cantidad, dco_costo_unitario)
VALUES (demo_oc('OC-DEMO-4'), demo_variante('CUE-NAPA-NEG'), 69.50, 2.10);
SELECT fn_cambiar_estado_oc(demo_oc('OC-DEMO-4'), 'EMITIDA', demo_usuario('luis@comercialelite.ec'));
SELECT fn_recepcionar_compra(
    demo_oc('OC-DEMO-4'), demo_usuario('diego@comercialelite.ec'),
    (SELECT jsonb_agg(jsonb_build_object('id_detalle_orden_compra', demo_dco('OC-DEMO-4', 'CUE-NAPA-NEG'),
                                         'cantidad', x.area, 'codigo_lote', x.banda) ORDER BY x.banda)
     FROM (VALUES ('BANDA-001', 23.10), ('BANDA-002', 22.40), ('BANDA-003', 24.00)) AS x(banda, area)),
    NULL, (CURRENT_TIMESTAMP - INTERVAL '30 days')::TIMESTAMP);

-- El taller pide unos 11.5 pie². Carla decide venderle media banda a precio
-- de banda y la corta de BANDA-001: la otra mitad queda como paquete.
SELECT fn_crear_pedido(
    demo_cliente('Taller Calzado Pérez'), 'TDA',
    jsonb_build_array(jsonb_build_object('id_presentacion', demo_pres('CUE-NAPA-NEG', 'Pie² precio banda'), 'cantidad', 11.55)),
    demo_usuario('carla@comercialelite.ec'), 'DEMO-CUERO-1');
SELECT fn_registrar_pago(demo_pedido('DEMO-CUERO-1'), demo_metodo('Efectivo'), demo_total('DEMO-CUERO-1'),
                         demo_usuario('carla@comercialelite.ec'));
SELECT fn_facturar_pedido(demo_pedido('DEMO-CUERO-1'), demo_dfa('1899999999001'), demo_punto('001'),
                          demo_usuario('carla@comercialelite.ec'),
                          jsonb_build_array(jsonb_build_object(
                              'id_detalle_pedido', demo_linea('DEMO-CUERO-1', 'CUE-NAPA-NEG', 'Pie² precio banda'),
                              'id_lote', (SELECT id_lote FROM lote WHERE lot_codigo_proveedor = 'BANDA-001'))));

-- Carla corta BANDA-002 en dos medias bandas para tenerlas empacadas
SELECT fn_fraccionar_lote((SELECT id_lote FROM lote WHERE lot_codigo_proveedor = 'BANDA-002'),
                          '[11.20, 11.20]', demo_usuario('carla@comercialelite.ec'), 'Dos medias bandas empacadas');

-- María pide 11 pie² al detal por la web: sin elección del vendedor, el
-- sistema toma la pieza más pequeña que alcanza (un paquete de 11.20)
SELECT fn_crear_pedido(demo_cliente('María'), 'WEB',
    jsonb_build_array(jsonb_build_object('id_presentacion', demo_pres('CUE-NAPA-NEG', 'Pie² al detal'), 'cantidad', 11)),
    NULL, 'DEMO-CUERO-2');
SELECT fn_registrar_pago(demo_pedido('DEMO-CUERO-2'), demo_metodo('Pago en línea (pasarela)'), demo_total('DEMO-CUERO-2'),
                         demo_usuario('sistema@comercialelite.local'), 'PASARELA-90412');
SELECT fn_facturar_pedido(demo_pedido('DEMO-CUERO-2'), demo_dfa('1800000001'), demo_punto('002'),
                          demo_usuario('sistema@comercialelite.local'));


-- =====================================================================
-- 9. AJUSTES, MERMA Y DEVOLUCIÓN A PROVEEDOR
-- =====================================================================

SELECT fn_registrar_ajuste(demo_variante('SIN-NAPA-CAF'), 'AJN', 1, 'Diferencia en conteo físico',
                           demo_usuario('diego@comercialelite.ec'));
SELECT fn_registrar_ajuste(demo_variante('PEG-PU-1L'), 'MER', 1, 'Envase roto en bodega',
                           demo_usuario('diego@comercialelite.ec'));
-- 2 m del lote CA-2290 con fallas de tintura vuelven al proveedor
SELECT fn_devolver_a_proveedor((SELECT id_lote FROM lote WHERE lot_codigo_proveedor = 'CA-2290'), 2,
                               'Fallas de tintura', demo_usuario('luis@comercialelite.ec'));

-- La segunda entrega de la OC-DEMO-1 (30 m, lote CA-2290) llegó sin factura.
-- La factura llega después: se registra y se asocia a esa recepción.
INSERT INTO comprobante_compra (id_proveedor, cco_numero, cco_fecha_emision, cco_fecha_vencimiento,
                               cco_subtotal_gravado, cco_iva, id_usuario_registra)
SELECT id_proveedor, '001-002-000004601', CURRENT_DATE - 19, CURRENT_DATE + 11, 124.50, 18.68,
       demo_usuario('luis@comercialelite.ec')
FROM proveedor WHERE prv_identificacion = '1899999998001';
SELECT fn_asociar_comprobante_compra(
    (SELECT dm.id_movimiento FROM detalle_movimiento dm JOIN lote l USING (id_lote)
     JOIN movimiento_inventario m USING (id_movimiento)
     WHERE l.lot_codigo_proveedor = 'CA-2290' AND m.id_tipo_movimiento = 'COM'),
    (SELECT id_comprobante_compra FROM comprobante_compra WHERE cco_numero = '001-002-000004601'),
    demo_usuario('luis@comercialelite.ec'));

-- Por los 2 m devueltos, el proveedor emite su nota de crédito (2 x 4.15 + IVA)
SELECT fn_registrar_nc_proveedor(
    (SELECT id_comprobante_compra FROM comprobante_compra WHERE cco_numero = '001-002-000004601'),
    '001-002-000000210', CURRENT_DATE, 0, 8.30, 1.25, 'Devolución de 2 m con fallas de tintura',
    demo_usuario('luis@comercialelite.ec'));

-- Compras menores que no vienen con factura: una ferretería RIMPE entrega
-- nota de venta (sin IVA) y un cargador cobra con un recibo simple
INSERT INTO proveedor (id_tipo_identificacion, prv_identificacion, prv_razon_social)
VALUES ('04', '1712345678001', 'FERRETERÍA DE BARRIO (DEMO, RIMPE)');
SELECT fn_registrar_comprobante_compra(
    (SELECT id_proveedor FROM proveedor WHERE prv_identificacion = '1712345678001'), '02', '001-001-000000123',
    CURRENT_DATE, CURRENT_DATE + 15, 18.00, 0, 0, demo_usuario('luis@comercialelite.ec'));
SELECT fn_registrar_comprobante_compra(
    (SELECT id_proveedor FROM proveedor WHERE prv_identificacion = '1712345678001'), '00', 'REC-0007',
    CURRENT_DATE, CURRENT_DATE, 25.00, 0, 0, demo_usuario('luis@comercialelite.ec'));


-- =====================================================================
-- 10. PRUEBAS QUE DEBEN SER RECHAZADAS
--    Cada bloque intenta una operación indebida. Si la base la rechaza,
--    se muestra "OK" con el mensaje; si no, se muestra "FALLA".
-- =====================================================================

DO $$
DECLARE
    v_ok INTEGER := 0;
    v_falla INTEGER := 0;
BEGIN
    -- 10.1 Una vendedora no puede autorizar notas de crédito
    BEGIN
        PERFORM fn_emitir_nota_credito(demo_comprobante('DEMO-TDA-PEREZ'), demo_motivo('Cliente no satisfecho'),
                                       demo_usuario('carla@comercialelite.ec'), demo_punto('001'),
                                       jsonb_build_array(jsonb_build_object('id_detalle_pedido',
                                           demo_linea('DEMO-TDA-PEREZ', 'PEG-PU-1L', 'Caja x 4'), 'cantidad', 1)));
        RAISE NOTICE 'FALLA 10.1: la vendedora emitió una nota de crédito'; v_falla := v_falla + 1;
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK 10.1 permiso por rol      → %', SQLERRM; v_ok := v_ok + 1;
    END;

    -- 10.2 No se vende más de lo disponible
    BEGIN
        PERFORM fn_crear_pedido(demo_cliente('Taller Calzado Pérez'), 'TDA',
                                jsonb_build_array(jsonb_build_object('id_presentacion', demo_pres('SIN-NAPA-NEG', 'Metro'), 'cantidad', 500)),
                                demo_usuario('carla@comercialelite.ec'));
        RAISE NOTICE 'FALLA 10.2: se reservó más stock del existente'; v_falla := v_falla + 1;
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK 10.2 stock disponible     → %', SQLERRM; v_ok := v_ok + 1;
    END;

    -- 10.3 No se factura un pedido que no está pagado
    BEGIN
        PERFORM fn_facturar_pedido(
            fn_crear_pedido(demo_cliente('Taller Calzado Pérez'), 'TDA',
                            jsonb_build_array(jsonb_build_object('id_presentacion', demo_pres('PEG-PU-1L', 'Unidad 1 L'), 'cantidad', 1)),
                            demo_usuario('carla@comercialelite.ec')),
            demo_dfa('1899999999001'), demo_punto('001'), demo_usuario('carla@comercialelite.ec'));
        RAISE NOTICE 'FALLA 10.3: se facturó un pedido sin pago'; v_falla := v_falla + 1;
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK 10.3 factura sin pago     → %', SQLERRM; v_ok := v_ok + 1;
    END;

    -- 10.4 El kárdex no se edita
    BEGIN
        UPDATE detalle_movimiento SET dmo_cantidad = dmo_cantidad + 1
        WHERE id_detalle_movimiento = (SELECT MIN(id_detalle_movimiento) FROM detalle_movimiento);
        RAISE NOTICE 'FALLA 10.4: se modificó el kárdex'; v_falla := v_falla + 1;
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK 10.4 kárdex inmutable     → %', SQLERRM; v_ok := v_ok + 1;
    END;

    -- 10.5 No se devuelve más de lo facturado (María compró 1 rollo)
    BEGIN
        PERFORM fn_emitir_nota_credito(demo_comprobante('DEMO-WEB-MARIA'), demo_motivo('Cliente no satisfecho'),
                                       demo_usuario('admin@comercialelite.ec'), demo_punto('002'),
                                       jsonb_build_array(jsonb_build_object('id_detalle_pedido',
                                           demo_linea('DEMO-WEB-MARIA', 'SIN-NAPA-NEG', 'Rollo 30 m'), 'cantidad', 2)));
        RAISE NOTICE 'FALLA 10.5: se devolvió más de lo facturado'; v_falla := v_falla + 1;
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK 10.5 tope de devolución   → %', SQLERRM; v_ok := v_ok + 1;
    END;

    -- 10.6 Un pedido facturado no se modifica
    BEGIN
        UPDATE detalle_pedido SET dpe_precio_unitario = 1
        WHERE id_detalle_pedido = demo_linea('DEMO-TDA-PEREZ', 'SIN-NAPA-NEG', 'Metro');
        RAISE NOTICE 'FALLA 10.6: se modificó un pedido facturado'; v_falla := v_falla + 1;
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK 10.6 pedido congelado     → %', SQLERRM; v_ok := v_ok + 1;
    END;

    -- 10.7 No se recibe más de lo pedido en la OC
    BEGIN
        PERFORM fn_recepcionar_compra(demo_oc('OC-DEMO-3'), demo_usuario('diego@comercialelite.ec'),
                                      jsonb_build_array(jsonb_build_object('id_detalle_orden_compra',
                                          demo_dco('OC-DEMO-3', 'SIN-NAPA-CAF'), 'cantidad', 150)));
        RAISE NOTICE 'FALLA 10.7: se recibió más de lo pedido'; v_falla := v_falla + 1;
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK 10.7 recepción vs OC      → %', SQLERRM; v_ok := v_ok + 1;
    END;

    -- 10.8 No se paga al proveedor más que el saldo de su factura
    BEGIN
        INSERT INTO pago_proveedor (id_comprobante_compra, id_metodo_pago, ppr_monto, id_usuario_registra)
        SELECT id_comprobante_compra, demo_metodo('Transferencia bancaria'), 1000, demo_usuario('luis@comercialelite.ec')
        FROM comprobante_compra WHERE cco_numero = '001-002-000004512';
        RAISE NOTICE 'FALLA 10.8: se pagó de más al proveedor'; v_falla := v_falla + 1;
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK 10.8 saldo por pagar      → %', SQLERRM; v_ok := v_ok + 1;
    END;

    -- 10.9 El estado de un pedido no retrocede
    BEGIN
        INSERT INTO historial_estado_pedido (id_pedido, id_estado_pedido) VALUES (demo_pedido('DEMO-WEB-MARIA'), 'PEN');
        RAISE NOTICE 'FALLA 10.9: se retrocedió el estado de un pedido'; v_falla := v_falla + 1;
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK 10.9 flujo de estados     → %', SQLERRM; v_ok := v_ok + 1;
    END;

    -- 10.10 Una venta web no lleva vendedor
    BEGIN
        INSERT INTO pedido (id_cliente, id_canal_venta, id_empleado_vendedor)
        VALUES (demo_cliente('María'), 'WEB', demo_usuario('carla@comercialelite.ec'));
        RAISE NOTICE 'FALLA 10.10: venta web con vendedor'; v_falla := v_falla + 1;
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK 10.10 canal y vendedor    → %', SQLERRM; v_ok := v_ok + 1;
    END;

    -- 10.11 Los datos de una factura emitida no se editan
    BEGIN
        UPDATE datos_facturacion SET dfa_razon_social = 'OTRO NOMBRE' WHERE dfa_identificacion = '1800000001';
        RAISE NOTICE 'FALLA 10.11: se editaron datos ya facturados'; v_falla := v_falla + 1;
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK 10.11 datos facturados    → %', SQLERRM; v_ok := v_ok + 1;
    END;

    -- 10.12 Un atributo que no corresponde a la categoría
    BEGIN
        INSERT INTO variante_valor (id_variante, id_atributo, id_valor_atributo)
        SELECT demo_variante('PEG-PU-1L'), va.id_atributo, va.id_valor_atributo
        FROM valor_atributo va JOIN atributo a USING (id_atributo)
        WHERE a.atr_nombre = 'Color' AND va.val_valor = 'Negro';
        RAISE NOTICE 'FALLA 10.12: atributo fuera de su categoría'; v_falla := v_falla + 1;
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'OK 10.12 atributo/categoría  → %', SQLERRM; v_ok := v_ok + 1;
    END;

    RAISE NOTICE '== Pruebas de rechazo: % OK, % FALLA ==', v_ok, v_falla;
END $$;


-- =====================================================================
-- 11. RESULTADOS
-- =====================================================================

-- Kárdex del sintético negro: entradas, salidas y saldo acumulado
SELECT fecha::DATE, tipo, documento, id_lote, costo_unitario, entrada, salida, saldo, saldo_valorizado
FROM v_kardex WHERE var_sku = 'SIN-NAPA-NEG' ORDER BY fecha, id_lote;

-- Lotes con saldo: antigüedad (tiempo en inventario) y vencimiento
SELECT v.var_sku, l.id_lote, l.fecha_ingreso::DATE, l.dias_en_inventario, l.lot_fecha_vencimiento,
       l.entradas, l.salidas, l.saldo, l.lot_costo_unitario
FROM v_lote_saldo l JOIN variante v USING (id_variante)
ORDER BY v.var_sku, l.id_lote;

-- Stock por variante: físico, reservado, disponible, en camino y alerta de compra
SELECT var_sku, unidad, stock_fisico, reservado, disponible, en_camino, stock_minimo, requiere_compra,
       valor_inventario, antiguedad_promedio_dias, antiguedad_maxima_dias
FROM v_stock_variante ORDER BY var_sku;

-- Facturas: número SRI, canal y quién vendió
SELECT tipo_comprobante, numero, canal, vendedor, razon_social, subtotal_gravado, costo_envio, iva, total, estado_sri
FROM v_comprobante_venta ORDER BY tipo_comprobante, numero;

-- Notas de crédito
SELECT numero, comprobante_venta, motivo, subtotal, iva, total, autorizada_por FROM v_nota_credito ORDER BY numero;

-- Ventas por canal: física vs e-commerce
SELECT * FROM v_ventas_por_canal ORDER BY fecha, canal;

-- Frecuencia de clientes
SELECT cliente, compras, dias_sin_comprar, monto_comprado, monto_devuelto, monto_neto,
       canal_preferido, segmento
FROM v_frecuencia_cliente ORDER BY compras DESC, cliente;

-- Compras: estado de recepción de cada OC y cuentas por pagar
SELECT id_orden_compra, proveedor, oc_estado, estado_recepcion, atrasada, valor_pactado FROM v_orden_compra_estado ORDER BY 1;
SELECT proveedor, tipo_comprobante, numero, total, notas_credito, pagado, saldo, vencida FROM v_cuentas_por_pagar ORDER BY proveedor, numero;

-- Proveedores: cuánto se les debe según facturas y mercadería ingresada
SELECT proveedor, mercaderia_recibida, mercaderia_devuelta, facturado, notas_credito, pagado,
       saldo_facturas, por_facturar_estimado, deuda_estimada
FROM v_estado_cuenta_proveedor ORDER BY proveedor;

-- Control del valor de ingreso: factura del proveedor contra lo recibido
SELECT proveedor, numero, subtotal_facturado, valor_recibido, diferencia, estado
FROM v_conciliacion_compra ORDER BY numero;

-- Historial de costos de compra (tabla o serie para una gráfica)
SELECT fecha::DATE, var_sku, proveedor, comprobante_compra, cantidad, costo_unitario, costo_pactado,
       dif_vs_pactado_pct, costo_anterior, variacion_pct
FROM v_historial_costo_compra ORDER BY var_sku, fecha;

-- Historial de precios de venta
SELECT var_sku, presentacion, precio, precio_con_iva, vigente_desde::DATE, vigente_hasta::DATE, programado, vigente
FROM v_historial_precio_venta WHERE var_sku = 'SIN-NAPA-NEG' ORDER BY presentacion, vigente_desde;

-- Cuentas por cobrar y estado de cuenta del cliente
SELECT cliente, comprobante_venta, tipo, concepto, monto, abonado, saldo, vencimiento, estado
FROM v_cuentas_por_cobrar ORDER BY id_cuenta_por_cobrar;
SELECT cliente, limite_credito, saldo_credito, saldo_avances, deuda_total, credito_disponible
FROM v_estado_cuenta_cliente WHERE deuda_total > 0 OR limite_credito > 0;

-- Cuero: piezas (bandas y paquetes) con su área y antigüedad
SELECT l.lot_codigo_proveedor AS pieza, o.lot_codigo_proveedor AS cortada_de, l.saldo AS pie2,
       l.fecha_ingreso::DATE, l.dias_en_inventario
FROM v_lote_saldo l
JOIN variante v ON v.id_variante = l.id_variante
LEFT JOIN lote o ON o.id_lote = l.id_lote_origen
WHERE v.var_sku = 'CUE-NAPA-NEG' ORDER BY 1;

-- Ventas de cuero por presentación (precio de banda o al detal) y vendedor
SELECT vendedor, presentacion, cantidad, subtotal FROM v_ventas_por_presentacion
WHERE var_sku = 'CUE-NAPA-NEG' ORDER BY vendedor;

-- Negociaciones de precio: lista contra valor final, % y quién autorizó
SELECT canal, cliente, autorizado_por, var_sku, cantidad, valor_lista_con_iva, valor_final_con_iva,
       descuento_oferta, descuento, pct_descuento, comprobante_venta
FROM v_negociaciones ORDER BY id_pedido, var_sku;

-- Ofertas: estado, uso y descuento otorgado
SELECT prd_codigo, porcentaje, descripcion, estado, lineas_vendidas, descuento_otorgado, registrada_por
FROM v_oferta ORDER BY id_oferta;

-- Buscar cuánto debe un cliente (por nombre, cédula/RUC o teléfono)
SELECT cliente, identificaciones, telefonos, deuda_total, deuda_vencida, proximo_vencimiento
FROM fn_buscar_deuda_cliente('1899999999001');

-- Estado de cuenta detallado ("cuentas claras")
SELECT fecha::DATE, detalle, cargo, abono, saldo
FROM v_estado_cuenta_movimientos WHERE cliente = 'Taller Calzado Pérez' ORDER BY fecha;

-- Cola del SRI: comprobantes aún sin autorización
SELECT tipo, numero, estado, minutos_pendiente FROM v_cola_sri ORDER BY emitido;

-- Bitácora del sistema interno (últimos eventos)
SELECT lev_fechahora::TIME(0) AS hora, lev_nivel AS nivel, lev_origen AS origen, lev_evento AS evento, lev_mensaje AS mensaje
FROM log_evento ORDER BY id_log_evento DESC LIMIT 12;

-- Auditoría: cambios por tabla y quién los hizo
SELECT a.aud_tabla AS tabla, a.aud_operacion AS op, COALESCE(u.usu_correo, '(proceso)') AS usuario, COUNT(*) AS cambios
FROM auditoria a LEFT JOIN usuario u ON u.id_usuario = a.id_usuario
GROUP BY 1, 2, 3 ORDER BY 1, 2, 3;

-- NODO E-COMMERCE ------------------------------------------------------
-- Catálogo publicado (precio, oferta y disponibilidad)
SELECT var_sku, presentacion, precio_con_iva, pct_oferta, precio_final_con_iva, disponible
FROM ecommerce.v_catalogo_web ORDER BY var_sku, presentacion;

-- Cuentas web y "mis pedidos"
SELECT correo, cliente, compras, segmento, ultimo_acceso IS NOT NULL AS entro FROM ecommerce.v_cuenta_web;
SELECT id_pedido, fecha::DATE, estado_nombre, total, comprobante_venta FROM ecommerce.v_pedido_web ORDER BY id_pedido;

-- Bitácora del e-commerce
SELECT lew_evento AS evento, lew_mensaje AS mensaje, lew_ip AS ip FROM ecommerce.log_evento_web ORDER BY id_log_evento_web;


-- Limpieza de utilidades de la demo
DROP FUNCTION demo_usuario(TEXT), demo_cliente(TEXT), demo_pres(TEXT, TEXT), demo_variante(TEXT),
              demo_oc(TEXT), demo_dco(TEXT, TEXT), demo_linea(TEXT, TEXT, TEXT), demo_comprobante(TEXT),
              demo_pedido(TEXT), demo_punto(TEXT), demo_metodo(TEXT), demo_motivo(TEXT), demo_dfa(TEXT),
              demo_total(TEXT);
