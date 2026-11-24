-- =====================================================================
--  COMERCIAL ELITE · 150 pruebas de flujo
--  Requiere una base VACÍA con ComercialElite_PDM.sql y
--  ComercialElite_logica.sql ya ejecutados (sin la demo):
--      psql -d <base> -f ComercialElite_pruebas.sql
--
--  Cada prueba recorre un paso real del negocio con las funciones del
--  sistema y verifica el resultado esperado. Las pruebas de rechazo
--  comprueban además que el motivo del rechazo sea el correcto.
--
--   1-7    Seguridad y permisos          51-61  Facturación y SRI
--   8-13   Catálogo y precios            62-69  Notas de crédito
--  14-25   Compras                       70-85  Crédito, avances y abonos
--  26-36   Inventario y kárdex           86-97  Cuero por bandas
--  37-50   Ventas                        98-100 Consistencia general
--                                       101-110 Negociación de precios
--                                       111-115 Avances y deuda de clientes
--                                       116-120 Proveedores e historial de costos
--                                       121-129 Ofertas
--                                       130-135 Bitácora y auditoría
--                                       136-141 Nodos producción / e-commerce
--                                       142-150 Comprobantes: factura, nota de venta, sin comprobante
-- =====================================================================

\set ON_ERROR_STOP on
\set QUIET on
\pset pager off
SET client_min_messages TO warning;
-- Las utilidades de prueba van en public; las tablas están en los esquemas de cada nodo
SET search_path = public, produccion, ecommerce;


-- =====================================================================
-- INFRAESTRUCTURA DE PRUEBAS
-- =====================================================================

CREATE TABLE t_resultado (
    n           INTEGER PRIMARY KEY,
    grupo       TEXT    NOT NULL,
    descripcion TEXT    NOT NULL,
    ok          BOOLEAN,
    detalle     TEXT
);
CREATE TABLE t_actual (n INTEGER);
INSERT INTO t_actual VALUES (NULL);

CREATE PROCEDURE t_inicio(p_n INTEGER, p_grupo TEXT, p_desc TEXT) LANGUAGE sql AS $$
    INSERT INTO t_resultado (n, grupo, descripcion) VALUES (p_n, p_grupo, p_desc);
    UPDATE t_actual SET n = p_n;
$$;
CREATE FUNCTION t_ok(p_cond BOOLEAN, p_detalle TEXT DEFAULT NULL) RETURNS VOID LANGUAGE sql AS $$
    UPDATE t_resultado SET ok = COALESCE(p_cond, FALSE), detalle = p_detalle WHERE n = (SELECT n FROM t_actual);
$$;
CREATE FUNCTION t_error(p_msg TEXT) RETURNS VOID LANGUAGE sql AS $$
    UPDATE t_resultado SET ok = FALSE, detalle = 'Error inesperado: ' || p_msg WHERE n = (SELECT n FROM t_actual);
$$;
CREATE FUNCTION t_rechazo(p_msg TEXT, p_patron TEXT) RETURNS VOID LANGUAGE sql AS $$
    UPDATE t_resultado SET ok = (p_msg ILIKE '%' || p_patron || '%'), detalle = 'Rechazado: ' || p_msg
    WHERE n = (SELECT n FROM t_actual);
$$;

-- Búsquedas por nombre (los datos de prueba se identifican por texto)
CREATE FUNCTION t_u(p TEXT) RETURNS INTEGER LANGUAGE sql STABLE AS
$$ SELECT id_usuario FROM usuario WHERE usu_correo IN (p || '@prueba.ec', p || '@comercialelite.local') $$;
CREATE FUNCTION t_cli(p TEXT) RETURNS INTEGER LANGUAGE sql STABLE AS
$$ SELECT id_cliente FROM cliente WHERE cli_nombres = p $$;
CREATE FUNCTION t_var(p TEXT) RETURNS INTEGER LANGUAGE sql STABLE AS
$$ SELECT id_variante FROM variante WHERE var_sku = p $$;
CREATE FUNCTION t_pres(p_sku TEXT, p_desc TEXT) RETURNS INTEGER LANGUAGE sql STABLE AS
$$ SELECT id_presentacion FROM presentacion WHERE id_variante = t_var(p_sku) AND pre_descripcion = p_desc $$;
CREATE FUNCTION t_dfa(p TEXT) RETURNS INTEGER LANGUAGE sql STABLE AS
$$ SELECT id_datos_facturacion FROM datos_facturacion WHERE dfa_identificacion = p AND dfa_activo $$;
CREATE FUNCTION t_punto(p TEXT) RETURNS INTEGER LANGUAGE sql STABLE AS
$$ SELECT id_punto_emision FROM punto_emision WHERE pem_establecimiento = '001' AND pem_punto = p $$;
CREATE FUNCTION t_met(p TEXT) RETURNS INTEGER LANGUAGE sql STABLE AS
$$ SELECT id_metodo_pago FROM metodo_pago WHERE mpa_nombre = p $$;
CREATE FUNCTION t_mot(p TEXT) RETURNS INTEGER LANGUAGE sql STABLE AS
$$ SELECT id_motivo_devolucion FROM motivo_devolucion WHERE mde_nombre = p $$;
CREATE FUNCTION t_lote(p TEXT) RETURNS INTEGER LANGUAGE sql STABLE AS
$$ SELECT id_lote FROM lote WHERE lot_codigo_proveedor = p $$;
CREATE FUNCTION t_oc(p TEXT) RETURNS INTEGER LANGUAGE sql STABLE AS
$$ SELECT id_orden_compra FROM orden_compra WHERE oc_observacion = p $$;
CREATE FUNCTION t_dco(p_oc TEXT, p_sku TEXT) RETURNS INTEGER LANGUAGE sql STABLE AS
$$ SELECT id_detalle_orden_compra FROM detalle_orden_compra WHERE id_orden_compra = t_oc(p_oc) AND id_variante = t_var(p_sku) $$;
CREATE FUNCTION t_ped(p TEXT) RETURNS INTEGER LANGUAGE sql STABLE AS
$$ SELECT id_pedido FROM pedido WHERE ped_observacion = p $$;
CREATE FUNCTION t_fac(p TEXT) RETURNS INTEGER LANGUAGE sql STABLE AS
$$ SELECT id_comprobante_venta FROM comprobante_venta WHERE id_pedido = t_ped(p) AND cve_estado <> 'ANULADA' $$;
CREATE FUNCTION t_nc(p TEXT) RETURNS INTEGER LANGUAGE sql STABLE AS
$$ SELECT id_nota_credito FROM nota_credito WHERE ncr_observacion = p $$;
CREATE FUNCTION t_lin(p_obs TEXT, p_sku TEXT, p_desc TEXT) RETURNS INTEGER LANGUAGE sql STABLE AS
$$ SELECT id_detalle_pedido FROM detalle_pedido WHERE id_pedido = t_ped(p_obs) AND id_presentacion = t_pres(p_sku, p_desc) $$;
CREATE FUNCTION t_linea(p_sku TEXT, p_desc TEXT, p_cant NUMERIC, p_descuento NUMERIC DEFAULT 0) RETURNS JSONB LANGUAGE sql STABLE AS
$$ SELECT jsonb_build_array(jsonb_build_object('id_presentacion', t_pres(p_sku, p_desc), 'cantidad', p_cant, 'descuento', p_descuento)) $$;
CREATE FUNCTION t_stock(p TEXT) RETURNS NUMERIC LANGUAGE sql STABLE AS
$$ SELECT stock_fisico FROM v_stock_variante WHERE var_sku = p $$;
CREATE FUNCTION t_saldo_lote(p TEXT) RETURNS NUMERIC LANGUAGE sql STABLE AS
$$ SELECT saldo FROM v_lote_saldo WHERE id_lote = t_lote(p) $$;
CREATE FUNCTION t_estado(p INTEGER) RETURNS TEXT LANGUAGE sql STABLE AS
$$ SELECT id_estado_pedido FROM v_pedido_estado_actual WHERE id_pedido = p $$;
CREATE FUNCTION t_total(p INTEGER) RETURNS NUMERIC LANGUAGE sql STABLE AS
$$ SELECT total FROM v_pedido_totales WHERE id_pedido = p $$;
CREATE FUNCTION t_cxc(p_obs TEXT, p_tipo TEXT) RETURNS INTEGER LANGUAGE sql STABLE AS
$$ SELECT MIN(id_cuenta_por_cobrar) FROM cuenta_por_cobrar WHERE id_pedido = t_ped(p_obs) AND cxc_tipo = p_tipo $$;
CREATE FUNCTION t_saldo_cxc(p INTEGER) RETURNS NUMERIC LANGUAGE sql STABLE AS
$$ SELECT saldo FROM v_cuentas_por_cobrar WHERE id_cuenta_por_cobrar = p $$;
CREATE FUNCTION t_deuda(p TEXT) RETURNS NUMERIC LANGUAGE sql STABLE AS
$$ SELECT deuda_total FROM v_estado_cuenta_cliente WHERE id_cliente = t_cli(p) $$;
-- Lotes que usó una factura (en el despacho)
CREATE FUNCTION t_lotes_comprobante(p_fac INTEGER) RETURNS TEXT LANGUAGE sql STABLE AS
$$ SELECT STRING_AGG(COALESCE(l.lot_codigo_proveedor, 'lote ' || l.id_lote) || ':' || dm.dmo_cantidad, ', ' ORDER BY dm.id_detalle_movimiento)
   FROM movimiento_inventario m
   JOIN detalle_movimiento dm ON dm.id_movimiento = m.id_movimiento
   JOIN lote l ON l.id_lote = dm.id_lote
   WHERE m.id_comprobante_venta = p_fac AND m.id_tipo_movimiento = 'VEN' $$;

-- Venta de contado completa: pedido → pago total → factura
CREATE FUNCTION t_vender(p_cli TEXT, p_canal TEXT, p_lineas JSONB, p_vendedor TEXT, p_dfa TEXT,
                         p_punto TEXT, p_obs TEXT, p_lote TEXT DEFAULT NULL)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_ped    INTEGER;
    v_cajero INTEGER := t_u(COALESCE(p_vendedor, 'sistema'));
    v_lotes  JSONB;
BEGIN
    v_ped := fn_crear_pedido(t_cli(p_cli), p_canal, p_lineas,
                             CASE WHEN p_vendedor IS NULL THEN NULL ELSE t_u(p_vendedor) END, p_obs);
    PERFORM fn_registrar_pago(v_ped, t_met(CASE WHEN p_canal = 'WEB' THEN 'Pago en línea (pasarela)' ELSE 'Efectivo' END),
                              t_total(v_ped), v_cajero);
    IF p_lote IS NOT NULL THEN
        SELECT jsonb_agg(jsonb_build_object('id_detalle_pedido', id_detalle_pedido, 'id_lote', t_lote(p_lote)))
          INTO v_lotes FROM detalle_pedido WHERE id_pedido = v_ped;
    END IF;
    RETURN fn_facturar_pedido(v_ped, t_dfa(p_dfa), t_punto(p_punto), v_cajero, v_lotes);
END $$;


-- =====================================================================
-- DATOS DE PRUEBA
-- =====================================================================

INSERT INTO provincia (pvc_nombre) VALUES ('Pichincha'), ('Tungurahua');
INSERT INTO ciudad (id_provincia, ciu_nombre)
SELECT id_provincia, CASE pvc_nombre WHEN 'Pichincha' THEN 'Quito' ELSE 'Ambato' END FROM provincia;
INSERT INTO direccion (id_ciudad, dir_calle_principal)
SELECT id_ciudad, 'Matriz de prueba' FROM ciudad WHERE ciu_nombre = 'Quito';
INSERT INTO empresa (emp_ruc, emp_razon_social, emp_nombre_comercial, emp_correo, id_direccion_matriz)
SELECT '1799999999001', 'EMPRESA DE PRUEBA', 'Comercial Elite', 'ventas@prueba.ec', MIN(id_direccion) FROM direccion;
INSERT INTO punto_emision (pem_establecimiento, pem_punto, pem_descripcion) VALUES
    ('001', '001', 'Tienda'), ('001', '002', 'E-commerce');

INSERT INTO usuario (usu_correo, usu_hash_clave, usu_activo) VALUES
    ('admin@prueba.ec', 'x', TRUE), ('vende@prueba.ec', 'x', TRUE), ('bodega@prueba.ec', 'x', TRUE),
    ('compras@prueba.ec', 'x', TRUE), ('inactivo@prueba.ec', 'x', FALSE);
INSERT INTO usuario_rol (id_usuario, id_rol)
SELECT u.id_usuario, r.id_rol FROM usuario u JOIN rol r ON (u.usu_correo, r.rol_codigo) IN (
    ('admin@prueba.ec', 'ADMIN'), ('vende@prueba.ec', 'VENDEDOR'), ('bodega@prueba.ec', 'BODEGA'),
    ('compras@prueba.ec', 'COMPRAS'), ('inactivo@prueba.ec', 'VENDEDOR'));
INSERT INTO empleado (id_usuario, id_tipo_identificacion, epl_identificacion, epl_nombres, epl_apellidos)
SELECT id_usuario, '05', '17000000' || LPAD((ROW_NUMBER() OVER (ORDER BY id_usuario))::TEXT, 2, '0'),
       INITCAP(SPLIT_PART(usu_correo, '@', 1)), 'Prueba'
FROM usuario WHERE usu_correo IN ('admin@prueba.ec', 'vende@prueba.ec', 'bodega@prueba.ec',
                                  'compras@prueba.ec', 'inactivo@prueba.ec');

INSERT INTO cliente (cli_nombres, cli_correo, cli_limite_credito) VALUES
    ('Ana', 'ana@prueba.ec', 50),
    ('Taller Uno', 'uno@prueba.ec', 400),
    ('Taller Dos', 'dos@prueba.ec', 0),
    ('Pablo', NULL, 0);
INSERT INTO cuenta_web (id_cliente, cwe_correo, cwe_hash_clave) VALUES (t_cli('Ana'), 'ana@prueba.ec', 'x');
INSERT INTO direccion (id_cliente, id_ciudad, dir_calle_principal)
SELECT id_cliente, (SELECT id_ciudad FROM ciudad WHERE ciu_nombre = 'Ambato'), 'Calle de prueba'
FROM cliente WHERE cli_nombres IN ('Ana', 'Taller Uno');
INSERT INTO datos_facturacion (id_cliente, id_tipo_identificacion, dfa_identificacion, dfa_razon_social)
SELECT t_cli(x.c), x.t, x.i, x.r
FROM (VALUES ('Ana', '05', '1700000101', 'ANA PRUEBA'), ('Taller Uno', '04', '1790000001001', 'TALLER UNO'),
             ('Taller Dos', '04', '1790000002001', 'TALLER DOS'), ('Pablo', '05', '1700000102', 'PABLO PRUEBA')) AS x(c, t, i, r);
INSERT INTO transportista (tra_nombre) VALUES ('Transporte de prueba');

INSERT INTO categoria (cat_codigo, cat_nombre) VALUES ('CUE', 'Cueros y sintéticos'), ('QUI', 'Químicos'), ('HIL', 'Hilos');
INSERT INTO categoria (id_categoria_padre, cat_codigo, cat_nombre)
SELECT id_categoria, 'CUE-SIN', 'Sintéticos' FROM categoria WHERE cat_codigo = 'CUE';
INSERT INTO atributo (atr_nombre, atr_tipo_dato) VALUES ('Color', 'COLOR'), ('Tipo', 'TEXTO');
INSERT INTO categoria_atributo
SELECT c.id_categoria, a.id_atributo FROM categoria c, atributo a
WHERE (c.cat_codigo, a.atr_nombre) IN (('CUE', 'Color'), ('QUI', 'Tipo'));
INSERT INTO valor_atributo (id_atributo, val_valor)
SELECT a.id_atributo, x.v FROM atributo a
JOIN (VALUES ('Color', 'Negro'), ('Color', 'Café'), ('Tipo', 'Poliuretano')) AS x(a, v) ON a.atr_nombre = x.a;

INSERT INTO producto (id_categoria, id_unidad_medida, id_tarifa_iva, prd_codigo, prd_nombre, prd_publicado, prd_venta_por_pieza)
SELECT c.id_categoria, x.u, x.t, x.cod, x.nom, TRUE, x.pieza FROM categoria c
JOIN (VALUES ('CUE-SIN', 'm',    '4', 'SIN', 'Sintético napa', FALSE),
             ('QUI',     'u',    '4', 'PEG', 'Pegamento PU',   FALSE),
             ('CUE',     'pie2', '4', 'CUE', 'Cuero napa',     TRUE),
             ('HIL',     'u',    '0', 'HIL', 'Hilo encerado',  FALSE)) AS x(cat, u, t, cod, nom, pieza)
  ON c.cat_codigo = x.cat;
INSERT INTO variante (id_producto, var_sku, var_stock_minimo)
SELECT p.id_producto, x.sku, x.m FROM producto p
JOIN (VALUES ('SIN', 'SIN-NEG', 20), ('PEG', 'PEG-1L', 6), ('CUE', 'CUE-NEG', 20), ('HIL', 'HIL-1', 0)) AS x(p, sku, m)
  ON p.prd_codigo = x.p;
INSERT INTO presentacion (id_variante, pre_descripcion, pre_factor, pre_cantidad_minima)
SELECT t_var(x.sku), x.d, x.f, x.m
FROM (VALUES ('SIN-NEG', 'Metro', 1, 0.5), ('SIN-NEG', 'Rollo 30 m', 30, 1),
             ('PEG-1L', 'Unidad', 1, 1), ('PEG-1L', 'Caja x 4', 4, 1),
             ('CUE-NEG', 'Pie² al detal', 1, 1), ('CUE-NEG', 'Pie² precio banda', 1, 10),
             ('HIL-1', 'Unidad', 1, 1)) AS x(sku, d, f, m);
INSERT INTO historial_precio (id_presentacion, hpr_precio, hpr_vigente_desde, id_usuario)
SELECT t_pres(x.sku, x.d), x.p, CURRENT_TIMESTAMP - INTERVAL '1 day', t_u('admin')
FROM (VALUES ('SIN-NEG', 'Metro', 6.50), ('SIN-NEG', 'Rollo 30 m', 180.00),
             ('PEG-1L', 'Unidad', 9.80), ('PEG-1L', 'Caja x 4', 36.00),
             ('CUE-NEG', 'Pie² al detal', 3.20), ('CUE-NEG', 'Pie² precio banda', 2.80),
             ('HIL-1', 'Unidad', 2.00)) AS x(sku, d, p);

INSERT INTO proveedor (id_tipo_identificacion, prv_identificacion, prv_razon_social) VALUES
    ('04', '1891111111001', 'CURTIEMBRE DE PRUEBA'), ('04', '0992222222001', 'QUÍMICA DE PRUEBA');
-- OC-QUI queda en borrador para las pruebas de compras
INSERT INTO orden_compra (id_proveedor, id_usuario_crea, oc_fecha, oc_observacion)
SELECT id_proveedor, t_u('compras'), CURRENT_DATE - 15, 'OC-QUI' FROM proveedor WHERE prv_identificacion = '0992222222001';
INSERT INTO detalle_orden_compra (id_orden_compra, id_variante, dco_cantidad, dco_costo_unitario)
VALUES (t_oc('OC-QUI'), t_var('PEG-1L'), 24, 7.20);

-- Hilo con stock inicial para las ventas pequeñas
DO $$ BEGIN
    PERFORM fn_registrar_ajuste(t_var('HIL-1'), 'INI', 100, 'Inventario inicial', t_u('bodega'), 1.00);
END $$;


-- =====================================================================
-- A. SEGURIDAD Y PERMISOS (1-7)
-- =====================================================================

CALL t_inicio(1, 'Seguridad', 'Bodega no puede registrar ventas');
DO $$ BEGIN
    PERFORM fn_crear_pedido(t_cli('Taller Uno'), 'TDA', t_linea('HIL-1', 'Unidad', 1), t_u('bodega'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'no tiene el permiso VENTA_REGISTRAR');
END $$;

CALL t_inicio(2, 'Seguridad', 'Un vendedor no puede cambiar precios');
DO $$ BEGIN
    PERFORM fn_registrar_precio(t_pres('HIL-1', 'Unidad'), 1.00, t_u('vende'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'no tiene el permiso PRECIO_GESTIONAR');
END $$;

CALL t_inicio(3, 'Seguridad', 'Un usuario inactivo pierde sus permisos');
DO $$ BEGIN
    PERFORM fn_crear_pedido(t_cli('Taller Uno'), 'TDA', t_linea('HIL-1', 'Unidad', 1), t_u('inactivo'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'no tiene el permiso VENTA_REGISTRAR');
END $$;

CALL t_inicio(4, 'Seguridad', 'Bodega no puede registrar pagos');
DO $$ BEGIN
    PERFORM fn_registrar_pago(0, t_met('Efectivo'), 10, t_u('bodega'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'no tiene el permiso PAGO_REGISTRAR');
END $$;

CALL t_inicio(5, 'Seguridad', 'Un vendedor no puede otorgar crédito');
DO $$ BEGIN
    PERFORM fn_facturar_a_credito(0, 30, 0, 1, t_u('vende'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'no tiene el permiso CREDITO_OTORGAR');
END $$;

CALL t_inicio(6, 'Seguridad', 'El administrador tiene todos los permisos del sistema interno');
DO $$ DECLARE v_admin INTEGER; v_total INTEGER; BEGIN
    SELECT COUNT(*) INTO v_admin FROM rol_permiso rp JOIN rol r USING (id_rol) WHERE r.rol_codigo = 'ADMIN';
    SELECT COUNT(*) INTO v_total FROM permiso;
    PERFORM t_ok(v_admin = v_total AND NOT EXISTS (SELECT 1 FROM rol WHERE rol_codigo = 'CLIENTE'),
                 v_admin || ' de ' || v_total || ' permisos (los clientes ya no son usuarios internos)');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(7, 'Seguridad', 'Un correo de usuario con mayúsculas se rechaza (evita cuentas duplicadas)');
DO $$ BEGIN
    INSERT INTO usuario (usu_correo, usu_hash_clave) VALUES ('Admin@Prueba.ec', 'x');
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'ckc_usu_correo');
END $$;


-- =====================================================================
-- B. CATÁLOGO Y PRECIOS (8-13)
-- =====================================================================

CALL t_inicio(8, 'Catálogo', 'Un precio programado no rige antes de su fecha');
DO $$ DECLARE v_antes NUMERIC; v_despues NUMERIC; BEGIN
    SELECT precio INTO v_antes FROM v_precio_vigente WHERE id_presentacion = t_pres('SIN-NEG', 'Metro');
    PERFORM fn_registrar_precio(t_pres('SIN-NEG', 'Metro'), 7.00, t_u('admin'), (CURRENT_TIMESTAMP + INTERVAL '5 days')::TIMESTAMP);
    SELECT precio INTO v_despues FROM v_precio_vigente WHERE id_presentacion = t_pres('SIN-NEG', 'Metro');
    PERFORM t_ok(v_antes = v_despues AND v_despues = 6.50, 'vigente ' || v_despues || ', programado 7.00');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(9, 'Catálogo', 'Un precio nuevo sin fecha rige de inmediato');
DO $$ BEGIN
    PERFORM fn_registrar_precio(t_pres('HIL-1', 'Unidad'), 2.10, t_u('admin'));
    PERFORM t_ok((SELECT precio FROM v_precio_vigente WHERE id_presentacion = t_pres('HIL-1', 'Unidad')) = 2.10, 'vigente 2.10');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(10, 'Catálogo', 'El historial de precios no se edita');
DO $$ BEGIN
    UPDATE historial_precio SET hpr_precio = 0 WHERE id_historial_precio = (SELECT MIN(id_historial_precio) FROM historial_precio);
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'no se modifican');
END $$;

CALL t_inicio(11, 'Catálogo', 'Un atributo heredado de la categoría padre se acepta (Color en sintético)');
DO $$ BEGIN
    INSERT INTO variante_valor (id_variante, id_atributo, id_valor_atributo)
    SELECT t_var('SIN-NEG'), va.id_atributo, va.id_valor_atributo
    FROM valor_atributo va JOIN atributo a USING (id_atributo) WHERE a.atr_nombre = 'Color' AND va.val_valor = 'Negro';
    PERFORM t_ok(EXISTS (SELECT 1 FROM variante_valor WHERE id_variante = t_var('SIN-NEG')), 'Color: Negro');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(12, 'Catálogo', 'Un atributo ajeno a la categoría se rechaza (Color en pegamento)');
DO $$ BEGIN
    INSERT INTO variante_valor (id_variante, id_atributo, id_valor_atributo)
    SELECT t_var('PEG-1L'), va.id_atributo, va.id_valor_atributo
    FROM valor_atributo va JOIN atributo a USING (id_atributo) WHERE a.atr_nombre = 'Color' AND va.val_valor = 'Café';
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'no está definido para la categoría');
END $$;

CALL t_inicio(13, 'Catálogo', 'Una categoría no puede colgar de su propia subcategoría');
DO $$ BEGIN
    UPDATE categoria SET id_categoria_padre = (SELECT id_categoria FROM categoria WHERE cat_codigo = 'CUE-SIN')
    WHERE cat_codigo = 'CUE';
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'no puede depender');
END $$;


-- =====================================================================
-- C. COMPRAS (14-25)
-- =====================================================================

CALL t_inicio(14, 'Compras', 'Una orden de compra sin líneas no se emite');
DO $$ DECLARE v INTEGER; BEGIN
    INSERT INTO orden_compra (id_proveedor, id_usuario_crea, oc_observacion)
    SELECT id_proveedor, t_u('compras'), 'OC-VACIA' FROM proveedor WHERE prv_identificacion = '1891111111001'
    RETURNING id_orden_compra INTO v;
    PERFORM fn_cambiar_estado_oc(v, 'EMITIDA', t_u('compras'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'no tiene líneas');
END $$;

CALL t_inicio(15, 'Compras', 'Una orden de compra con líneas pasa de borrador a emitida');
DO $$ DECLARE v INTEGER; BEGIN
    INSERT INTO orden_compra (id_proveedor, id_usuario_crea, oc_fecha, oc_observacion)
    SELECT id_proveedor, t_u('compras'), CURRENT_DATE - 50, 'OC-CUR' FROM proveedor WHERE prv_identificacion = '1891111111001'
    RETURNING id_orden_compra INTO v;
    INSERT INTO detalle_orden_compra (id_orden_compra, id_variante, dco_cantidad, dco_costo_unitario) VALUES
        (v, t_var('SIN-NEG'), 120, 4.10), (v, t_var('CUE-NEG'), 69.50, 2.10);
    PERFORM fn_cambiar_estado_oc(v, 'EMITIDA', t_u('compras'));
    PERFORM t_ok((SELECT oc_estado FROM orden_compra WHERE id_orden_compra = v) = 'EMITIDA', 'OC-CUR emitida');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(16, 'Compras', 'Las líneas de una orden emitida no se editan');
DO $$ BEGIN
    INSERT INTO detalle_orden_compra (id_orden_compra, id_variante, dco_cantidad, dco_costo_unitario)
    VALUES (t_oc('OC-CUR'), t_var('PEG-1L'), 5, 7.00);
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'solo se editan en borrador');
END $$;

CALL t_inicio(17, 'Compras', 'No se recibe mercadería de una orden en borrador');
DO $$ BEGIN
    PERFORM fn_recepcionar_compra(t_oc('OC-QUI'), t_u('bodega'),
        jsonb_build_array(jsonb_build_object('id_detalle_orden_compra', t_dco('OC-QUI', 'PEG-1L'), 'cantidad', 5)));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'de una OC emitida');
END $$;

CALL t_inicio(18, 'Compras', 'Recepción parcial con la factura del proveedor crea un lote con su costo');
DO $$ BEGIN
    INSERT INTO comprobante_compra (id_proveedor, cco_numero, cco_fecha_emision, cco_fecha_vencimiento,
                                   cco_subtotal_gravado, cco_iva, id_usuario_registra)
    SELECT id_proveedor, '001-001-000000101', CURRENT_DATE - 45, CURRENT_DATE + 15, 369.00, 55.35, t_u('compras')
    FROM proveedor WHERE prv_identificacion = '1891111111001';
    PERFORM fn_recepcionar_compra(t_oc('OC-CUR'), t_u('bodega'),
        jsonb_build_array(jsonb_build_object('id_detalle_orden_compra', t_dco('OC-CUR', 'SIN-NEG'), 'cantidad', 90,
                                             'costo_unitario', 4.10, 'codigo_lote', 'L-SIN-1')),
        (SELECT id_comprobante_compra FROM comprobante_compra WHERE cco_numero = '001-001-000000101'),
        (CURRENT_TIMESTAMP - INTERVAL '45 days')::TIMESTAMP);
    PERFORM t_ok(t_stock('SIN-NEG') = 90
                 AND (SELECT estado_recepcion FROM v_orden_compra_estado WHERE id_orden_compra = t_oc('OC-CUR')) = 'PARCIAL',
                 'stock ' || t_stock('SIN-NEG') || ' m, OC parcial');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(19, 'Compras', 'Emitir la orden del químico y recibir pegamento con vencimiento');
DO $$ BEGIN
    PERFORM fn_cambiar_estado_oc(t_oc('OC-QUI'), 'EMITIDA', t_u('compras'));
    PERFORM fn_recepcionar_compra(t_oc('OC-QUI'), t_u('bodega'),
        jsonb_build_array(jsonb_build_object('id_detalle_orden_compra', t_dco('OC-QUI', 'PEG-1L'), 'cantidad', 12,
                                             'fecha_vencimiento', CURRENT_DATE + 60, 'codigo_lote', 'L-PEG-1')),
        NULL, (CURRENT_TIMESTAMP - INTERVAL '10 days')::TIMESTAMP);
    PERFORM t_ok(t_stock('PEG-1L') = 12 AND (SELECT lot_costo_unitario FROM lote WHERE id_lote = t_lote('L-PEG-1')) = 7.20,
                 'stock 12 u a 7.20 (costo pactado)');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(20, 'Compras', 'Una factura de otro proveedor no se acepta en la recepción');
DO $$ BEGIN
    PERFORM fn_recepcionar_compra(t_oc('OC-QUI'), t_u('bodega'),
        jsonb_build_array(jsonb_build_object('id_detalle_orden_compra', t_dco('OC-QUI', 'PEG-1L'), 'cantidad', 1)),
        (SELECT id_comprobante_compra FROM comprobante_compra WHERE cco_numero = '001-001-000000101'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'no corresponde al proveedor');
END $$;

CALL t_inicio(21, 'Compras', 'Una segunda recepción a otro costo crea otro lote y completa la línea');
DO $$ BEGIN
    PERFORM fn_recepcionar_compra(t_oc('OC-CUR'), t_u('bodega'),
        jsonb_build_array(jsonb_build_object('id_detalle_orden_compra', t_dco('OC-CUR', 'SIN-NEG'), 'cantidad', 30,
                                             'costo_unitario', 4.15, 'codigo_lote', 'L-SIN-2')),
        NULL, (CURRENT_TIMESTAMP - INTERVAL '20 days')::TIMESTAMP);
    PERFORM t_ok((SELECT COUNT(*) FROM lote WHERE id_variante = t_var('SIN-NEG')) = 2
                 AND (SELECT cantidad_pendiente FROM v_orden_compra_detalle
                      WHERE id_detalle_orden_compra = t_dco('OC-CUR', 'SIN-NEG')) = 0,
                 '2 lotes (4.10 y 4.15), pendiente 0');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(22, 'Compras', 'No se recibe más de lo pendiente en la orden');
DO $$ BEGIN
    PERFORM fn_recepcionar_compra(t_oc('OC-CUR'), t_u('bodega'),
        jsonb_build_array(jsonb_build_object('id_detalle_orden_compra', t_dco('OC-CUR', 'SIN-NEG'), 'cantidad', 1)));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'solo quedan');
END $$;

CALL t_inicio(23, 'Compras', 'Cuero: una línea de recepción por banda crea un lote por banda con su área');
DO $$ BEGIN
    PERFORM fn_recepcionar_compra(t_oc('OC-CUR'), t_u('bodega'),
        (SELECT jsonb_agg(jsonb_build_object('id_detalle_orden_compra', t_dco('OC-CUR', 'CUE-NEG'),
                                             'cantidad', x.a, 'codigo_lote', x.b) ORDER BY x.b)
         FROM (VALUES ('BANDA-1', 23.10), ('BANDA-2', 22.40), ('BANDA-3', 24.00)) AS x(b, a)),
        NULL, (CURRENT_TIMESTAMP - INTERVAL '30 days')::TIMESTAMP);
    PERFORM t_ok((SELECT COUNT(*) FROM lote WHERE id_variante = t_var('CUE-NEG')) = 3
                 AND t_stock('CUE-NEG') = 69.50
                 AND (SELECT estado_recepcion FROM v_orden_compra_estado WHERE id_orden_compra = t_oc('OC-CUR')) = 'COMPLETA',
                 '3 bandas, 69.50 pie², OC completa');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(24, 'Compras', 'Un pago parcial al proveedor deja el saldo correcto');
DO $$ BEGIN
    INSERT INTO pago_proveedor (id_comprobante_compra, id_metodo_pago, ppr_monto, id_usuario_registra)
    SELECT id_comprobante_compra, t_met('Transferencia bancaria'), 300, t_u('compras')
    FROM comprobante_compra WHERE cco_numero = '001-001-000000101';
    PERFORM t_ok((SELECT saldo FROM v_cuentas_por_pagar WHERE numero = '001-001-000000101') = 124.35, 'saldo 124.35');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(25, 'Compras', 'Un pago mayor al saldo del proveedor se rechaza');
DO $$ BEGIN
    INSERT INTO pago_proveedor (id_comprobante_compra, id_metodo_pago, ppr_monto, id_usuario_registra)
    SELECT id_comprobante_compra, t_met('Transferencia bancaria'), 200, t_u('compras')
    FROM comprobante_compra WHERE cco_numero = '001-001-000000101';
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'supera el saldo pendiente');
END $$;


-- =====================================================================
-- D. INVENTARIO Y KÁRDEX (26-36)
-- =====================================================================

CALL t_inicio(26, 'Inventario', 'Devolución al proveedor descuenta del lote recibido');
DO $$ BEGIN
    PERFORM fn_devolver_a_proveedor(t_lote('L-SIN-2'), 2, 'Fallas de tintura', t_u('compras'));
    PERFORM t_ok(t_saldo_lote('L-SIN-2') = 28, 'L-SIN-2 queda en ' || t_saldo_lote('L-SIN-2'));
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(27, 'Inventario', 'No se devuelve al proveedor un lote de otra orden de compra');
DO $$ DECLARE v INTEGER; BEGIN
    INSERT INTO movimiento_inventario (id_tipo_movimiento, id_usuario, mov_motivo, id_orden_compra)
    VALUES ('DPR', t_u('compras'), 'Prueba', t_oc('OC-CUR')) RETURNING id_movimiento INTO v;
    INSERT INTO detalle_movimiento (id_movimiento, id_lote, dmo_cantidad) VALUES (v, t_lote('L-PEG-1'), 1);
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'no fue recibido en la OC');
END $$;

CALL t_inicio(28, 'Inventario', 'El inventario inicial crea un lote con su costo y vencimiento');
DO $$ BEGIN
    PERFORM fn_registrar_ajuste(t_var('PEG-1L'), 'INI', 10, 'Inventario inicial', t_u('bodega'), 6.80,
                                CURRENT_DATE + 150, NULL, (CURRENT_TIMESTAMP - INTERVAL '75 days')::TIMESTAMP);
    PERFORM t_ok(t_stock('PEG-1L') = 22, 'stock 22 u');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(29, 'Inventario', 'Un inventario inicial sin costo se rechaza');
DO $$ BEGIN
    PERFORM fn_registrar_ajuste(t_var('PEG-1L'), 'INI', 5, 'Inventario inicial', t_u('bodega'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'costo unitario');
END $$;

CALL t_inicio(30, 'Inventario', 'Un ajuste positivo sin costo toma el costo del último lote');
DO $$ BEGIN
    PERFORM fn_registrar_ajuste(t_var('SIN-NEG'), 'AJP', 1, 'Sobrante en conteo físico', t_u('bodega'));
    PERFORM t_ok((SELECT lot_costo_unitario FROM lote WHERE id_variante = t_var('SIN-NEG') ORDER BY id_lote DESC LIMIT 1) = 4.15,
                 'costo 4.15');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(31, 'Inventario', 'Un ajuste negativo sin motivo se rechaza');
DO $$ BEGIN
    PERFORM fn_registrar_ajuste(t_var('SIN-NEG'), 'AJN', 1, NULL, t_u('bodega'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'ckt_movimiento_inventario');
END $$;

CALL t_inicio(32, 'Inventario', 'Una merma se descuenta del lote indicado');
DO $$ BEGIN
    PERFORM fn_registrar_ajuste(t_var('PEG-1L'), 'MER', 1, 'Envase roto', t_u('bodega'), NULL, NULL, t_lote('L-PEG-1'));
    PERFORM t_ok(t_saldo_lote('L-PEG-1') = 11, 'L-PEG-1 queda en 11');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(33, 'Inventario', 'Un ajuste sobre un lote de otra variante se rechaza');
DO $$ BEGIN
    PERFORM fn_registrar_ajuste(t_var('PEG-1L'), 'MER', 1, 'Prueba', t_u('bodega'), NULL, NULL, t_lote('L-SIN-1'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'no pertenece a la variante');
END $$;

CALL t_inicio(34, 'Inventario', 'Ninguna salida deja un lote en negativo');
DO $$ BEGIN
    PERFORM fn_registrar_ajuste(t_var('PEG-1L'), 'MER', 50, 'Prueba', t_u('bodega'), NULL, NULL, t_lote('L-PEG-1'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'Stock insuficiente en el lote');
END $$;

CALL t_inicio(35, 'Inventario', 'No se registran movimientos con fecha futura');
DO $$ BEGIN
    INSERT INTO movimiento_inventario (id_tipo_movimiento, mov_fechahora, id_usuario, mov_motivo)
    VALUES ('AJP', CURRENT_TIMESTAMP + INTERVAL '1 day', t_u('bodega'), 'Prueba');
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'fecha futura');
END $$;

CALL t_inicio(36, 'Inventario', 'El kárdex no se edita ni se borra');
DO $$ BEGIN
    DELETE FROM detalle_movimiento WHERE id_detalle_movimiento = (SELECT MIN(id_detalle_movimiento) FROM detalle_movimiento);
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'no se modifican');
END $$;


-- =====================================================================
-- E. VENTAS (37-50)
-- =====================================================================

CALL t_inicio(37, 'Ventas', 'Un pedido sin líneas se rechaza');
DO $$ BEGIN
    PERFORM fn_crear_pedido(t_cli('Taller Uno'), 'TDA', '[]'::JSONB, t_u('vende'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'no tiene líneas');
END $$;

CALL t_inicio(38, 'Ventas', 'Una cantidad menor a la mínima de la presentación se rechaza');
DO $$ BEGIN
    PERFORM fn_crear_pedido(t_cli('Taller Uno'), 'TDA', t_linea('SIN-NEG', 'Metro', 0.2), t_u('vende'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'compra mínima');
END $$;

CALL t_inicio(39, 'Ventas', 'El pedido toma el precio vigente y la tarifa de IVA del producto');
DO $$ DECLARE v INTEGER; v_ok BOOLEAN; BEGIN
    v := fn_crear_pedido(t_cli('Taller Uno'), 'TDA', t_linea('HIL-1', 'Unidad', 3), t_u('vende'));
    SELECT dpe_precio_unitario = 2.10 AND id_tarifa_iva = '0' INTO v_ok FROM detalle_pedido WHERE id_pedido = v;
    PERFORM fn_cambiar_estado_pedido(v, 'CAN', t_u('vende'), 'Prueba');
    PERFORM t_ok(v_ok AND t_estado(v) = 'CAN', 'precio 2.10, IVA 0%, luego cancelado');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(40, 'Ventas', 'Un pedido pendiente reserva stock: baja el disponible, no el físico');
DO $$ DECLARE v_fis NUMERIC; v_disp NUMERIC; BEGIN
    SELECT stock_fisico, disponible INTO v_fis, v_disp FROM v_stock_variante WHERE var_sku = 'SIN-NEG';
    PERFORM fn_crear_pedido(t_cli('Taller Uno'), 'TDA', t_linea('SIN-NEG', 'Metro', 10), t_u('vende'), 'T-RESERVA');
    PERFORM t_ok((SELECT stock_fisico = v_fis AND disponible = v_disp - 10 FROM v_stock_variante WHERE var_sku = 'SIN-NEG'),
                 'físico ' || v_fis || ', disponible ' || v_disp || ' → ' || (v_disp - 10));
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(41, 'Ventas', 'No se reserva más de lo disponible');
DO $$ BEGIN
    PERFORM fn_crear_pedido(t_cli('Taller Uno'), 'TDA',
        t_linea('SIN-NEG', 'Metro', (SELECT disponible + 1 FROM v_stock_variante WHERE var_sku = 'SIN-NEG')), t_u('vende'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'Stock insuficiente para SIN-NEG');
END $$;

CALL t_inicio(42, 'Ventas', 'Cancelar el pedido libera la reserva');
DO $$ BEGIN
    PERFORM fn_cambiar_estado_pedido(t_ped('T-RESERVA'), 'CAN', t_u('vende'), 'El cliente desistió');
    PERFORM t_ok((SELECT reservado = 0 AND disponible = stock_fisico FROM v_stock_variante WHERE var_sku = 'SIN-NEG'),
                 'reservado 0');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(43, 'Ventas', 'FEFO: el pegamento sale del lote que vence antes, aunque sea más nuevo');
DO $$ DECLARE f INTEGER; BEGIN
    f := t_vender('Taller Uno', 'TDA', t_linea('PEG-1L', 'Unidad', 3), 'vende', '1790000001001', '001', 'T-PEG-3');
    PERFORM t_ok(t_lotes_comprobante(f) = 'L-PEG-1:3.000', t_lotes_comprobante(f));
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(44, 'Ventas', 'PEPS: el sintético (sin vencimiento) sale del lote más antiguo');
DO $$ DECLARE f INTEGER; BEGIN
    f := t_vender('Taller Uno', 'TDA', t_linea('SIN-NEG', 'Metro', 5), 'vende', '1790000001001', '001', 'T-SIN-5');
    PERFORM t_ok(t_lotes_comprobante(f) = 'L-SIN-1:5.000', t_lotes_comprobante(f));
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(45, 'Ventas', 'Una venta mayor que un lote se reparte entre lotes (producto no es por pieza)');
DO $$ DECLARE f INTEGER; BEGIN
    f := t_vender('Taller Uno', 'TDA', t_linea('SIN-NEG', 'Metro', t_saldo_lote('L-SIN-1') + 2), 'vende',
                  '1790000001001', '001', 'T-SIN-REPARTO');
    PERFORM t_ok(t_lotes_comprobante(f) = 'L-SIN-1:85.000, L-SIN-2:2.000', t_lotes_comprobante(f));
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(46, 'Ventas', 'Venta web completa: carrito, pedido, envío, pasarela y factura automática');
DO $$ DECLARE v_car INTEGER; v_ped INTEGER; v_fac INTEGER; r RECORD; BEGIN
    INSERT INTO carrito (id_cliente) VALUES (t_cli('Ana')) RETURNING id_carrito INTO v_car;
    INSERT INTO item_carrito (id_carrito, id_presentacion, ica_cantidad) VALUES
        (v_car, t_pres('SIN-NEG', 'Metro'), 3), (v_car, t_pres('PEG-1L', 'Unidad'), 1);
    v_ped := fn_crear_pedido_desde_carrito(v_car, 'T-WEB-ANA');
    INSERT INTO envio (id_pedido, id_direccion, env_costo, id_tarifa_iva)
    SELECT v_ped, id_direccion, 5.00, '4' FROM direccion WHERE id_cliente = t_cli('Ana');
    PERFORM fn_registrar_pago(v_ped, t_met('Pago en línea (pasarela)'), t_total(v_ped), t_u('sistema'), 'PAS-0001');
    v_fac := fn_facturar_pedido(v_ped, t_dfa('1700000101'), t_punto('002'), t_u('sistema'));
    SELECT * INTO r FROM v_comprobante_venta WHERE id_comprobante_venta = v_fac;
    PERFORM t_ok(t_estado(v_ped) = 'FAC' AND r.canal = 'WEB' AND r.vendedor = 'E-commerce'
                 AND r.costo_envio = 5 AND r.total = 39.45 AND r.numero = '001-002-000000001',
                 r.numero || ' total ' || r.total || ' (incluye envío 5.00 + IVA)');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(47, 'Ventas', 'Un pedido con envío no se entrega sin despacharse');
DO $$ BEGIN
    PERFORM fn_cambiar_estado_pedido(t_ped('T-WEB-ANA'), 'ENT', t_u('bodega'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'debe despacharse primero');
END $$;

CALL t_inicio(48, 'Ventas', 'El costo del envío queda congelado después del pago');
DO $$ BEGIN
    UPDATE envio SET env_costo = 0 WHERE id_pedido = t_ped('T-WEB-ANA');
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'ya no se pueden cambiar');
END $$;

CALL t_inicio(49, 'Ventas', 'Bodega registra la guía, despacha y entrega');
DO $$ BEGIN
    UPDATE envio SET id_transportista = (SELECT MIN(id_transportista) FROM transportista), env_guia = 'GUIA-0001'
    WHERE id_pedido = t_ped('T-WEB-ANA');
    PERFORM fn_cambiar_estado_pedido(t_ped('T-WEB-ANA'), 'DES', t_u('bodega'), 'Entregado al transportista');
    PERFORM fn_cambiar_estado_pedido(t_ped('T-WEB-ANA'), 'ENT', t_u('bodega'), 'Recibido por el cliente');
    PERFORM t_ok(t_estado(t_ped('T-WEB-ANA')) = 'ENT', 'FAC → DES → ENT');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(50, 'Ventas', 'Pago parcial y transferencia por validar no confirman el pedido hasta cubrir el total');
DO $$ DECLARE v INTEGER; v_pago INTEGER; e1 TEXT; e2 TEXT; BEGIN
    v := fn_crear_pedido(t_cli('Pablo'), 'WSP', t_linea('HIL-1', 'Unidad', 10), t_u('vende'), 'T-PABLO');
    PERFORM fn_registrar_pago(v, t_met('Efectivo'), 10, t_u('vende'));
    e1 := t_estado(v);
    v_pago := fn_registrar_pago(v, t_met('Transferencia bancaria'), t_total(v) - 10, t_u('vende'), 'TRF-PABLO', FALSE);
    e2 := t_estado(v);
    PERFORM fn_confirmar_pago(v_pago, TRUE, t_u('vende'));
    PERFORM fn_facturar_pedido(v, t_dfa('1700000102'), t_punto('001'), t_u('vende'));
    PERFORM t_ok(e1 = 'PEN' AND e2 = 'PEN' AND t_estado(v) = 'FAC', e1 || ' → ' || e2 || ' → PAG → ' || t_estado(v));
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;


-- =====================================================================
-- F. FACTURACIÓN Y SRI (51-61)
-- =====================================================================

CALL t_inicio(51, 'Facturación', 'No se factura un pedido sin pago');
DO $$ DECLARE v INTEGER; BEGIN
    v := fn_crear_pedido(t_cli('Taller Uno'), 'TDA', t_linea('HIL-1', 'Unidad', 1), t_u('vende'));
    PERFORM fn_facturar_pedido(v, t_dfa('1790000001001'), t_punto('001'), t_u('vende'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'Solo se factura un pedido pagado');
END $$;

CALL t_inicio(52, 'Facturación', 'Se factura a consumidor final hasta USD 50');
DO $$ DECLARE f INTEGER; BEGIN
    f := t_vender('CONSUMIDOR FINAL', 'TDA', t_linea('HIL-1', 'Unidad', 5), 'vende', '9999999999999', '001', 'T-CF');
    PERFORM t_ok((SELECT tipo_identificacion = '07' AND total = 10.50 AND subtotal_0 = 10.50 FROM v_comprobante_venta WHERE id_comprobante_venta = f),
                 'USD 10.50 a consumidor final (IVA 0%)');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(53, 'Facturación', 'Sobre USD 50 la factura debe identificar al comprador (SRI)');
DO $$ BEGIN
    PERFORM t_vender('CONSUMIDOR FINAL', 'TDA', t_linea('PEG-1L', 'Unidad', 6), 'vende', '9999999999999', '001', 'T-CF-ALTO');
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'deben identificar al comprador');
END $$;

CALL t_inicio(54, 'Facturación', 'No se factura con los datos de otro cliente');
DO $$ DECLARE v INTEGER; BEGIN
    v := fn_crear_pedido(t_cli('Taller Uno'), 'TDA', t_linea('HIL-1', 'Unidad', 1), t_u('vende'));
    PERFORM fn_registrar_pago(v, t_met('Efectivo'), t_total(v), t_u('vende'));
    PERFORM fn_facturar_pedido(v, t_dfa('1700000101'), t_punto('001'), t_u('vende'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'no pertenecen al cliente');
END $$;

CALL t_inicio(55, 'Facturación', 'Un pedido facturado no se modifica');
DO $$ BEGIN
    UPDATE detalle_pedido SET dpe_precio_unitario = 1 WHERE id_pedido = t_ped('T-WEB-ANA');
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'ya no se puede modificar');
END $$;

CALL t_inicio(56, 'Facturación', 'Secuenciales por punto de emisión empiezan en 1 y no tienen saltos');
DO $$ BEGIN
    PERFORM t_ok(NOT EXISTS (SELECT 1 FROM (SELECT id_punto_emision, MIN(cve_secuencial) mn, MAX(cve_secuencial) mx, COUNT(*) c
                                            FROM comprobante_venta GROUP BY id_punto_emision) x
                             WHERE mn <> 1 OR mx <> c)
                 AND (SELECT COUNT(DISTINCT id_punto_emision) FROM comprobante_venta) = 2,
                 (SELECT STRING_AGG(pem_establecimiento || '-' || pem_punto || ': ' || n, ', ')
                  FROM (SELECT id_punto_emision, COUNT(*) n FROM comprobante_venta GROUP BY 1) x JOIN punto_emision USING (id_punto_emision)));
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(57, 'Facturación', 'Cada clave de acceso tiene 49 dígitos, RUC, tipo 01 y dígito verificador válido');
DO $$ DECLARE r RECORD; v_suma INTEGER; v_peso INTEGER; v_dv INTEGER; v_ok BOOLEAN := TRUE; v_n INTEGER := 0; i INTEGER; BEGIN
    FOR r IN SELECT cve_clave_acceso AS c FROM comprobante_venta LOOP
        v_n := v_n + 1;
        IF LENGTH(r.c) <> 49 OR r.c !~ '^[0-9]+$' OR SUBSTR(r.c, 9, 2) <> '01'
           OR SUBSTR(r.c, 11, 13) <> (SELECT emp_ruc FROM empresa) THEN
            v_ok := FALSE;
        END IF;
        v_suma := 0; v_peso := 2;
        FOR i IN REVERSE 48..1 LOOP
            v_suma := v_suma + SUBSTR(r.c, i, 1)::INTEGER * v_peso;
            v_peso := CASE WHEN v_peso = 7 THEN 2 ELSE v_peso + 1 END;
        END LOOP;
        v_dv := 11 - v_suma % 11;
        v_dv := CASE v_dv WHEN 11 THEN 0 WHEN 10 THEN 1 ELSE v_dv END;
        IF v_dv <> SUBSTR(r.c, 49, 1)::INTEGER THEN v_ok := FALSE; END IF;
    END LOOP;
    PERFORM t_ok(v_ok AND v_n > 0, v_n || ' claves verificadas');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(58, 'Facturación', 'Toda factura nueva entra a la cola del SRI y dispara el aviso de envío');
DO $$ BEGIN
    PERFORM t_ok(EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'tr_comprobante_venta_avisar_sri')
                 AND (SELECT COUNT(*) FROM v_cola_sri WHERE tipo = 'FACTURA') = (SELECT COUNT(*) FROM comprobante_venta)
                 AND (SELECT COUNT(*) FROM comprobante_venta) > 0,
                 (SELECT COUNT(*) FROM v_cola_sri) || ' comprobantes en cola');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(59, 'Facturación', 'Solo el usuario con permiso registra respuestas del SRI');
DO $$ BEGIN
    PERFORM fn_registrar_respuesta_sri('FACTURA', t_fac('T-WEB-ANA'), 'AUTORIZADA', t_u('vende'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'no tiene el permiso SRI_GESTIONAR');
END $$;

CALL t_inicio(60, 'Facturación', 'La factura autorizada por el SRI sale de la cola');
DO $$ BEGIN
    PERFORM fn_registrar_respuesta_sri('FACTURA', t_fac('T-WEB-ANA'), 'AUTORIZADA', t_u('sistema'));
    PERFORM t_ok(NOT EXISTS (SELECT 1 FROM v_cola_sri WHERE tipo = 'FACTURA' AND id = t_fac('T-WEB-ANA'))
                 AND (SELECT cve_fecha_autorizacion IS NOT NULL FROM comprobante_venta WHERE id_comprobante_venta = t_fac('T-WEB-ANA')),
                 'AUTORIZADA con fecha de autorización');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(61, 'Facturación', 'Una factura a consumidor final no se anula (SRI 2026)');
DO $$ BEGIN
    UPDATE comprobante_venta SET cve_estado = 'ANULADA' WHERE id_comprobante_venta = t_fac('T-CF');
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'consumidor final no se anula');
END $$;


-- =====================================================================
-- G. NOTAS DE CRÉDITO (62-69)
-- =====================================================================

CALL t_inicio(62, 'Notas de crédito', 'Un vendedor no puede emitir notas de crédito');
DO $$ BEGIN
    PERFORM fn_emitir_nota_credito(t_fac('T-PEG-3'), t_mot('Cliente no satisfecho'), t_u('vende'), t_punto('001'),
        jsonb_build_array(jsonb_build_object('id_detalle_pedido', t_lin('T-PEG-3', 'PEG-1L', 'Unidad'), 'cantidad', 1)));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'no tiene el permiso NC_EMITIR');
END $$;

CALL t_inicio(63, 'Notas de crédito', 'La devolución en buen estado vuelve al mismo lote del que salió');
DO $$ DECLARE v_antes NUMERIC; BEGIN
    v_antes := t_saldo_lote('L-PEG-1');
    PERFORM fn_emitir_nota_credito(t_fac('T-PEG-3'), t_mot('Cliente no satisfecho'), t_u('admin'), t_punto('001'),
        jsonb_build_array(jsonb_build_object('id_detalle_pedido', t_lin('T-PEG-3', 'PEG-1L', 'Unidad'),
                                             'cantidad', 1, 'reingresa', TRUE)), 'T-NC-PEG');
    PERFORM t_ok(t_saldo_lote('L-PEG-1') = v_antes + 1, 'L-PEG-1: ' || v_antes || ' → ' || t_saldo_lote('L-PEG-1'));
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(64, 'Notas de crédito', 'El producto dañado se acredita pero no vuelve al stock');
DO $$ DECLARE v_antes NUMERIC; BEGIN
    v_antes := t_stock('SIN-NEG');
    PERFORM fn_emitir_nota_credito(t_fac('T-SIN-REPARTO'), t_mot('Producto defectuoso'), t_u('admin'), t_punto('001'),
        jsonb_build_array(jsonb_build_object('id_detalle_pedido', t_lin('T-SIN-REPARTO', 'SIN-NEG', 'Metro'),
                                             'cantidad', 2, 'reingresa', FALSE)), 'T-NC-SIN');
    PERFORM t_ok(t_stock('SIN-NEG') = v_antes AND (SELECT total FROM v_nota_credito WHERE id_nota_credito = t_nc('T-NC-SIN')) = 14.95,
                 'stock sin cambio, NC 14.95');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(65, 'Notas de crédito', 'No se devuelve más de lo facturado, contando notas anteriores');
DO $$ BEGIN
    PERFORM fn_emitir_nota_credito(t_fac('T-PEG-3'), t_mot('Cliente no satisfecho'), t_u('admin'), t_punto('001'),
        jsonb_build_array(jsonb_build_object('id_detalle_pedido', t_lin('T-PEG-3', 'PEG-1L', 'Unidad'), 'cantidad', 3)));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'solo quedan 2');
END $$;

CALL t_inicio(66, 'Notas de crédito', 'Fuera del plazo de la política de devoluciones se rechaza');
DO $$ DECLARE v_msg TEXT; BEGIN
    BEGIN
        ALTER TABLE comprobante_venta DISABLE TRIGGER tr_comprobante_venta_protegido;
        UPDATE comprobante_venta SET cve_fechahora = cve_fechahora - INTERVAL '40 days' WHERE id_comprobante_venta = t_fac('T-PEG-3');
        ALTER TABLE comprobante_venta ENABLE TRIGGER tr_comprobante_venta_protegido;
        BEGIN
            PERFORM fn_emitir_nota_credito(t_fac('T-PEG-3'), t_mot('Cliente no satisfecho'), t_u('admin'), t_punto('001'),
                jsonb_build_array(jsonb_build_object('id_detalle_pedido', t_lin('T-PEG-3', 'PEG-1L', 'Unidad'), 'cantidad', 1)));
            v_msg := 'No se rechazó';
        EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
        END;
        RAISE EXCEPTION 'deshacer';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'deshacer' THEN v_msg := 'Error preparando: ' || SQLERRM; END IF;
    END;
    PERFORM t_rechazo(v_msg, 'superó el plazo de devolución');
END $$;

CALL t_inicio(67, 'Notas de crédito', 'Una factura a consumidor final no admite nota de crédito (SRI 2026)');
DO $$ BEGIN
    PERFORM fn_emitir_nota_credito(t_fac('T-CF'), t_mot('Cliente no satisfecho'), t_u('admin'), t_punto('001'),
        jsonb_build_array(jsonb_build_object('id_detalle_pedido', t_lin('T-CF', 'HIL-1', 'Unidad'), 'cantidad', 1)));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'consumidor final no admite nota de crédito');
END $$;

CALL t_inicio(68, 'Notas de crédito', 'Un reembolso mayor que la nota de crédito se rechaza');
DO $$ BEGIN
    INSERT INTO reembolso (id_nota_credito, id_metodo_pago, ree_monto, id_usuario_registra)
    VALUES (t_nc('T-NC-PEG'), t_met('Efectivo'), 20, t_u('admin'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'supera lo disponible');
END $$;

CALL t_inicio(69, 'Notas de crédito', 'El reembolso por el valor de la nota de crédito se registra');
DO $$ BEGIN
    INSERT INTO reembolso (id_nota_credito, id_metodo_pago, ree_monto, id_usuario_registra)
    SELECT id_nota_credito, t_met('Efectivo'), total, t_u('admin') FROM v_nota_credito WHERE id_nota_credito = t_nc('T-NC-PEG');
    PERFORM t_ok((SELECT SUM(ree_monto) FROM reembolso WHERE id_nota_credito = t_nc('T-NC-PEG')) = 11.27, 'reembolso 11.27');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;


-- =====================================================================
-- H. CRÉDITO, AVANCES Y ABONOS (70-85)
-- =====================================================================

CALL t_inicio(70, 'Crédito', 'Un cliente sin límite de crédito no compra a crédito');
DO $$ DECLARE v INTEGER; BEGIN
    v := fn_crear_pedido(t_cli('Taller Dos'), 'TDA', t_linea('HIL-1', 'Unidad', 2), t_u('vende'));
    PERFORM fn_facturar_a_credito(v, 30, t_dfa('1790000002001'), t_punto('001'), t_u('admin'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'límite de crédito');
END $$;

CALL t_inicio(71, 'Crédito', 'No se da crédito a consumidor final');
DO $$ DECLARE v INTEGER; BEGIN
    v := fn_crear_pedido(t_cli('CONSUMIDOR FINAL'), 'TDA', t_linea('HIL-1', 'Unidad', 1), t_u('vende'));
    PERFORM fn_facturar_a_credito(v, 30, t_dfa('9999999999999'), t_punto('001'), t_u('admin'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'identificación del cliente');
END $$;

CALL t_inicio(72, 'Crédito', 'Venta a crédito con abono inicial: el saldo queda como cuenta por cobrar');
DO $$ DECLARE v INTEGER; BEGIN
    v := fn_crear_pedido(t_cli('Taller Uno'), 'TDA',
                         t_linea('SIN-NEG', 'Metro', 4) || t_linea('PEG-1L', 'Caja x 4', 1), t_u('vende'), 'T-CREDITO');
    PERFORM fn_registrar_pago(v, t_met('Efectivo'), 20, t_u('vende'));
    PERFORM fn_facturar_a_credito(v, 30, t_dfa('1790000001001'), t_punto('001'), t_u('admin'));
    PERFORM t_ok(t_estado(v) = 'FAC' AND t_total(v) = 71.30 AND t_saldo_cxc(t_cxc('T-CREDITO', 'CREDITO')) = 51.30,
                 'total 71.30, pagó 20.00, crédito 51.30 a 30 días');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(73, 'Crédito', 'La venta a crédito se factura en el momento y va a la cola del SRI');
DO $$ BEGIN
    PERFORM t_ok(EXISTS (SELECT 1 FROM v_cola_sri WHERE tipo = 'FACTURA' AND id = t_fac('T-CREDITO')),
                 (SELECT numero FROM v_comprobante_venta WHERE id_comprobante_venta = t_fac('T-CREDITO')) || ' emitida aunque no está cobrada');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(74, 'Crédito', 'No se agrega crédito a un pedido ya facturado');
DO $$ BEGIN
    INSERT INTO cuenta_por_cobrar (id_pedido, cxc_tipo, cxc_monto, cxc_concepto, cxc_fecha_vencimiento, id_usuario_autoriza)
    VALUES (t_ped('T-CREDITO'), 'CREDITO', 1, 'Prueba', CURRENT_DATE + 1, t_u('admin'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'sobre un pedido pendiente');
END $$;

CALL t_inicio(75, 'Crédito', 'Avance para pasaje: suma a la deuda pero no cambia la factura');
DO $$ DECLARE v_fac NUMERIC; v_credito NUMERIC; BEGIN
    SELECT total INTO v_fac FROM v_comprobante_venta WHERE id_comprobante_venta = t_fac('T-CREDITO');
    v_credito := t_saldo_cxc(t_cxc('T-CREDITO', 'CREDITO'));
    PERFORM fn_registrar_avance(t_ped('T-CREDITO'), 15, 'Pasaje de regreso', t_met('Efectivo'), 15, t_u('admin'));
    PERFORM t_ok(t_deuda('Taller Uno') = v_credito + 15
                 AND (SELECT total FROM v_comprobante_venta WHERE id_comprobante_venta = t_fac('T-CREDITO')) = v_fac,
                 'deuda ' || t_deuda('Taller Uno') || ', factura sigue en ' || v_fac);
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(76, 'Crédito', 'No se entrega un avance sobre un pedido que no está facturado');
DO $$ DECLARE v INTEGER; BEGIN
    v := fn_crear_pedido(t_cli('Taller Uno'), 'TDA', t_linea('HIL-1', 'Unidad', 1), t_u('vende'));
    PERFORM fn_registrar_avance(v, 5, 'Pasaje', t_met('Efectivo'), 5, t_u('admin'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'compra ya facturada');
END $$;

CALL t_inicio(77, 'Crédito', 'Un avance que supera el límite de crédito se rechaza');
DO $$ BEGIN
    PERFORM fn_registrar_avance(t_ped('T-CREDITO'), 400, 'Material en otro local', t_met('Efectivo'), 15, t_u('admin'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'límite de crédito');
END $$;

CALL t_inicio(78, 'Crédito', 'Un abono parcial reduce el saldo de la cuenta');
DO $$ DECLARE v_antes NUMERIC; BEGIN
    v_antes := t_saldo_cxc(t_cxc('T-CREDITO', 'CREDITO'));
    PERFORM fn_registrar_abono(t_cxc('T-CREDITO', 'CREDITO'), 10, t_met('Efectivo'), t_u('vende'));
    PERFORM t_ok(t_saldo_cxc(t_cxc('T-CREDITO', 'CREDITO')) = v_antes - 10,
                 v_antes || ' → ' || t_saldo_cxc(t_cxc('T-CREDITO', 'CREDITO')));
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(79, 'Crédito', 'Un abono mayor al saldo de la cuenta se rechaza');
DO $$ BEGIN
    PERFORM fn_registrar_abono(t_cxc('T-CREDITO', 'CREDITO'), 1000, t_met('Efectivo'), t_u('vende'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'supera el saldo de la cuenta');
END $$;

CALL t_inicio(80, 'Crédito', 'Un abono general se aplica primero a lo que vence antes (el avance)');
DO $$ DECLARE v_credito NUMERIC; BEGIN
    v_credito := t_saldo_cxc(t_cxc('T-CREDITO', 'CREDITO'));
    PERFORM fn_abonar_cliente(t_cli('Taller Uno'), 45, t_met('Transferencia bancaria'), t_u('vende'), 'TRF-ABONO');
    PERFORM t_ok(t_saldo_cxc(t_cxc('T-CREDITO', 'AVANCE')) = 0
                 AND t_saldo_cxc(t_cxc('T-CREDITO', 'CREDITO')) = v_credito - 30,
                 'avance 15 → 0, crédito ' || v_credito || ' → ' || t_saldo_cxc(t_cxc('T-CREDITO', 'CREDITO')));
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(81, 'Crédito', 'Un abono mayor que la deuda total del cliente se rechaza');
DO $$ BEGIN
    PERFORM fn_abonar_cliente(t_cli('Taller Uno'), 1000, t_met('Efectivo'), t_u('vende'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'supera la deuda del cliente');
END $$;

CALL t_inicio(82, 'Crédito', 'La devolución de una venta a crédito se compensa con la deuda');
DO $$ DECLARE v_antes NUMERIC; BEGIN
    v_antes := t_saldo_cxc(t_cxc('T-CREDITO', 'CREDITO'));
    PERFORM fn_emitir_nota_credito(t_fac('T-CREDITO'), t_mot('Producto defectuoso'), t_u('admin'), t_punto('001'),
        jsonb_build_array(jsonb_build_object('id_detalle_pedido', t_lin('T-CREDITO', 'SIN-NEG', 'Metro'),
                                             'cantidad', 2, 'reingresa', TRUE)), 'T-NC-CREDITO');
    PERFORM t_ok(t_saldo_cxc(t_cxc('T-CREDITO', 'CREDITO')) = 0
                 AND (SELECT SUM(abo_monto) FROM abono_cliente WHERE id_nota_credito = t_nc('T-NC-CREDITO')) = v_antes,
                 'NC 14.95 compensa ' || v_antes || ' de deuda');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(83, 'Crédito', 'No se reembolsa más de lo que sobra de la nota compensada');
DO $$ BEGIN
    INSERT INTO reembolso (id_nota_credito, id_metodo_pago, ree_monto, id_usuario_registra)
    SELECT n.id_nota_credito, t_met('Efectivo'),
           n.total - (SELECT SUM(abo_monto) FROM abono_cliente WHERE id_nota_credito = n.id_nota_credito) + 0.01, t_u('admin')
    FROM v_nota_credito n WHERE n.id_nota_credito = t_nc('T-NC-CREDITO');
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'supera lo disponible');
END $$;

CALL t_inicio(84, 'Crédito', 'Se reembolsa al cliente lo que sobra de la nota después de compensar');
DO $$ BEGIN
    INSERT INTO reembolso (id_nota_credito, id_metodo_pago, ree_monto, id_usuario_registra)
    SELECT n.id_nota_credito, t_met('Efectivo'),
           n.total - (SELECT SUM(abo_monto) FROM abono_cliente WHERE id_nota_credito = n.id_nota_credito), t_u('admin')
    FROM v_nota_credito n WHERE n.id_nota_credito = t_nc('T-NC-CREDITO');
    PERFORM t_ok((SELECT SUM(ree_monto) FROM reembolso WHERE id_nota_credito = t_nc('T-NC-CREDITO')) = 3.65
                 AND t_deuda('Taller Uno') = 0, 'reembolso 3.65, deuda 0');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(85, 'Crédito', 'Un pedido con crédito otorgado no se puede cancelar');
DO $$ DECLARE v_msg TEXT; v INTEGER; BEGIN
    BEGIN
        v := fn_crear_pedido(t_cli('Taller Uno'), 'TDA', t_linea('HIL-1', 'Unidad', 1), t_u('vende'));
        INSERT INTO cuenta_por_cobrar (id_pedido, cxc_tipo, cxc_monto, cxc_concepto, cxc_fecha_vencimiento, id_usuario_autoriza)
        VALUES (v, 'CREDITO', 1.00, 'Prueba', CURRENT_DATE + 10, t_u('admin'));
        BEGIN
            PERFORM fn_cambiar_estado_pedido(v, 'CAN', t_u('vende'));
            v_msg := 'No se rechazó';
        EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
        END;
        RAISE EXCEPTION 'deshacer';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'deshacer' THEN v_msg := 'Error preparando: ' || SQLERRM; END IF;
    END;
    PERFORM t_rechazo(v_msg, 'tiene crédito otorgado');
END $$;


-- =====================================================================
-- I. CUERO POR BANDAS (86-97)
-- =====================================================================

CALL t_inicio(86, 'Cuero', 'El precio de banda exige la cantidad mínima (10 pie²)');
DO $$ BEGIN
    PERFORM fn_crear_pedido(t_cli('Taller Uno'), 'TDA', t_linea('CUE-NEG', 'Pie² precio banda', 4), t_u('vende'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'compra mínima');
END $$;

CALL t_inicio(87, 'Cuero', 'Media banda a precio de banda, cortada de la banda que elige el vendedor');
DO $$ DECLARE f INTEGER; BEGIN
    f := t_vender('Taller Uno', 'TDA', t_linea('CUE-NEG', 'Pie² precio banda', 11.55), 'vende', '1790000001001', '001',
                  'T-CUERO-1', 'BANDA-1');
    PERFORM t_ok(t_lotes_comprobante(f) = 'BANDA-1:11.550'
                 AND (SELECT dpe_precio_unitario FROM detalle_pedido WHERE id_pedido = t_ped('T-CUERO-1')) = 2.80,
                 t_lotes_comprobante(f) || ' a 2.80 el pie²');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(88, 'Cuero', 'La media banda que sobra queda como paquete con su área y antigüedad');
DO $$ BEGIN
    PERFORM t_ok((SELECT saldo = 11.55 AND dias_en_inventario = 30 FROM v_lote_saldo WHERE id_lote = t_lote('BANDA-1')),
                 'BANDA-1: 11.55 pie², 30 días');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(89, 'Cuero', 'El vendedor no puede escoger un lote de otro producto');
DO $$ BEGIN
    PERFORM t_vender('Taller Uno', 'TDA', t_linea('CUE-NEG', 'Pie² al detal', 2), 'vende', '1790000001001', '001',
                     'T-CUERO-X', 'L-SIN-1');
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'no es de la variante');
END $$;

CALL t_inicio(90, 'Cuero', 'Si la pieza escogida no alcanza, la venta se rechaza (no se completa con otra)');
DO $$ BEGIN
    PERFORM t_vender('Taller Uno', 'TDA', t_linea('CUE-NEG', 'Pie² al detal', 15), 'vende', '1790000001001', '001',
                     'T-CUERO-X', 'BANDA-1');
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'Stock insuficiente en el lote');
END $$;

CALL t_inicio(91, 'Cuero', 'Sin elección, se usa la pieza más pequeña que alcanza (aprovecha retazos)');
DO $$ DECLARE f INTEGER; BEGIN
    f := t_vender('Taller Uno', 'TDA', t_linea('CUE-NEG', 'Pie² al detal', 11), 'vende', '1790000001001', '001', 'T-CUERO-2');
    PERFORM t_ok(t_lotes_comprobante(f) = 'BANDA-1:11.000', t_lotes_comprobante(f) || ' (piezas: 11.55, 22.40, 24.00)');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(92, 'Cuero', 'Si ninguna pieza alcanza se rechaza, aunque la suma de retazos sí alcance');
DO $$ BEGIN
    PERFORM fn_crear_pedido(t_cli('Taller Uno'), 'TDA', t_linea('CUE-NEG', 'Pie² al detal', 30), t_u('vende'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'Ninguna pieza de CUE-NEG alcanza');
END $$;

CALL t_inicio(93, 'Cuero', 'El vendedor corta una banda en dos medias bandas (paquetes)');
DO $$ DECLARE v_lotes INTEGER[]; v_stock NUMERIC; BEGIN
    v_stock := t_stock('CUE-NEG');
    v_lotes := fn_fraccionar_lote(t_lote('BANDA-2'), '[11.20, 11.20]', t_u('vende'), 'Dos medias bandas');
    PERFORM t_ok(array_length(v_lotes, 1) = 2 AND t_saldo_lote('BANDA-2') = 0 AND t_stock('CUE-NEG') = v_stock
                 AND (SELECT COUNT(*) FROM lote WHERE id_lote_origen = t_lote('BANDA-2')) = 2,
                 'BANDA-2 → BANDA-2-1 y BANDA-2-2; stock total sin cambio (' || v_stock || ')');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(94, 'Cuero', 'Los paquetes conservan el costo y la antigüedad de la banda original');
DO $$ BEGIN
    PERFORM t_ok((SELECT BOOL_AND(lot_costo_unitario = 2.10 AND dias_en_inventario = 30)
                  FROM v_lote_saldo WHERE id_lote_origen = t_lote('BANDA-2')),
                 'costo 2.10, 30 días');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(95, 'Cuero', 'No se cortan paquetes por más de lo que tiene la pieza');
DO $$ BEGIN
    PERFORM fn_fraccionar_lote(t_lote('BANDA-3'), '[20, 5]', t_u('vende'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'Stock insuficiente en el lote');
END $$;

CALL t_inicio(96, 'Cuero', 'Un paquete solo puede venir de una pieza del mismo producto');
DO $$ BEGIN
    INSERT INTO lote (id_variante, lot_costo_unitario, id_lote_origen) VALUES (t_var('CUE-NEG'), 1, t_lote('L-SIN-1'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'misma variante');
END $$;

CALL t_inicio(97, 'Cuero', 'El reporte muestra cuánto vendió cada vendedor a precio de banda');
DO $$ BEGIN
    PERFORM t_ok((SELECT SUM(cantidad) FROM v_ventas_por_presentacion
                  WHERE var_sku = 'CUE-NEG' AND presentacion = 'Pie² precio banda' AND vendedor = 'Vende Prueba') = 11.55,
                 'Vende Prueba: 11.55 pie² a precio de banda');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;


-- =====================================================================
-- J. CONSISTENCIA GENERAL (98-100)
-- =====================================================================

CALL t_inicio(98, 'Consistencia', 'Para cada producto, entradas − salidas del kárdex = stock físico');
DO $$ BEGIN
    PERFORM t_ok(NOT EXISTS (
        SELECT 1 FROM v_stock_variante s
        WHERE s.stock_fisico <> COALESCE((SELECT SUM(COALESCE(k.entrada, 0) - COALESCE(k.salida, 0))
                                          FROM v_kardex k WHERE k.id_variante = s.id_variante), 0)),
        (SELECT STRING_AGG(var_sku || ' ' || stock_fisico, ', ' ORDER BY var_sku) FROM v_stock_variante));
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(99, 'Consistencia', 'Para cada cliente, deuda = cuentas por cobrar − abonos');
DO $$ BEGIN
    PERFORM t_ok(NOT EXISTS (
        SELECT 1 FROM v_estado_cuenta_cliente e
        WHERE e.deuda_total <>
              COALESCE((SELECT SUM(c.cxc_monto) FROM cuenta_por_cobrar c JOIN pedido p USING (id_pedido)
                        WHERE p.id_cliente = e.id_cliente), 0)
            - COALESCE((SELECT SUM(a.abo_monto) FROM abono_cliente a
                        JOIN cuenta_por_cobrar c USING (id_cuenta_por_cobrar) JOIN pedido p USING (id_pedido)
                        WHERE p.id_cliente = e.id_cliente), 0)),
        (SELECT COUNT(*) FROM cuenta_por_cobrar) || ' cuentas, ' || (SELECT COUNT(*) FROM abono_cliente) || ' abonos');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(100, 'Consistencia', 'Todo pedido facturado cuadra su total y está cubierto por pagos o crédito');
DO $$ BEGIN
    PERFORM t_ok(NOT EXISTS (
        SELECT 1 FROM comprobante_venta f
        JOIN v_pedido_totales t ON t.id_pedido = f.id_pedido
        JOIN v_pedido_pagos  pp ON pp.id_pedido = f.id_pedido
        WHERE f.cve_estado <> 'ANULADA'
          AND (t.total <> t.subtotal_0 + t.subtotal_gravado + t.iva OR pp.cubierto < t.total)),
        (SELECT COUNT(*) FROM comprobante_venta) || ' facturas revisadas');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;


-- =====================================================================
-- K. NEGOCIACIÓN DE PRECIOS (101-110)
-- =====================================================================

CALL t_inicio(101, 'Negociación', 'En tienda se negocia una línea escribiendo el valor final con IVA');
DO $$ DECLARE v INTEGER; v_linea NUMERIC; BEGIN
    v := fn_crear_pedido(t_cli('Taller Uno'), 'TDA', t_linea('SIN-NEG', 'Metro', 4), t_u('vende'), 'T-NEG-1');
    v_linea := fn_negociar_linea(t_lin('T-NEG-1', 'SIN-NEG', 'Metro'), 25.00, t_u('vende'));
    PERFORM t_ok(v_linea = 25.00 AND t_total(v) = 25.00
                 AND (SELECT dpe_descuento = 4.26 AND id_usuario_descuento = t_u('vende')
                      FROM detalle_pedido WHERE id_pedido = v),
                 'lista 29.90 → pactado 25.00; descuento calculado 4.26 sin IVA ('
                 || (SELECT pct_descuento FROM v_detalle_pedido_valor WHERE id_pedido = v) || ' %)');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(102, 'Negociación', 'Si el IVA no permite el valor exacto, queda al centavo inferior (no cobra de más)');
DO $$ DECLARE v INTEGER; BEGIN
    v := fn_crear_pedido(t_cli('Taller Uno'), 'TDA', t_linea('PEG-1L', 'Unidad', 1), t_u('vende'), 'T-NEG-2');
    PERFORM fn_negociar_linea(t_lin('T-NEG-2', 'PEG-1L', 'Unidad'), 10.00, t_u('vende'));
    PERFORM t_ok(t_total(v) = 9.99, 'pactado 10.00 → factura 9.99 (8.70 + 1.31 daría 10.01)');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(103, 'Negociación', 'Por WhatsApp el valor final se puede indicar al crear el pedido');
DO $$ DECLARE v INTEGER; BEGIN
    v := fn_crear_pedido(t_cli('Pablo'), 'WSP',
                         jsonb_build_array(jsonb_build_object('id_presentacion', t_pres('HIL-1', 'Unidad'),
                                                              'cantidad', 10, 'valor_final', 18.00)),
                         t_u('vende'), 'T-NEG-WSP');
    PERFORM t_ok(t_total(v) = 18.00
                 AND (SELECT dpe_descuento = 3.00 AND id_usuario_descuento = t_u('vende') FROM detalle_pedido WHERE id_pedido = v),
                 'lista 21.00 → 18.00, descuento 3.00 autorizado por el vendedor');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(104, 'Negociación', 'Un pedido del e-commerce no se puede negociar');
DO $$ DECLARE v INTEGER; v_msg TEXT; BEGIN
    v := fn_crear_pedido(t_cli('Ana'), 'WEB', t_linea('HIL-1', 'Unidad', 1), NULL, 'T-NEG-WEB');
    BEGIN
        PERFORM fn_negociar_linea(t_lin('T-NEG-WEB', 'HIL-1', 'Unidad'), 1.00, t_u('vende'));
        v_msg := 'No se rechazó';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    PERFORM t_rechazo(v_msg, 'solo se permiten en tienda o WhatsApp');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(105, 'Negociación', 'Ni escribiendo directo en la tabla se acepta un descuento en un pedido web');
DO $$ BEGIN
    UPDATE detalle_pedido SET dpe_descuento = 0.50, id_usuario_descuento = t_u('admin') WHERE id_pedido = t_ped('T-NEG-WEB');
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'solo se permiten en tienda o WhatsApp');
END $$;

CALL t_inicio(106, 'Negociación', 'Un usuario sin permiso no puede negociar precios');
DO $$ BEGIN
    PERFORM fn_negociar_linea(t_lin('T-NEG-1', 'SIN-NEG', 'Metro'), 24.00, t_u('bodega'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'no tiene el permiso PRECIO_NEGOCIAR');
END $$;

CALL t_inicio(107, 'Negociación', 'Un valor pactado mayor al precio de lista se rechaza');
DO $$ BEGIN
    PERFORM fn_negociar_linea(t_lin('T-NEG-1', 'SIN-NEG', 'Metro'), 50.00, t_u('vende'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'supera el precio de lista');
END $$;

CALL t_inicio(108, 'Negociación', 'Negociar el total del pedido reparte el descuento entre líneas con IVA distinto');
DO $$ DECLARE v INTEGER; v_total NUMERIC; BEGIN
    v := fn_crear_pedido(t_cli('Taller Uno'), 'TDA',
                         t_linea('SIN-NEG', 'Metro', 2) || t_linea('HIL-1', 'Unidad', 5), t_u('vende'), 'T-NEG-TOTAL');
    v_total := fn_negociar_pedido(v, 23.00, t_u('vende'));
    PERFORM t_ok(v_total = 23.00
                 AND (SELECT COUNT(*) FROM detalle_pedido WHERE id_pedido = v AND dpe_descuento > 0) = 2,
                 'lista 25.45 → 23.00: ' || (SELECT STRING_AGG(var_sku || ' ' || valor_final_con_iva, ', ' ORDER BY var_sku)
                                             FROM (SELECT v2.var_sku, dv.base_imponible + dv.iva AS valor_final_con_iva
                                                   FROM v_detalle_pedido_valor dv JOIN variante v2 USING (id_variante)
                                                   WHERE dv.id_pedido = v) x));
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(109, 'Negociación', 'Después de pagar y facturar ya no se renegocia');
DO $$ DECLARE v INTEGER := t_ped('T-NEG-TOTAL'); v_msg TEXT; BEGIN
    PERFORM fn_registrar_pago(v, t_met('Efectivo'), t_total(v), t_u('vende'));
    PERFORM fn_facturar_pedido(v, t_dfa('1790000001001'), t_punto('001'), t_u('vende'));
    BEGIN
        PERFORM fn_negociar_pedido(v, 20.00, t_u('vende'));
        v_msg := 'No se rechazó';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    PERFORM t_rechazo(v_msg, 'ya no se puede modificar');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(110, 'Negociación', 'El reporte muestra precio de lista, valor final, % y quién autorizó; la factura lleva el descuento');
DO $$ BEGIN
    PERFORM t_ok((SELECT COUNT(*) = 2 AND BOOL_AND(autorizado_por = 'Vende Prueba' AND comprobante_venta IS NOT NULL AND pct_descuento > 0)
                  FROM v_negociaciones WHERE id_pedido = t_ped('T-NEG-TOTAL'))
                 AND (SELECT descuento FROM v_comprobante_venta WHERE id_comprobante_venta = t_fac('T-NEG-TOTAL'))
                   = (SELECT SUM(dpe_descuento) FROM detalle_pedido WHERE id_pedido = t_ped('T-NEG-TOTAL')),
                 (SELECT STRING_AGG(var_sku || ' ' || pct_descuento || ' %', ', ' ORDER BY var_sku)
                  FROM v_negociaciones WHERE id_pedido = t_ped('T-NEG-TOTAL')));
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;


-- =====================================================================
-- L. AVANCES Y DEUDA DE CLIENTES (111-115)
-- =====================================================================

CALL t_inicio(111, 'Deuda clientes', 'Avance para comprar en otro local: con motivo, sin productos y sin tocar el inventario');
DO $$ DECLARE v_stock NUMERIC; v_fac NUMERIC; BEGIN
    SELECT SUM(stock_fisico) INTO v_stock FROM v_stock_variante;
    SELECT total INTO v_fac FROM v_comprobante_venta WHERE id_comprobante_venta = t_fac('T-NEG-TOTAL');
    PERFORM fn_registrar_avance(t_ped('T-NEG-TOTAL'), 20, 'Suela para un pedido urgente', t_met('Efectivo'), 10, t_u('admin'),
                                (SELECT id_motivo_avance FROM motivo_avance WHERE mav_nombre = 'Compra en otro establecimiento'));
    PERFORM t_ok((SELECT SUM(stock_fisico) FROM v_stock_variante) = v_stock
                 AND (SELECT total FROM v_comprobante_venta WHERE id_comprobante_venta = t_fac('T-NEG-TOTAL')) = v_fac
                 AND (SELECT motivo FROM v_cuentas_por_cobrar WHERE id_cuenta_por_cobrar = t_cxc('T-NEG-TOTAL', 'AVANCE'))
                     = 'Compra en otro establecimiento',
                 'deuda ' || t_deuda('Taller Uno') || '; inventario y factura sin cambio');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(112, 'Deuda clientes', 'Un avance sin motivo no se acepta');
DO $$ BEGIN
    INSERT INTO cuenta_por_cobrar (id_pedido, cxc_tipo, cxc_monto, cxc_concepto, cxc_fecha_vencimiento,
                                   id_metodo_entrega, id_usuario_autoriza)
    VALUES (t_ped('T-NEG-TOTAL'), 'AVANCE', 5, 'Sin motivo', CURRENT_DATE + 5, t_met('Efectivo'), t_u('admin'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'ckt_cuenta_por_cobrar');
END $$;

CALL t_inicio(113, 'Deuda clientes', 'Se busca al cliente por su RUC y se ve cuánto debe exactamente');
DO $$ BEGIN
    PERFORM t_ok((SELECT COUNT(*) = 1 AND MIN(cliente) = 'Taller Uno' AND MIN(deuda_total) = 20.00
                  FROM fn_buscar_deuda_cliente('1790000001001')),
                 (SELECT cliente || ': debe ' || deuda_total || ', vence ' || proximo_vencimiento
                  FROM fn_buscar_deuda_cliente('1790000001001')));
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(114, 'Deuda clientes', 'La búsqueda por nombre no distingue mayúsculas y no trae a otros clientes');
DO $$ BEGIN
    PERFORM t_ok((SELECT COUNT(*) = 1 AND MIN(cliente) = 'Taller Uno' FROM fn_buscar_deuda_cliente('TALLER UNO')),
                 (SELECT STRING_AGG(cliente, ', ') FROM fn_buscar_deuda_cliente('TALLER UNO')));
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(115, 'Deuda clientes', 'El estado de cuenta (cargos y abonos) cuadra con la deuda y nunca queda negativo');
DO $$ BEGIN
    PERFORM t_ok((SELECT SUM(cargo) - SUM(abono) = t_deuda('Taller Uno') AND BOOL_AND(saldo >= 0)
                  FROM v_estado_cuenta_movimientos WHERE id_cliente = t_cli('Taller Uno')),
                 (SELECT COUNT(*) || ' movimientos, cargos ' || SUM(cargo) || ', abonos ' || SUM(abono)
                  FROM v_estado_cuenta_movimientos WHERE id_cliente = t_cli('Taller Uno')));
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;


-- =====================================================================
-- M. PROVEEDORES E HISTORIAL DE COSTOS (116-120)
-- =====================================================================

CALL t_inicio(116, 'Proveedores', 'Mercadería recibida sin factura aparece como deuda por facturar');
DO $$ BEGIN
    PERFORM t_ok((SELECT total_estimado FROM v_recepciones_por_facturar rf
                  JOIN detalle_movimiento dm ON dm.id_movimiento = rf.id_movimiento
                  WHERE dm.id_lote = t_lote('L-SIN-2')) = 143.18
                 AND (SELECT por_facturar_estimado > 0 FROM v_estado_cuenta_proveedor WHERE proveedor = 'CURTIEMBRE DE PRUEBA'),
                 '30 m a 4.15 = 124.50 + IVA 18.68; por facturar del proveedor: '
                 || (SELECT por_facturar_estimado FROM v_estado_cuenta_proveedor WHERE proveedor = 'CURTIEMBRE DE PRUEBA'));
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(117, 'Proveedores', 'La factura que llega después se asocia a la recepción y cuadra con lo recibido');
DO $$ DECLARE v_mov INTEGER; v_fp INTEGER; v_saldo NUMERIC; BEGIN
    SELECT dm.id_movimiento INTO v_mov FROM detalle_movimiento dm JOIN movimiento_inventario m USING (id_movimiento)
    WHERE dm.id_lote = t_lote('L-SIN-2') AND m.id_tipo_movimiento = 'COM';
    SELECT saldo_facturas INTO v_saldo FROM v_estado_cuenta_proveedor WHERE proveedor = 'CURTIEMBRE DE PRUEBA';
    INSERT INTO comprobante_compra (id_proveedor, cco_numero, cco_fecha_emision, cco_fecha_vencimiento,
                                   cco_subtotal_gravado, cco_iva, id_usuario_registra)
    SELECT id_proveedor, '001-001-000000102', CURRENT_DATE - 19, CURRENT_DATE + 11, 124.50, 18.68, t_u('compras')
    FROM proveedor WHERE prv_identificacion = '1891111111001'
    RETURNING id_comprobante_compra INTO v_fp;
    PERFORM fn_asociar_comprobante_compra(v_mov, v_fp, t_u('compras'));
    PERFORM t_ok((SELECT estado FROM v_conciliacion_compra WHERE id_comprobante_compra = v_fp) = 'CUADRA'
                 AND NOT EXISTS (SELECT 1 FROM v_recepciones_por_facturar WHERE id_movimiento = v_mov)
                 AND (SELECT saldo_facturas FROM v_estado_cuenta_proveedor WHERE proveedor = 'CURTIEMBRE DE PRUEBA') = v_saldo + 143.18,
                 'factura 001-001-000000102 asociada; conciliación CUADRA');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(118, 'Proveedores', 'No se asocia la factura de un proveedor a mercadería de otro');
DO $$ BEGIN
    PERFORM fn_asociar_comprobante_compra(
        (SELECT dm.id_movimiento FROM detalle_movimiento dm JOIN movimiento_inventario m USING (id_movimiento)
         WHERE dm.id_lote = t_lote('L-PEG-1') AND m.id_tipo_movimiento = 'COM'),
        (SELECT id_comprobante_compra FROM comprobante_compra WHERE cco_numero = '001-001-000000101'), t_u('compras'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'no corresponde al proveedor');
END $$;

CALL t_inicio(119, 'Proveedores', 'La nota de crédito del proveedor por la devolución baja la deuda; una excesiva se rechaza');
DO $$ DECLARE v_fp INTEGER; v_msg TEXT; BEGIN
    SELECT id_comprobante_compra INTO v_fp FROM comprobante_compra WHERE cco_numero = '001-001-000000102';
    PERFORM fn_registrar_nc_proveedor(v_fp, '001-001-000000501', CURRENT_DATE, 0, 8.30, 1.25,
                                      'Devolución de 2 m con fallas de tintura', t_u('compras'));
    BEGIN
        PERFORM fn_registrar_nc_proveedor(v_fp, '001-001-000000502', CURRENT_DATE, 0, 500, 75, 'Prueba', t_u('compras'));
        v_msg := 'No se rechazó';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    PERFORM t_ok((SELECT saldo FROM v_cuentas_por_pagar WHERE id_comprobante_compra = v_fp) = 133.63
                 AND v_msg ILIKE '%supera lo facturado%',
                 'saldo 143.18 - 9.55 = 133.63; NC excesiva: ' || v_msg);
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(120, 'Proveedores', 'Historial de costos de compra y de precios de venta listos para tabla y gráfica');
DO $$ BEGIN
    PERFORM t_ok((SELECT COUNT(*) = 2 AND MAX(variacion_pct) = 1.22 AND BOOL_AND(proveedor = 'CURTIEMBRE DE PRUEBA')
                  FROM v_historial_costo_compra WHERE var_sku = 'SIN-NEG')
                 AND (SELECT comprobante_compra FROM v_historial_costo_compra
                      WHERE var_sku = 'SIN-NEG' AND codigo_lote = 'L-SIN-2') = '001-001-000000102'
                 AND (SELECT COUNT(*) = 2 AND BOOL_OR(programado) AND BOOL_OR(vigente)
                      FROM v_historial_precio_venta WHERE var_sku = 'SIN-NEG' AND presentacion = 'Metro'),
                 (SELECT STRING_AGG(fecha::DATE || ' ' || costo_unitario || COALESCE(' (' || variacion_pct || ' %)', ''), ' → '
                                    ORDER BY fecha)
                  FROM v_historial_costo_compra WHERE var_sku = 'SIN-NEG'));
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;


-- =====================================================================
-- N. OFERTAS (121-129)
-- =====================================================================
CREATE FUNCTION t_prd(p TEXT) RETURNS INTEGER LANGUAGE sql STABLE AS
$$ SELECT id_producto FROM producto WHERE prd_codigo = p $$;
CREATE FUNCTION t_oferta(p TEXT) RETURNS INTEGER LANGUAGE sql STABLE AS
$$ SELECT MAX(id_oferta) FROM oferta WHERE ofe_descripcion = p $$;

CALL t_inicio(121, 'Ofertas', 'Un vendedor no puede crear ofertas (solo quien gestiona precios)');
DO $$ BEGIN
    PERFORM fn_registrar_oferta(t_prd('PEG'), 10, t_u('vende'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'no tiene el permiso PRECIO_GESTIONAR');
END $$;

CALL t_inicio(122, 'Ofertas', 'El administrador publica una oferta del 10 % y el catálogo muestra el precio con oferta');
DO $$ DECLARE r RECORD; BEGIN
    PERFORM fn_registrar_oferta(t_prd('PEG'), 10, t_u('admin'), LOCALTIMESTAMP - INTERVAL '1 hour', NULL, 'Promo pegamento');
    SELECT * INTO r FROM v_catalogo WHERE var_sku = 'PEG-1L' AND presentacion = 'Unidad';
    PERFORM t_ok(r.pct_oferta = 10 AND r.precio = 9.80 AND r.precio_final = 8.82 AND r.precio_final_con_iva = 10.14
                 AND (SELECT precio_final FROM v_catalogo WHERE var_sku = 'PEG-1L' AND presentacion = 'Caja x 4') = 32.40,
                 'Unidad: 9.80 → ' || r.precio_final || ' (' || r.precio_final_con_iva || ' con IVA); caja: 36.00 → 32.40');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(123, 'Ofertas', 'La venta web toma la oferta sola: el carrito no lleva precios ni descuentos');
DO $$ DECLARE v_car INTEGER; v INTEGER; r RECORD; BEGIN
    INSERT INTO carrito (id_cliente) VALUES (t_cli('Ana')) RETURNING id_carrito INTO v_car;
    INSERT INTO item_carrito (id_carrito, id_presentacion, ica_cantidad) VALUES (v_car, t_pres('PEG-1L', 'Unidad'), 2);
    v := fn_crear_pedido_desde_carrito(v_car, 'T-OFE-WEB');
    SELECT * INTO r FROM v_detalle_pedido_valor WHERE id_pedido = v;
    PERFORM t_ok(r.id_oferta = t_oferta('Promo pegamento') AND r.descuento_oferta = 1.96 AND r.dpe_descuento = 0
                 AND r.base_imponible = 17.64 AND t_total(v) = 20.29,
                 'lista 19.60 − oferta ' || r.descuento_oferta || ' = ' || r.base_imponible || ' + IVA = ' || t_total(v));
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(124, 'Ofertas', 'Al comprar no se puede elegir una oferta que no corresponde (ni escribiendo en la tabla)');
DO $$ DECLARE v INTEGER; BEGIN
    v := fn_crear_pedido(t_cli('Ana'), 'WEB', t_linea('HIL-1', 'Unidad', 1), NULL, 'T-OFE-TRAMPA');
    INSERT INTO detalle_pedido (id_pedido, id_presentacion, dpe_cantidad, dpe_precio_unitario, id_tarifa_iva, id_oferta)
    VALUES (v, t_pres('SIN-NEG', 'Metro'), 1, 6.50, '4', t_oferta('Promo pegamento'));
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'no está vigente para este producto');
END $$;

CALL t_inicio(125, 'Ofertas', 'Dos ofertas activas del mismo producto no se solapan');
DO $$ BEGIN
    PERFORM fn_registrar_oferta(t_prd('PEG'), 15, t_u('admin'), LOCALTIMESTAMP + INTERVAL '2 days', NULL, 'Otra promo');
    PERFORM t_ok(FALSE, 'No se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_rechazo(SQLERRM, 'ya tiene una oferta activa en ese período');
END $$;

CALL t_inicio(126, 'Ofertas', 'Una oferta ya usada no cambia su porcentaje; se pausa y la venta siguiente va sin oferta');
DO $$ DECLARE v_msg TEXT; v INTEGER; BEGIN
    BEGIN
        UPDATE oferta SET ofe_porcentaje = 20 WHERE id_oferta = t_oferta('Promo pegamento');
        v_msg := 'se aceptó el cambio';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    PERFORM fn_cambiar_estado_oferta(t_oferta('Promo pegamento'), FALSE, t_u('admin'));
    v := fn_crear_pedido(t_cli('Taller Uno'), 'TDA', t_linea('PEG-1L', 'Unidad', 1), t_u('vende'), 'T-OFE-PAUSA');
    PERFORM t_ok(v_msg ILIKE '%solo se puede pausar%'
                 AND (SELECT id_oferta IS NULL AND descuento_oferta = 0 FROM v_detalle_pedido_valor WHERE id_pedido = v),
                 'cambio rechazado; pausada: la venta siguiente sale a 9.80');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(127, 'Ofertas', 'En tienda la negociación parte del precio con oferta y no lo puede superar');
DO $$ DECLARE v INTEGER; r RECORD; v_msg TEXT; BEGIN
    PERFORM fn_registrar_oferta(t_prd('SIN'), 20, t_u('admin'), LOCALTIMESTAMP - INTERVAL '1 hour', NULL, 'Liquidación sintético');
    v := fn_crear_pedido(t_cli('Taller Uno'), 'TDA', t_linea('SIN-NEG', 'Metro', 2), t_u('vende'), 'T-OFE-NEG');
    BEGIN
        PERFORM fn_negociar_linea(t_lin('T-OFE-NEG', 'SIN-NEG', 'Metro'), 12.50, t_u('vende'));
        v_msg := 'se aceptó';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    PERFORM fn_negociar_linea(t_lin('T-OFE-NEG', 'SIN-NEG', 'Metro'), 11.00, t_u('vende'));
    SELECT * INTO r FROM v_detalle_pedido_valor WHERE id_pedido = v;
    PERFORM t_ok(v_msg ILIKE '%la negociación solo baja el precio%'
                 AND r.descuento_oferta = 2.60 AND r.dpe_descuento = 0.84 AND r.base_imponible = 9.56 AND t_total(v) = 10.99,
                 'lista 13.00 − oferta 2.60 − negociado ' || r.dpe_descuento || ' = ' || r.base_imponible
                 || ' (' || t_total(v) || ' con IVA); 12.50 se rechazó');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(128, 'Ofertas', 'La nota de crédito de una línea con oferta devuelve el precio con oferta');
DO $$ DECLARE f INTEGER; n INTEGER; r RECORD; BEGIN
    PERFORM fn_registrar_pago(t_ped('T-OFE-WEB'), t_met('Pago en línea (pasarela)'), t_total(t_ped('T-OFE-WEB')), t_u('sistema'));
    f := fn_facturar_pedido(t_ped('T-OFE-WEB'), t_dfa('1700000101'), t_punto('002'), t_u('sistema'));
    n := fn_emitir_nota_credito(f, t_mot('Producto defectuoso'), t_u('admin'), t_punto('001'),
                                jsonb_build_array(jsonb_build_object('id_detalle_pedido', t_lin('T-OFE-WEB', 'PEG-1L', 'Unidad'),
                                                                     'cantidad', 1)), 'T-NC-OFE');
    SELECT * INTO r FROM v_nota_credito WHERE id_nota_credito = n;
    PERFORM t_ok(r.subtotal = 8.82 AND r.iva = 1.32 AND r.total = 10.14,
                 'devuelve 1 de 2: ' || r.subtotal || ' + IVA ' || r.iva || ' = ' || r.total || ' (no 9.80 de lista)');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(129, 'Ofertas', 'Una oferta programada no se aplica antes de su inicio; el reporte muestra el estado de cada una');
DO $$ DECLARE v INTEGER; BEGIN
    PERFORM fn_registrar_oferta(t_prd('HIL'), 5, t_u('admin'), LOCALTIMESTAMP + INTERVAL '7 days', NULL, 'Hilo próxima semana');
    v := fn_crear_pedido(t_cli('Taller Uno'), 'TDA', t_linea('HIL-1', 'Unidad', 1), t_u('vende'), 'T-OFE-PROG');
    PERFORM t_ok((SELECT id_oferta IS NULL FROM detalle_pedido WHERE id_pedido = v)
                 AND (SELECT estado FROM v_oferta WHERE id_oferta = t_oferta('Hilo próxima semana')) = 'PROGRAMADA'
                 AND (SELECT estado = 'PAUSADA' AND lineas_vendidas = 1 AND descuento_otorgado = 1.96
                      FROM v_oferta WHERE id_oferta = t_oferta('Promo pegamento'))
                 AND (SELECT estado FROM v_oferta WHERE id_oferta = t_oferta('Liquidación sintético')) = 'VIGENTE',
                 (SELECT STRING_AGG(prd_codigo || ' ' || porcentaje || ' % ' || estado, ', ' ORDER BY id_oferta) FROM v_oferta));
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;


-- =====================================================================
-- O. BITÁCORA Y AUDITORÍA (130-135)
-- =====================================================================

CALL t_inicio(130, 'Auditoría', 'Un cambio directo del límite de crédito queda en la auditoría con quién lo hizo');
DO $$ DECLARE r RECORD; BEGIN
    PERFORM fn_usuario_sesion(t_u('admin'));
    UPDATE cliente SET cli_limite_credito = 600 WHERE id_cliente = t_cli('Taller Uno');
    SELECT * INTO r FROM auditoria
    WHERE aud_tabla = 'cliente' AND aud_id_registro = t_cli('Taller Uno')::TEXT ORDER BY id_auditoria DESC LIMIT 1;
    PERFORM t_ok(r.aud_operacion = 'U' AND r.id_usuario = t_u('admin')
                 AND (r.aud_valores_anteriores::JSONB ->> 'cli_limite_credito')::NUMERIC = 400
                 AND (r.aud_valores_nuevos::JSONB ->> 'cli_limite_credito')::NUMERIC = 600,
                 'cliente ' || r.aud_id_registro || ': límite 400 → 600 por admin@prueba.ec (' || r.aud_usuario_bd || ')');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(131, 'Auditoría', 'La auditoría nunca guarda hashes de clave: un cambio de clave queda como "(cambiada)"');
DO $$ DECLARE r RECORD; BEGIN
    UPDATE usuario SET usu_hash_clave = 'hash-nuevo-secreto' WHERE id_usuario = t_u('vende');
    SELECT * INTO r FROM auditoria
    WHERE aud_tabla = 'usuario' AND aud_id_registro = t_u('vende')::TEXT ORDER BY id_auditoria DESC LIMIT 1;
    PERFORM t_ok(r.aud_valores_anteriores::JSONB ->> 'usu_hash_clave' = '(oculta)'
                 AND r.aud_valores_nuevos::JSONB ->> 'usu_hash_clave' = '(cambiada)'
                 AND NOT EXISTS (SELECT 1 FROM auditoria WHERE aud_valores_nuevos LIKE '%hash-nuevo-secreto%'
                                                            OR aud_valores_anteriores LIKE '%hash-nuevo-secreto%'),
                 'usu_hash_clave: ' || (r.aud_valores_anteriores::JSONB ->> 'usu_hash_clave') || ' → '
                 || (r.aud_valores_nuevos::JSONB ->> 'usu_hash_clave'));
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(132, 'Auditoría', 'Los accesos del personal quedan en la bitácora (válido, fallido y bloqueado)');
DO $$ DECLARE v_aud BIGINT; v_ok INTEGER; v_eventos TEXT; BEGIN
    SELECT COUNT(*) INTO v_aud FROM auditoria;
    v_ok := fn_registrar_acceso('Vende@Prueba.ec', TRUE, '10.0.0.5');
    PERFORM fn_registrar_acceso('vende@prueba.ec', FALSE, '10.0.0.5');
    PERFORM fn_registrar_acceso('inactivo@prueba.ec', TRUE, '10.0.0.9');
    PERFORM fn_registrar_acceso('nadie@prueba.ec', TRUE, '10.0.0.9');
    SELECT STRING_AGG(lev_evento, ', ' ORDER BY id_log_evento) INTO v_eventos
    FROM log_evento WHERE lev_origen = 'SEGURIDAD';
    PERFORM t_ok(v_ok = t_u('vende')
                 AND v_eventos = 'LOGIN_OK, LOGIN_FALLIDO, LOGIN_BLOQUEADO, LOGIN_FALLIDO'
                 AND (SELECT usu_ultimo_acceso IS NOT NULL FROM usuario WHERE id_usuario = t_u('vende'))
                 AND (SELECT COUNT(*) FROM auditoria) = v_aud,
                 v_eventos || '; el último acceso no generó auditoría');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(133, 'Auditoría', 'Un rechazo del SRI queda como error en la bitácora');
DO $$ DECLARE f INTEGER; r RECORD; BEGIN
    f := t_vender('Taller Uno', 'TDA', t_linea('HIL-1', 'Unidad', 1), 'vende', '1790000001001', '001', 'T-SRI-LOG');
    PERFORM fn_registrar_respuesta_sri('FACTURA', f, 'RECHAZADA', t_u('sistema'));
    SELECT * INTO r FROM log_evento WHERE lev_origen = 'SRI' ORDER BY id_log_evento DESC LIMIT 1;
    PERFORM t_ok(r.lev_nivel = 'ERROR' AND r.lev_evento = 'SRI_RECHAZADA' AND r.id_usuario = t_u('sistema')
                 AND (r.lev_detalle::JSONB ->> 'id')::INTEGER = f,
                 r.lev_nivel || ' ' || r.lev_evento || ': ' || r.lev_mensaje);
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(134, 'Auditoría', 'La bitácora y la auditoría no se editan ni se borran');
DO $$ DECLARE m1 TEXT; m2 TEXT; BEGIN
    BEGIN UPDATE log_evento SET lev_mensaje = 'x'; m1 := 'se aceptó'; EXCEPTION WHEN OTHERS THEN m1 := SQLERRM; END;
    BEGIN DELETE FROM auditoria; m2 := 'se aceptó'; EXCEPTION WHEN OTHERS THEN m2 := SQLERRM; END;
    PERFORM t_ok(m1 ILIKE '%solo se inserta%' AND m2 ILIKE '%solo se inserta%', m1);
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(135, 'Auditoría', 'Cada factura y nota de crédito emitidas quedan en la bitácora');
DO $$ DECLARE nf BIGINT; nn BIGINT; lf BIGINT; ln BIGINT; BEGIN
    SELECT COUNT(*) INTO nf FROM comprobante_venta;
    SELECT COUNT(*) INTO nn FROM nota_credito;
    SELECT COUNT(*) FILTER (WHERE lev_evento = 'FACTURA_EMITIDA'), COUNT(*) FILTER (WHERE lev_evento = 'NC_EMITIDA')
      INTO lf, ln FROM log_evento;
    PERFORM t_ok(nf = lf AND nn = ln AND nf > 0 AND nn > 0,
                 nf || ' facturas y ' || nn || ' notas de crédito, todas en la bitácora');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;


-- =====================================================================
-- P. NODOS PRODUCCIÓN Y E-COMMERCE (136-141)
-- =====================================================================

CALL t_inicio(136, 'Nodos', 'Cada tabla está en su nodo y producción no referencia nada del e-commerce');
DO $$ DECLARE np INTEGER; ne INTEGER; v_mal INTEGER; v_cruzadas TEXT; BEGIN
    SELECT COUNT(*) FILTER (WHERE table_schema = 'produccion'), COUNT(*) FILTER (WHERE table_schema = 'ecommerce')
      INTO np, ne FROM information_schema.tables
    WHERE table_type = 'BASE TABLE' AND table_schema IN ('produccion', 'ecommerce');
    SELECT COUNT(*) INTO v_mal
    FROM pg_constraint c JOIN pg_class h ON h.oid = c.conrelid JOIN pg_class p ON p.oid = c.confrelid
    WHERE c.contype = 'f' AND h.relnamespace = 'produccion'::regnamespace AND p.relnamespace = 'ecommerce'::regnamespace;
    SELECT STRING_AGG(c.conname, ', ' ORDER BY c.conname) INTO v_cruzadas
    FROM pg_constraint c JOIN pg_class h ON h.oid = c.conrelid JOIN pg_class p ON p.oid = c.confrelid
    WHERE c.contype = 'f' AND h.relnamespace <> p.relnamespace;
    PERFORM t_ok(np = 57 AND ne = 4 AND v_mal = 0
                 AND v_cruzadas = 'fkx_carrito_cliente, fkx_carrito_pedido, fkx_cuenta_web_cliente, fkx_item_carrito_presentacion',
                 np || ' tablas en produccion, ' || ne || ' en ecommerce; entre nodos solo ' || v_cruzadas);
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(137, 'Nodos', 'Las funciones y vistas de producción no ven el esquema del e-commerce');
DO $$ DECLARE nf INTEGER; v_mal INTEGER; BEGIN
    SELECT COUNT(*), COUNT(*) FILTER (WHERE NOT (proconfig @> ARRAY['search_path=produccion, public'])
                                         OR array_to_string(proconfig, ',') ILIKE '%ecommerce%')
      INTO nf, v_mal
    FROM pg_proc WHERE pronamespace = 'produccion'::regnamespace;
    v_mal := v_mal + (SELECT COUNT(*) FROM pg_views WHERE schemaname = 'produccion' AND definition ILIKE '%ecommerce.%');
    PERFORM t_ok(nf > 50 AND v_mal = 0, nf || ' funciones de producción, todas limitadas a su esquema');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(138, 'Nodos', 'Registro web: el cliente se crea en producción y la cuenta en el e-commerce; correo repetido se rechaza');
DO $$ DECLARE c INTEGER; v_msg TEXT; BEGIN
    c := fn_registrar_cuenta_web('Lucía', 'Mora', ' Lucia@Prueba.ec ', '$2b$hash', '0991112233', '200.1.1.1');
    BEGIN
        PERFORM fn_registrar_cuenta_web('Otra', NULL, 'lucia@prueba.ec', '$2b$hash');
        v_msg := 'se aceptó';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    PERFORM t_ok((SELECT cw.cwe_correo = 'lucia@prueba.ec' AND cl.cli_correo = 'lucia@prueba.ec'
                  FROM cuenta_web cw JOIN cliente cl USING (id_cliente) WHERE cw.id_cuenta_web = c)
                 AND EXISTS (SELECT 1 FROM telefono WHERE id_cliente = t_cli('Lucía') AND tel_numero = '0991112233')
                 AND EXISTS (SELECT 1 FROM log_evento_web WHERE id_cuenta_web = c AND lew_evento = 'REGISTRO')
                 AND v_msg ILIKE '%Ya existe una cuenta%',
                 'cuenta ' || c || ' del cliente ' || t_cli('Lucía') || '; repetido: ' || v_msg);
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(139, 'Nodos', 'Un cliente de tienda que abre su cuenta web conserva su historial y su crédito');
DO $$ DECLARE c INTEGER; r RECORD; BEGIN
    c := fn_registrar_cuenta_web('Taller Uno', NULL, 'uno@prueba.ec', '$2b$hash');
    SELECT * INTO r FROM v_cuenta_web WHERE id_cuenta_web = c;
    PERFORM t_ok(r.id_cliente = t_cli('Taller Uno') AND r.compras > 0
                 AND (SELECT COUNT(*) FROM cliente WHERE cli_correo = 'uno@prueba.ec') = 1,
                 'misma ficha de cliente: ' || r.compras || ' compras, segmento ' || r.segmento);
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(140, 'Nodos', 'Confirmar el carrito crea el pedido en producción y cierra el carrito');
DO $$ DECLARE v_car INTEGER; v INTEGER; m1 TEXT; m2 TEXT; BEGIN
    INSERT INTO carrito (id_cliente) VALUES (t_cli('Lucía')) RETURNING id_carrito INTO v_car;
    INSERT INTO item_carrito (id_carrito, id_presentacion, ica_cantidad) VALUES (v_car, t_pres('HIL-1', 'Unidad'), 3);
    v := fn_crear_pedido_desde_carrito(v_car, 'T-WEB-LUCIA');
    BEGIN PERFORM fn_crear_pedido_desde_carrito(v_car); m1 := 'se aceptó'; EXCEPTION WHEN OTHERS THEN m1 := SQLERRM; END;
    BEGIN
        INSERT INTO item_carrito (id_carrito, id_presentacion, ica_cantidad) VALUES (v_car, t_pres('PEG-1L', 'Unidad'), 1);
        m2 := 'se aceptó';
    EXCEPTION WHEN OTHERS THEN m2 := SQLERRM;
    END;
    PERFORM t_ok((SELECT id_pedido FROM carrito WHERE id_carrito = v_car) = v
                 AND (SELECT id_canal_venta FROM pedido WHERE id_pedido = v) = 'WEB'
                 AND (SELECT id_cuenta_web IS NOT NULL AND estado = 'PEN' AND total = 6.30 FROM v_pedido_web WHERE id_pedido = v)
                 AND m1 ILIKE '%ya se convirtió en el pedido%' AND m2 ILIKE '%no se modifica%',
                 'carrito ' || v_car || ' → pedido ' || v || '; reintento: ' || m1);
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(141, 'Nodos', 'Accesos web en su bitácora; una cuenta desactivada no entra ni confirma carritos');
DO $$ DECLARE c INTEGER; v_car INTEGER; v_ok INTEGER; v_bloq INTEGER; m TEXT; v_eventos TEXT; BEGIN
    c := (SELECT id_cuenta_web FROM cuenta_web WHERE cwe_correo = 'lucia@prueba.ec');
    v_ok := fn_registrar_acceso_web('lucia@prueba.ec', TRUE, 'sesion-1', '200.1.1.1', 'Firefox');
    PERFORM fn_registrar_acceso_web('lucia@prueba.ec', FALSE, 'sesion-2', '200.1.1.1');
    UPDATE cuenta_web SET cwe_activa = FALSE WHERE id_cuenta_web = c;
    v_bloq := fn_registrar_acceso_web('lucia@prueba.ec', TRUE, 'sesion-3');
    INSERT INTO carrito (id_cliente) VALUES (t_cli('Lucía')) RETURNING id_carrito INTO v_car;
    INSERT INTO item_carrito (id_carrito, id_presentacion, ica_cantidad) VALUES (v_car, t_pres('HIL-1', 'Unidad'), 1);
    BEGIN PERFORM fn_crear_pedido_desde_carrito(v_car); m := 'se aceptó'; EXCEPTION WHEN OTHERS THEN m := SQLERRM; END;
    SELECT STRING_AGG(lew_evento, ', ' ORDER BY id_log_evento_web) INTO v_eventos
    FROM log_evento_web WHERE id_cuenta_web = c;
    PERFORM t_ok(v_ok = c AND v_bloq IS NULL AND m ILIKE '%desactivada%'
                 AND v_eventos = 'REGISTRO, CHECKOUT, LOGIN_OK, LOGIN_FALLIDO, LOGIN_BLOQUEADO',
                 v_eventos || '; carrito: ' || m);
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;


-- =====================================================================
-- Q. COMPROBANTES: FACTURA, NOTA DE VENTA Y SIN COMPROBANTE (142-150)
-- =====================================================================

CALL t_inicio(142, 'Comprobantes', 'Venta en tienda con nota de venta: no va al SRI, descarga el stock y el pedido queda con comprobante');
DO $$ DECLARE v INTEGER; c INTEGER; s0 NUMERIC; r RECORD; BEGIN
    v := fn_crear_pedido(t_cli('Pablo'), 'TDA', t_linea('HIL-1', 'Unidad', 2), t_u('vende'), 'T-NV-1');
    PERFORM fn_registrar_pago(v, t_met('Efectivo'), t_total(v), t_u('vende'));
    s0 := t_stock('HIL-1');
    c := fn_emitir_nota_venta(v, t_punto('001'), t_u('vende'));
    SELECT * INTO r FROM comprobante_venta WHERE id_comprobante_venta = c;
    PERFORM t_ok(r.id_tipo_comprobante = '02' AND r.cve_clave_acceso IS NULL AND r.cve_estado = 'EMITIDA'
                 AND r.id_datos_facturacion IS NULL AND t_estado(v) = 'FAC' AND t_stock('HIL-1') = s0 - 2
                 AND NOT EXISTS (SELECT 1 FROM v_cola_sri WHERE tipo = 'FACTURA' AND id = c)
                 AND (SELECT razon_social FROM v_comprobante_venta WHERE id_comprobante_venta = c) = 'Pablo'
                 AND EXISTS (SELECT 1 FROM log_evento WHERE lev_evento = 'NOTA_VENTA_EMITIDA'),
                 (SELECT tipo_comprobante || ' ' || numero || ' a ' || razon_social || ', ' || estado_sri
                  FROM v_comprobante_venta WHERE id_comprobante_venta = c) || '; fuera de la cola del SRI');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(143, 'Comprobantes', 'La nota de venta puede llevar el número impreso del talonario y ese número no se repite');
DO $$ DECLARE v INTEGER; c INTEGER; v_msg TEXT; BEGIN
    v := fn_crear_pedido(t_cli('Pablo'), 'TDA', t_linea('HIL-1', 'Unidad', 1), t_u('vende'), 'T-NV-2');
    PERFORM fn_registrar_pago(v, t_met('Efectivo'), t_total(v), t_u('vende'));
    c := fn_emitir_nota_venta(v, t_punto('001'), t_u('vende'), 351);
    v := fn_crear_pedido(t_cli('Pablo'), 'TDA', t_linea('HIL-1', 'Unidad', 1), t_u('vende'), 'T-NV-3');
    PERFORM fn_registrar_pago(v, t_met('Efectivo'), t_total(v), t_u('vende'));
    BEGIN
        PERFORM fn_emitir_nota_venta(v, t_punto('001'), t_u('vende'), 351);
        v_msg := 'se aceptó';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    PERFORM t_ok((SELECT numero FROM v_comprobante_venta WHERE id_comprobante_venta = c) = '001-001-000000351'
                 AND v_msg ILIKE '%ya fue registrada%' AND t_estado(v) = 'PAG',
                 'talonario 001-001-000000351; repetido: ' || v_msg);
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(144, 'Comprobantes', 'La factura sí va al SRI y tiene su propia numeración, separada de la nota de venta');
DO $$ DECLARE f INTEGER; v_max INTEGER; r RECORD; BEGIN
    SELECT MAX(cve_secuencial) INTO v_max FROM comprobante_venta
    WHERE id_tipo_comprobante = '01' AND id_punto_emision = t_punto('001');
    f := t_vender('Pablo', 'TDA', t_linea('HIL-1', 'Unidad', 1), 'vende', '1700000102', '001', 'T-FAC-SEP');
    SELECT * INTO r FROM comprobante_venta WHERE id_comprobante_venta = f;
    PERFORM t_ok(r.id_tipo_comprobante = '01' AND LENGTH(r.cve_clave_acceso) = 49 AND r.cve_estado = 'PENDIENTE'
                 AND r.cve_secuencial = v_max + 1 AND SUBSTR(r.cve_clave_acceso, 9, 2) = '01'
                 AND EXISTS (SELECT 1 FROM v_cola_sri WHERE tipo = 'FACTURA' AND id = f),
                 'factura n.º ' || r.cve_secuencial || ' (la nota de venta 351 no altera la serie); en cola del SRI');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(145, 'Comprobantes', 'La factura exige comprador y número automático; el recibo no sirve para vender');
DO $$ DECLARE m1 TEXT; m2 TEXT; m3 TEXT; v INTEGER := t_ped('T-NV-3'); BEGIN
    BEGIN PERFORM fn_facturar_pedido(v, NULL, t_punto('001'), t_u('vende')); m1 := 'se aceptó';
    EXCEPTION WHEN OTHERS THEN m1 := SQLERRM; END;
    BEGIN PERFORM fn_facturar_pedido(v, t_dfa('1700000102'), t_punto('001'), t_u('vende'), NULL, '01', 500); m2 := 'se aceptó';
    EXCEPTION WHEN OTHERS THEN m2 := SQLERRM; END;
    BEGIN PERFORM fn_facturar_pedido(v, t_dfa('1700000102'), t_punto('001'), t_u('vende'), NULL, '00'); m3 := 'se aceptó';
    EXCEPTION WHEN OTHERS THEN m3 := SQLERRM; END;
    PERFORM t_ok(m1 ILIKE '%exige los datos del comprador%' AND m2 ILIKE '%lo asigna el sistema%'
                 AND m3 ILIKE '%no se usa en ventas%', m1 || ' / ' || m3);
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(146, 'Comprobantes', 'Devolución sobre una nota de venta: la nota de crédito se registra sin SRI y el producto vuelve al stock');
DO $$ DECLARE n INTEGER; s0 NUMERIC; r RECORD; BEGIN
    s0 := t_stock('HIL-1');
    n := fn_emitir_nota_credito(t_fac('T-NV-1'), t_mot('Producto defectuoso'), t_u('admin'), t_punto('001'),
                                jsonb_build_array(jsonb_build_object('id_detalle_pedido', t_lin('T-NV-1', 'HIL-1', 'Unidad'),
                                                                     'cantidad', 1)), 'T-NC-NV');
    SELECT * INTO r FROM nota_credito WHERE id_nota_credito = n;
    PERFORM t_ok(r.ncr_estado = 'EMITIDA' AND r.ncr_clave_acceso IS NULL AND t_stock('HIL-1') = s0 + 1
                 AND NOT EXISTS (SELECT 1 FROM v_cola_sri WHERE tipo = 'NOTA_CREDITO' AND id = n)
                 AND (SELECT total FROM v_nota_credito WHERE id_nota_credito = n) = 2.10,
                 'nota de crédito ' || r.ncr_estado || ' por ' || (SELECT total FROM v_nota_credito WHERE id_nota_credito = n)
                 || '; stock +1; fuera de la cola del SRI');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(147, 'Comprobantes', 'Compra con nota de venta de un proveedor pequeño: sin IVA; si trae IVA se rechaza');
DO $$ DECLARE prv INTEGER; c INTEGER; v_msg TEXT; BEGIN
    INSERT INTO proveedor (id_tipo_identificacion, prv_identificacion, prv_razon_social)
    VALUES ('04', '1712345678001', 'FERRETERÍA DE BARRIO (RIMPE)') RETURNING id_proveedor INTO prv;
    c := fn_registrar_comprobante_compra(prv, '02', '001-001-000000123', CURRENT_DATE, CURRENT_DATE + 15,
                                         18.00, 0, 0, t_u('compras'));
    BEGIN
        PERFORM fn_registrar_comprobante_compra(prv, '02', '001-001-000000124', CURRENT_DATE, CURRENT_DATE + 15,
                                                0, 18.00, 2.70, t_u('compras'));
        v_msg := 'se aceptó';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    PERFORM t_ok((SELECT tipo_comprobante = 'Nota de venta' AND total = 18.00 AND saldo = 18.00
                  FROM v_cuentas_por_pagar WHERE id_comprobante_compra = c)
                 AND v_msg ILIKE '%ckt_comprobante_compra%',
                 'nota de venta 18.00 por pagar; con IVA: rechazada');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(148, 'Comprobantes', 'Compra sin comprobante (recibo): queda como deuda pero no admite nota de crédito del proveedor');
DO $$ DECLARE prv INTEGER; c INTEGER; v_msg TEXT; BEGIN
    SELECT id_proveedor INTO prv FROM proveedor WHERE prv_identificacion = '1712345678001';
    c := fn_registrar_comprobante_compra(prv, '00', 'REC-0007', CURRENT_DATE, CURRENT_DATE, 25.00, 0, 0, t_u('compras'));
    BEGIN
        PERFORM fn_registrar_nc_proveedor(c, '001-001-000000009', CURRENT_DATE, 5, 0, 0, 'Rebaja', t_u('compras'));
        v_msg := 'se aceptó';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    PERFORM t_ok((SELECT saldo_facturas FROM v_estado_cuenta_proveedor WHERE id_proveedor = prv) = 43.00
                 AND v_msg ILIKE '%no admite nota de crédito%',
                 'deuda con el proveedor 43.00 (nota de venta + recibo); NC: ' || v_msg);
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(149, 'Comprobantes', 'La factura de proveedor se registra según el SRI: número y clave de acceso se validan');
DO $$ DECLARE prv INTEGER; c INTEGER; m1 TEXT; m2 TEXT; BEGIN
    SELECT id_proveedor INTO prv FROM proveedor WHERE prv_identificacion = '1712345678001';
    BEGIN PERFORM fn_registrar_comprobante_compra(prv, '01', '123-45', CURRENT_DATE, CURRENT_DATE + 30, 0, 100, 15, t_u('compras'));
          m1 := 'se aceptó';
    EXCEPTION WHEN OTHERS THEN m1 := SQLERRM; END;
    BEGIN PERFORM fn_registrar_comprobante_compra(prv, '01', '001-001-000004700', CURRENT_DATE, CURRENT_DATE + 30, 0, 100, 15,
                                                  t_u('compras'), '123');
          m2 := 'se aceptó';
    EXCEPTION WHEN OTHERS THEN m2 := SQLERRM; END;
    c := fn_registrar_comprobante_compra(prv, '01', '001-001-000004700', CURRENT_DATE, CURRENT_DATE + 30, 0, 100, 15,
                                         t_u('compras'), REPEAT('1', 49));
    PERFORM t_ok(m1 ILIKE '%formato del SRI%' AND m2 ILIKE '%49 dígitos%'
                 AND (SELECT tipo_comprobante = 'Factura' AND total = 115 FROM v_cuentas_por_pagar WHERE id_comprobante_compra = c),
                 m1 || ' / ' || m2);
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;

CALL t_inicio(150, 'Comprobantes', 'Los reportes separan las ventas por tipo de comprobante y las notas de venta cuentan como compras del cliente');
DO $$ DECLARE nf INTEGER; nv INTEGER; BEGIN
    SELECT COUNT(*) FILTER (WHERE id_tipo_comprobante = '01'), COUNT(*) FILTER (WHERE id_tipo_comprobante = '02')
      INTO nf, nv FROM v_comprobante_venta;
    PERFORM t_ok(nv = 2 AND nf > 10
                 AND NOT EXISTS (SELECT 1 FROM v_cola_sri c JOIN comprobante_venta cv ON cv.id_comprobante_venta = c.id
                                 WHERE c.tipo = 'FACTURA' AND cv.id_tipo_comprobante <> '01')
                 AND (SELECT compras FROM v_frecuencia_cliente WHERE cliente = 'Pablo') >= 3,
                 nf || ' facturas y ' || nv || ' notas de venta; Pablo: '
                 || (SELECT compras FROM v_frecuencia_cliente WHERE cliente = 'Pablo') || ' compras');
EXCEPTION WHEN OTHERS THEN PERFORM t_error(SQLERRM);
END $$;


-- =====================================================================
-- RESULTADOS
-- =====================================================================

\set QUIET off
\echo
\echo '=================== RESULTADO DE LAS PRUEBAS ==================='
SELECT n AS "#", grupo, descripcion AS prueba,
       CASE WHEN ok THEN 'OK' WHEN ok IS NULL THEN 'SIN RESULTADO' ELSE 'FALLA' END AS resultado,
       LEFT(detalle, 110) AS detalle
FROM t_resultado ORDER BY n;

\echo '=========================== POR GRUPO ==========================='
SELECT grupo, COUNT(*) AS pruebas, COUNT(*) FILTER (WHERE ok) AS ok, COUNT(*) FILTER (WHERE ok IS NOT TRUE) AS fallas
FROM t_resultado GROUP BY grupo ORDER BY MIN(n);

SELECT COUNT(*) FILTER (WHERE ok) || ' de ' || COUNT(*) || ' pruebas OK' AS total FROM t_resultado;
