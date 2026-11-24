-- =====================================================================
--  COMERCIAL ELITE · Modelo físico corregido
--  Lógica de la base: complementos, datos base, vistas, disparadores y
--  funciones del flujo (PostgreSQL 13 o superior).
--
--  Se ejecuta DESPUÉS de crear las tablas, ya sea con
--  ComercialElite_PDM.sql o con el script que genere PowerDesigner
--  desde el modelo físico. Crea sus objetos en los esquemas de cada
--  nodo: produccion (secciones 0 a C) y ecommerce (sección D).
-- =====================================================================
--
--  0. COMPLEMENTOS    Lo propio de PostgreSQL que PowerDesigner no modela
--                     (índices únicos parciales, valores por defecto con
--                     funciones) y los datos base de los catálogos.
--  A. VISTAS          Todo dato derivado se calcula aquí (stock, saldos,
--                     antigüedad, totales, estado actual, precio vigente,
--                     frecuencia de clientes, ventas por canal...).
--  B. DISPARADORES    Reglas que se cumplen aunque se escriba directo en
--                     las tablas: kárdex inmutable, stock no negativo,
--                     pedido facturado congelado, transiciones de estado.
--  C. FUNCIONES       El flujo de negocio, con control de permisos por rol:
--       Comprobante fn_facturar_pedido (factura o nota de venta),
--                   fn_emitir_nota_venta, fn_registrar_comprobante_compra
--       Ventas      fn_crear_pedido, fn_registrar_cliente,
--                   fn_registrar_pago, fn_confirmar_pago,
--                   fn_facturar_pedido, fn_cambiar_estado_pedido
--       Negociación fn_negociar_linea, fn_negociar_pedido (tienda/WhatsApp,
--                   desde el valor final), fn_base_desde_final
--       Crédito     fn_facturar_a_credito, fn_registrar_avance,
--                   fn_registrar_abono, fn_abonar_cliente,
--                   fn_buscar_deuda_cliente
--       Devolución  fn_emitir_nota_credito
--       SRI         fn_registrar_respuesta_sri (cola: v_cola_sri)
--       Compras     fn_cambiar_estado_oc, fn_recepcionar_compra,
--                   fn_asociar_comprobante_compra, fn_registrar_nc_proveedor,
--                   fn_devolver_a_proveedor
--       Inventario  fn_registrar_ajuste, fn_fraccionar_lote,
--                   fn_consumir_lotes
--       Catálogo    fn_registrar_precio, fn_registrar_oferta,
--                   fn_cambiar_estado_oferta
--       Bitácora    fn_log, fn_registrar_acceso, fn_usuario_sesion
--       Apoyo       fn_exigir_permiso, fn_clave_acceso
--  D. NODO E-COMMERCE Cuentas web, carrito y su bitácora; vistas que
--                     leen de producción (mañana, réplicas) y funciones
--                     que le piden a producción crear clientes y pedidos:
--                     fn_registrar_cuenta_web, fn_registrar_acceso_web,
--                     fn_crear_pedido_desde_carrito, fn_log_web
--  E. CONTRATO        Roles por nodo y lo único que el e-commerce puede
--                     leer o ejecutar en producción.
--
--  OFERTAS Y DESCUENTOS
--   · En el e-commerce el único descuento es la oferta preestablecida del
--     producto (tabla oferta). Se aplica sola al crear el pedido; el
--     carrito no guarda precios ni descuentos.
--   · En tienda y WhatsApp, además, se negocia desde el valor final; la
--     negociación parte del precio que ya tiene la oferta.
--
--  COMPROBANTES
--   · Venta: factura (electrónica: clave de acceso, cola y respuesta del
--     SRI) o nota de venta (se registra con el número del talonario; no
--     pasa por el flujo electrónico). La nota de venta corresponde a
--     contribuyentes RIMPE Negocio Popular o a la nota de venta resumen:
--     usarla según el régimen tributario de la empresa.
--   · Compra: factura (número SRI, desglose de IVA y, si es electrónica,
--     clave de acceso), nota de venta o sin comprobante (recibo). Las dos
--     últimas no llevan IVA ni dan crédito tributario.
--
--  REGLAS DEL SRI CONSIDERADAS (verificar vigencia con el contador)
--   · La factura se emite al momento de la venta, aunque sea a crédito
--     (Reglamento de Comprobantes de Venta, art. 17). El crédito no
--     posterga la factura: queda como cuenta por cobrar.
--   · Desde 2026 los comprobantes se transmiten al SRI de inmediato: cada
--     factura y nota de crédito emite un aviso (pg_notify 'cola_sri') para
--     que el servicio de facturación la firme y la envíe.
--   · Facturas a consumidor final: hasta emp_max_consumidor_final (USD 50);
--     desde 2026 no se anulan ni admiten nota de crédito.
--   · El avance de dinero no es una venta: no lleva factura.
-- =====================================================================




SET search_path = produccion, public;

-- =====================================================================
-- 0. COMPLEMENTOS DE POSTGRESQL Y DATOS BASE
-- =====================================================================

-- Un cliente no repite un perfil de facturación activo
-- (los perfiles desactivados quedan como historia)
CREATE UNIQUE INDEX ux_datos_facturacion_activo
    ON datos_facturacion (id_cliente, id_tipo_identificacion, dfa_identificacion)
    WHERE dfa_activo;

-- Un pedido tiene a lo sumo una factura vigente (no anulada)
CREATE UNIQUE INDEX ux_comprobante_venta_vigente
    ON comprobante_venta (id_pedido)
    WHERE cve_estado <> 'ANULADA';

-- Un pedido tiene a lo sumo un crédito (el saldo de la venta)
CREATE UNIQUE INDEX ux_cxc_credito_pedido
    ON cuenta_por_cobrar (id_pedido)
    WHERE cxc_tipo = 'CREDITO';

-- Token del carrito generado por la base si la aplicación no lo envía
ALTER TABLE ecommerce.carrito ALTER COLUMN car_token SET DEFAULT gen_random_uuid()::TEXT;

-- Bitácora y auditoría: hora real y usuario de base de datos de la conexión
ALTER TABLE log_evento ALTER COLUMN lev_fechahora SET DEFAULT CLOCK_TIMESTAMP();
ALTER TABLE auditoria  ALTER COLUMN aud_fechahora SET DEFAULT CLOCK_TIMESTAMP();
ALTER TABLE auditoria  ALTER COLUMN aud_usuario_bd SET DEFAULT SESSION_USER;
ALTER TABLE ecommerce.log_evento_web ALTER COLUMN lew_fechahora SET DEFAULT CLOCK_TIMESTAMP();

-- Hora real de cada cambio de estado (aunque ocurran en la misma transacción)
ALTER TABLE historial_estado_pedido ALTER COLUMN hep_fechahora SET DEFAULT CLOCK_TIMESTAMP();

-- ---------------------------------------------------------------------
-- Datos base (necesarios para el flujo)
-- ---------------------------------------------------------------------
INSERT INTO tipo_identificacion VALUES
    ('04', 'RUC'),
    ('05', 'Cédula'),
    ('06', 'Pasaporte'),
    ('07', 'Consumidor final'),
    ('08', 'Identificación del exterior');

-- Códigos de porcentaje según la ficha técnica del SRI (verificar la versión vigente)
INSERT INTO tarifa_iva VALUES
    ('0', 0,  'IVA 0%',              TRUE),
    ('2', 12, 'IVA 12% (histórica)', FALSE),
    ('4', 15, 'IVA 15%',             TRUE);

INSERT INTO unidad_medida VALUES
    ('u',    'Unidad'),
    ('m',    'Metro'),
    ('m2',   'Metro cuadrado'),
    ('pie2', 'Pie cuadrado'),
    ('par',  'Par'),
    ('kg',   'Kilogramo'),
    ('l',    'Litro');

INSERT INTO canal_venta VALUES
    ('WEB', 'E-commerce'),
    ('TDA', 'Tienda física'),
    ('WSP', 'WhatsApp / teléfono');

INSERT INTO estado_pedido VALUES
    ('PEN', 'Pendiente de pago', 1),
    ('PAG', 'Pago o crédito confirmado', 2),
    ('FAC', 'Comprobante emitido', 3),
    ('DES', 'Despachado',        4),
    ('ENT', 'Entregado',         5),
    ('CAN', 'Cancelado',         6);

-- Tipos de comprobante (código SRI). Solo la factura de venta va al SRI.
INSERT INTO tipo_comprobante VALUES
    ('01', 'Factura',                  TRUE,  TRUE,  TRUE,  TRUE),
    ('02', 'Nota de venta',            TRUE,  TRUE,  FALSE, FALSE),
    ('00', 'Sin comprobante (recibo)', FALSE, TRUE,  FALSE, FALSE);

INSERT INTO metodo_pago (mpa_nombre, mpa_codigo_sri) VALUES
    ('Efectivo',                 '01'),
    ('Transferencia bancaria',   '20'),
    ('Tarjeta de débito',        '16'),
    ('Tarjeta de crédito',       '19'),
    ('Pago en línea (pasarela)', '19');

INSERT INTO motivo_avance (mav_nombre) VALUES
    ('Pasaje'),
    ('Compra en otro establecimiento'),
    ('Otro');

INSERT INTO motivo_devolucion (mde_nombre) VALUES
    ('Producto defectuoso'),
    ('Error en el despacho'),
    ('No corresponde a la descripción'),
    ('Cliente no satisfecho');

INSERT INTO tipo_movimiento VALUES
    ('INI', 'Inventario inicial',       1),
    ('COM', 'Compra (recepción)',       1),
    ('DCL', 'Devolución de cliente',    1),
    ('AJP', 'Ajuste positivo',          1),
    ('VEN', 'Venta (despacho)',        -1),
    ('DPR', 'Devolución a proveedor',  -1),
    ('AJN', 'Ajuste negativo',         -1),
    ('MER', 'Merma o daño',            -1),
    ('FRS', 'Fraccionamiento (sale la pieza)',   -1),
    ('FRE', 'Fraccionamiento (entra paquete)',    1);

INSERT INTO rol (rol_codigo, rol_nombre) VALUES
    ('ADMIN',    'Administrador'),
    ('VENDEDOR', 'Vendedor de tienda'),
    ('BODEGA',   'Bodeguero'),
    ('COMPRAS',  'Responsable de compras'),
    ('SISTEMA',  'Procesos automáticos del e-commerce');

INSERT INTO permiso (per_codigo, per_descripcion) VALUES
    ('CATALOGO_GESTIONAR', 'Crear y editar productos, variantes y presentaciones'),
    ('PRECIO_GESTIONAR',   'Registrar cambios de precio'),
    ('VENTA_REGISTRAR',    'Registrar ventas en tienda o por WhatsApp'),
    ('PAGO_REGISTRAR',     'Registrar y confirmar pagos'),
    ('VENTA_FACTURAR',     'Emitir facturas'),
    ('PEDIDO_DESPACHAR',   'Despachar y marcar pedidos como entregados'),
    ('NC_EMITIR',          'Autorizar devoluciones y emitir notas de crédito'),
    ('INV_RECEPCIONAR',    'Recibir mercadería de órdenes de compra'),
    ('INV_AJUSTAR',        'Registrar inventario inicial, ajustes y mermas'),
    ('COMPRA_GESTIONAR',   'Gestionar órdenes, facturas y devoluciones a proveedores'),
    ('CREDITO_OTORGAR',    'Vender a crédito y entregar avances de dinero'),
    ('INV_FRACCIONAR',     'Cortar piezas (bandas) en paquetes'),
    ('SRI_GESTIONAR',      'Registrar las respuestas del SRI'),
    ('USUARIO_GESTIONAR',  'Administrar usuarios y roles'),
    ('PRECIO_NEGOCIAR',    'Negociar el precio de una venta en tienda o WhatsApp'),
    ('AUDITORIA_CONSULTAR', 'Consultar la bitácora y la auditoría');

INSERT INTO rol_permiso (id_rol, id_permiso)
SELECT r.id_rol, p.id_permiso
FROM rol r
JOIN permiso p ON
       r.rol_codigo = 'ADMIN'
    OR r.rol_codigo = 'VENDEDOR' AND p.per_codigo IN ('VENTA_REGISTRAR', 'PAGO_REGISTRAR', 'VENTA_FACTURAR', 'PEDIDO_DESPACHAR', 'INV_FRACCIONAR', 'PRECIO_NEGOCIAR')
    OR r.rol_codigo = 'BODEGA'   AND p.per_codigo IN ('INV_RECEPCIONAR', 'INV_AJUSTAR', 'PEDIDO_DESPACHAR', 'INV_FRACCIONAR')
    OR r.rol_codigo = 'COMPRAS'  AND p.per_codigo IN ('COMPRA_GESTIONAR', 'INV_RECEPCIONAR')
    OR r.rol_codigo = 'SISTEMA'  AND p.per_codigo IN ('PAGO_REGISTRAR', 'VENTA_FACTURAR', 'SRI_GESTIONAR');

-- Usuario técnico que registra pagos de la pasarela y factura pedidos web
INSERT INTO usuario (usu_correo, usu_hash_clave) VALUES ('sistema@comercialelite.local', '!sin-acceso');
INSERT INTO usuario_rol (id_usuario, id_rol)
SELECT u.id_usuario, r.id_rol FROM usuario u, rol r
WHERE u.usu_correo = 'sistema@comercialelite.local' AND r.rol_codigo = 'SISTEMA';

-- Cliente genérico para ventas a consumidor final en tienda
INSERT INTO cliente (cli_nombres) VALUES ('CONSUMIDOR FINAL');
INSERT INTO datos_facturacion (id_cliente, id_tipo_identificacion, dfa_identificacion, dfa_razon_social)
SELECT id_cliente, '07', '9999999999999', 'CONSUMIDOR FINAL' FROM cliente WHERE cli_nombres = 'CONSUMIDOR FINAL';


-- =====================================================================
-- A. VISTAS
-- =====================================================================

-- Precio vigente de cada presentación (último cambio ya en vigor)
CREATE VIEW v_precio_vigente AS
SELECT DISTINCT ON (hp.id_presentacion)
       hp.id_presentacion,
       hp.hpr_precio        AS precio,
       hp.hpr_vigente_desde AS vigente_desde
FROM historial_precio hp
WHERE hp.hpr_vigente_desde <= CURRENT_TIMESTAMP
ORDER BY hp.id_presentacion, hp.hpr_vigente_desde DESC;

-- Oferta vigente de cada producto (a lo sumo una: las activas no se solapan)
CREATE VIEW v_oferta_vigente AS
SELECT o.id_oferta, o.id_producto, o.ofe_porcentaje, o.ofe_descripcion, o.ofe_desde, o.ofe_hasta
FROM oferta o
WHERE o.ofe_activa
  AND o.ofe_desde <= CURRENT_TIMESTAMP
  AND (o.ofe_hasta IS NULL OR o.ofe_hasta > CURRENT_TIMESTAMP);

-- Estado actual del pedido (último registro del historial)
CREATE VIEW v_pedido_estado_actual AS
SELECT DISTINCT ON (h.id_pedido)
       h.id_pedido,
       h.id_estado_pedido,
       e.esp_nombre    AS estado,
       h.hep_fechahora AS desde
FROM historial_estado_pedido h
JOIN estado_pedido e ON e.id_estado_pedido = h.id_estado_pedido
ORDER BY h.id_pedido, h.hep_fechahora DESC, h.id_historial_estado DESC;

-- Valor de cada línea de pedido (base imponible e IVA) y su equivalente en unidad base.
-- Descuento total = oferta (del porcentaje de la oferta aplicada) + negociado (dpe_descuento)
CREATE VIEW v_detalle_pedido_valor AS
WITH l AS (
    SELECT d.*, pr.id_variante, pr.pre_factor, t.tiv_porcentaje, o.ofe_porcentaje,
           d.dpe_cantidad * d.dpe_precio_unitario                                         AS bruto,
           ROUND(d.dpe_cantidad * d.dpe_precio_unitario * COALESCE(o.ofe_porcentaje, 0) / 100, 2) AS descuento_oferta
    FROM detalle_pedido d
    JOIN presentacion pr ON pr.id_presentacion = d.id_presentacion
    JOIN tarifa_iva   t  ON t.id_tarifa_iva    = d.id_tarifa_iva
    LEFT JOIN oferta  o  ON o.id_oferta        = d.id_oferta
)
SELECT id_detalle_pedido,
       id_pedido,
       id_presentacion,
       id_variante,
       dpe_cantidad,
       pre_factor,
       (dpe_cantidad * pre_factor)::NUMERIC(14,3)                       AS cantidad_base,
       dpe_precio_unitario,
       id_oferta,
       ofe_porcentaje                                                   AS pct_oferta,
       descuento_oferta,
       dpe_descuento,
       descuento_oferta + dpe_descuento                                 AS descuento_total,
       id_tarifa_iva,
       tiv_porcentaje,
       ROUND(bruto - descuento_oferta - dpe_descuento, 2)               AS base_imponible,
       ROUND((bruto - descuento_oferta - dpe_descuento) * tiv_porcentaje / 100, 2) AS iva,
       ROUND(bruto, 2)                                                  AS valor_lista,
       CASE WHEN bruto > 0
            THEN ROUND((descuento_oferta + dpe_descuento) * 100 / bruto, 2)
            ELSE 0 END                                                  AS pct_descuento,
       id_usuario_descuento
FROM l;

-- Totales del pedido (= totales de su factura), incluido el envío
CREATE VIEW v_pedido_totales AS
WITH lineas AS (
    SELECT id_pedido, tiv_porcentaje, base_imponible, iva, descuento_total AS descuento, FALSE AS es_envio
    FROM v_detalle_pedido_valor
    UNION ALL
    SELECT e.id_pedido, t.tiv_porcentaje, e.env_costo,
           ROUND(e.env_costo * t.tiv_porcentaje / 100, 2), 0, TRUE
    FROM envio e
    JOIN tarifa_iva t ON t.id_tarifa_iva = e.id_tarifa_iva
)
SELECT p.id_pedido,
       COALESCE(SUM(l.base_imponible) FILTER (WHERE l.tiv_porcentaje = 0), 0) AS subtotal_0,
       COALESCE(SUM(l.base_imponible) FILTER (WHERE l.tiv_porcentaje > 0), 0) AS subtotal_gravado,
       COALESCE(SUM(l.descuento), 0)                                          AS descuento,
       COALESCE(SUM(l.base_imponible) FILTER (WHERE l.es_envio), 0)           AS costo_envio,
       COALESCE(SUM(l.iva), 0)                                                AS iva,
       COALESCE(SUM(l.base_imponible + l.iva), 0)                             AS total
FROM pedido p
LEFT JOIN lineas l ON l.id_pedido = p.id_pedido
GROUP BY p.id_pedido;

-- Pagos aprobados y crédito otorgado por pedido
CREATE VIEW v_pedido_pagos AS
SELECT p.id_pedido,
       COALESCE(pg.pagado, 0)                            AS pagado,
       COALESCE(cr.credito, 0)                           AS credito,
       COALESCE(pg.pagado, 0) + COALESCE(cr.credito, 0)  AS cubierto
FROM pedido p
LEFT JOIN (SELECT id_pedido, SUM(pag_monto) AS pagado
           FROM pago WHERE pag_estado = 'APROBADO' GROUP BY id_pedido) pg ON pg.id_pedido = p.id_pedido
LEFT JOIN (SELECT id_pedido, SUM(cxc_monto) AS credito
           FROM cuenta_por_cobrar WHERE cxc_tipo = 'CREDITO' GROUP BY id_pedido) cr ON cr.id_pedido = p.id_pedido;

-- Pieza original de cada lote (un paquete cortado de una banda hereda
-- la fecha de ingreso de la banda, aunque se haya cortado después)
CREATE VIEW v_lote_raiz AS
WITH RECURSIVE r AS (
    SELECT id_lote, id_lote AS id_lote_raiz, id_lote_origen FROM lote
    UNION ALL
    SELECT r.id_lote, l.id_lote, l.id_lote_origen
    FROM r JOIN lote l ON l.id_lote = r.id_lote_origen
)
SELECT id_lote, id_lote_raiz FROM r WHERE id_lote_origen IS NULL;

-- Saldo, fecha de ingreso y antigüedad de cada lote
CREATE VIEW v_lote_saldo AS
WITH ingreso AS (
    SELECT dm.id_lote, MIN(m.mov_fechahora) AS fecha
    FROM detalle_movimiento dm
    JOIN movimiento_inventario m ON m.id_movimiento = dm.id_movimiento
    GROUP BY dm.id_lote
)
SELECT l.id_lote,
       l.id_variante,
       l.id_lote_origen,
       l.lot_codigo_proveedor,
       l.lot_costo_unitario,
       l.lot_fecha_vencimiento,
       i.fecha                                                            AS fecha_ingreso,
       SUM(dm.dmo_cantidad) FILTER (WHERE t.tmv_signo = 1)                AS entradas,
       COALESCE(SUM(dm.dmo_cantidad) FILTER (WHERE t.tmv_signo = -1), 0)  AS salidas,
       SUM(dm.dmo_cantidad * t.tmv_signo)                                 AS saldo,
       MAX(m.mov_fechahora)                                               AS ultimo_movimiento,
       CURRENT_DATE - i.fecha::DATE                                       AS dias_en_inventario
FROM lote l
JOIN v_lote_raiz           lr ON lr.id_lote       = l.id_lote
JOIN ingreso               i  ON i.id_lote        = lr.id_lote_raiz
JOIN detalle_movimiento    dm ON dm.id_lote       = l.id_lote
JOIN movimiento_inventario m  ON m.id_movimiento  = dm.id_movimiento
JOIN tipo_movimiento       t  ON t.id_tipo_movimiento = m.id_tipo_movimiento
GROUP BY l.id_lote, i.fecha;

-- Avance de recepción por línea de orden de compra
CREATE VIEW v_orden_compra_detalle AS
SELECT d.id_detalle_orden_compra,
       d.id_orden_compra,
       d.id_variante,
       v.var_sku,
       d.dco_cantidad                                         AS cantidad_pedida,
       d.dco_costo_unitario                                   AS costo_pactado,
       COALESCE(r.recibido, 0)                                AS cantidad_recibida,
       GREATEST(d.dco_cantidad - COALESCE(r.recibido, 0), 0)  AS cantidad_pendiente
FROM detalle_orden_compra d
JOIN variante v ON v.id_variante = d.id_variante
LEFT JOIN (
    SELECT id_detalle_orden_compra, SUM(dmo_cantidad) AS recibido
    FROM detalle_movimiento
    WHERE id_detalle_orden_compra IS NOT NULL
    GROUP BY id_detalle_orden_compra
) r ON r.id_detalle_orden_compra = d.id_detalle_orden_compra;

-- Estado de recepción de la orden de compra (calculado, no almacenado)
CREATE VIEW v_orden_compra_estado AS
SELECT oc.id_orden_compra,
       pr.prv_razon_social                          AS proveedor,
       oc.oc_fecha,
       oc.oc_fecha_entrega_esperada,
       oc.oc_estado,
       ROUND(SUM(d.cantidad_pedida * d.costo_pactado), 2) AS valor_pactado,
       CASE
           WHEN oc.oc_estado IN ('BORRADOR', 'ANULADA')    THEN 'NO APLICA'
           WHEN COALESCE(SUM(d.cantidad_recibida), 0) = 0  THEN 'PENDIENTE'
           WHEN SUM(d.cantidad_pendiente) = 0              THEN 'COMPLETA'
           ELSE 'PARCIAL'
       END                                          AS estado_recepcion,
       oc.oc_estado = 'EMITIDA'
         AND oc.oc_fecha_entrega_esperada < CURRENT_DATE
         AND SUM(d.cantidad_pendiente) > 0          AS atrasada
FROM orden_compra oc
JOIN proveedor pr ON pr.id_proveedor = oc.id_proveedor
LEFT JOIN v_orden_compra_detalle d ON d.id_orden_compra = oc.id_orden_compra
GROUP BY oc.id_orden_compra, pr.prv_razon_social;

-- Stock por variante: físico, reservado por pedidos sin facturar,
-- disponible para vender, en camino (OC emitidas), valor y antigüedad
CREATE VIEW v_stock_variante AS
WITH saldos AS (
    SELECT id_variante,
           SUM(saldo)                                                    AS stock_fisico,
           SUM(saldo * lot_costo_unitario)                               AS valor_inventario,
           SUM(saldo * dias_en_inventario) FILTER (WHERE saldo > 0)
               / NULLIF(SUM(saldo) FILTER (WHERE saldo > 0), 0)          AS antiguedad_promedio_dias,
           MAX(dias_en_inventario) FILTER (WHERE saldo > 0)              AS antiguedad_maxima_dias,
           MAX(ultimo_movimiento)                                        AS ultimo_movimiento
    FROM v_lote_saldo
    GROUP BY id_variante
), reservas AS (
    SELECT dv.id_variante, SUM(dv.cantidad_base) AS reservado
    FROM v_detalle_pedido_valor dv
    JOIN v_pedido_estado_actual ea ON ea.id_pedido = dv.id_pedido
    WHERE ea.id_estado_pedido IN ('PEN', 'PAG')
    GROUP BY dv.id_variante
), en_camino AS (
    SELECT d.id_variante, SUM(d.cantidad_pendiente) AS en_camino
    FROM v_orden_compra_detalle d
    JOIN orden_compra oc ON oc.id_orden_compra = d.id_orden_compra
    WHERE oc.oc_estado = 'EMITIDA'
    GROUP BY d.id_variante
)
SELECT v.id_variante,
       v.var_sku,
       p.prd_nombre,
       p.id_unidad_medida                                         AS unidad,
       COALESCE(s.stock_fisico, 0)                                AS stock_fisico,
       COALESCE(r.reservado, 0)                                   AS reservado,
       COALESCE(s.stock_fisico, 0) - COALESCE(r.reservado, 0)     AS disponible,
       COALESCE(c.en_camino, 0)                                   AS en_camino,
       v.var_stock_minimo                                         AS stock_minimo,
       COALESCE(s.stock_fisico, 0) - COALESCE(r.reservado, 0)
         + COALESCE(c.en_camino, 0) <= v.var_stock_minimo         AS requiere_compra,
       ROUND(COALESCE(s.valor_inventario, 0), 2)                  AS valor_inventario,
       ROUND(s.antiguedad_promedio_dias, 1)                       AS antiguedad_promedio_dias,
       s.antiguedad_maxima_dias,
       s.ultimo_movimiento
FROM variante v
JOIN producto p ON p.id_producto = v.id_producto
LEFT JOIN saldos    s ON s.id_variante = v.id_variante
LEFT JOIN reservas  r ON r.id_variante = v.id_variante
LEFT JOIN en_camino c ON c.id_variante = v.id_variante;

-- Kárdex: entradas, salidas y saldo acumulado (en cantidad y valorizado) por variante
CREATE VIEW v_kardex AS
SELECT m.mov_fechahora                                  AS fecha,
       l.id_variante,
       v.var_sku,
       m.id_movimiento,
       m.id_tipo_movimiento                             AS tipo,
       t.tmv_nombre                                     AS movimiento,
       CASE m.id_tipo_movimiento
           WHEN 'VEN' THEN 'Factura ' || fe.pem_establecimiento || '-' || fe.pem_punto || '-' || LPAD(f.cve_secuencial::TEXT, 9, '0')
           WHEN 'DCL' THEN 'N/C '     || ne.pem_establecimiento || '-' || ne.pem_punto || '-' || LPAD(nc.ncr_secuencial::TEXT, 9, '0')
           WHEN 'COM' THEN 'OC ' || m.id_orden_compra || COALESCE(' / fact. ' || fp.cco_numero, '')
           WHEN 'DPR' THEN 'OC ' || m.id_orden_compra || ' / ' || m.mov_motivo
           ELSE m.mov_motivo
       END                                              AS documento,
       dm.id_lote,
       l.lot_costo_unitario                             AS costo_unitario,
       CASE WHEN t.tmv_signo =  1 THEN dm.dmo_cantidad END AS entrada,
       CASE WHEN t.tmv_signo = -1 THEN dm.dmo_cantidad END AS salida,
       SUM(dm.dmo_cantidad * t.tmv_signo) OVER w        AS saldo,
       ROUND(dm.dmo_cantidad * l.lot_costo_unitario * t.tmv_signo, 2)              AS valor,
       ROUND(SUM(dm.dmo_cantidad * l.lot_costo_unitario * t.tmv_signo) OVER w, 2)  AS saldo_valorizado,
       u.usu_correo                                     AS usuario
FROM detalle_movimiento dm
JOIN movimiento_inventario m  ON m.id_movimiento      = dm.id_movimiento
JOIN tipo_movimiento       t  ON t.id_tipo_movimiento = m.id_tipo_movimiento
JOIN lote                  l  ON l.id_lote            = dm.id_lote
JOIN variante              v  ON v.id_variante        = l.id_variante
JOIN usuario               u  ON u.id_usuario         = m.id_usuario
LEFT JOIN comprobante_venta           f  ON f.id_comprobante_venta           = m.id_comprobante_venta
LEFT JOIN punto_emision     fe ON fe.id_punto_emision    = f.id_punto_emision
LEFT JOIN nota_credito      nc ON nc.id_nota_credito     = m.id_nota_credito
LEFT JOIN punto_emision     ne ON ne.id_punto_emision    = nc.id_punto_emision
LEFT JOIN comprobante_compra fp ON fp.id_comprobante_compra = m.id_comprobante_compra
WINDOW w AS (PARTITION BY l.id_variante ORDER BY m.mov_fechahora, dm.id_detalle_movimiento);

-- Comprobante de venta (factura o nota de venta) con número, comprador,
-- canal, vendedor y totales
CREATE VIEW v_comprobante_venta AS
SELECT f.id_comprobante_venta,
       f.id_tipo_comprobante,
       tc.tco_nombre                                       AS tipo_comprobante,
       pe.pem_establecimiento || '-' || pe.pem_punto || '-' || LPAD(f.cve_secuencial::TEXT, 9, '0') AS numero,
       f.cve_fechahora                                     AS fecha,
       f.cve_estado                                    AS estado_sri,
       f.cve_clave_acceso                                  AS clave_acceso,
       f.id_pedido,
       p.id_canal_venta                                    AS canal,
       COALESCE(e.epl_nombres || ' ' || e.epl_apellidos, 'E-commerce') AS vendedor,
       df.id_tipo_identificacion                           AS tipo_identificacion,
       df.dfa_identificacion                               AS identificacion,
       COALESCE(df.dfa_razon_social, cl.cli_nombres || COALESCE(' ' || cl.cli_apellidos, '')) AS razon_social,
       -- la nota de venta no discrimina IVA: solo muestra el total
       CASE WHEN tc.tco_desglosa_iva THEN t.subtotal_0 END       AS subtotal_0,
       CASE WHEN tc.tco_desglosa_iva THEN t.subtotal_gravado END AS subtotal_gravado,
       t.descuento, t.costo_envio,
       CASE WHEN tc.tco_desglosa_iva THEN t.iva END              AS iva,
       t.total,
       u.usu_correo                                        AS emitida_por
FROM comprobante_venta f
JOIN tipo_comprobante  tc ON tc.id_tipo_comprobante  = f.id_tipo_comprobante
JOIN punto_emision     pe ON pe.id_punto_emision     = f.id_punto_emision
JOIN pedido            p  ON p.id_pedido             = f.id_pedido
JOIN cliente           cl ON cl.id_cliente           = p.id_cliente
LEFT JOIN datos_facturacion df ON df.id_datos_facturacion = f.id_datos_facturacion
JOIN v_pedido_totales  t  ON t.id_pedido             = f.id_pedido
JOIN usuario           u  ON u.id_usuario            = f.id_usuario_emite
LEFT JOIN empleado     e  ON e.id_usuario            = p.id_empleado_vendedor;

-- Notas de crédito con su valor (proporcional a lo devuelto de cada línea)
CREATE VIEW v_nota_credito AS
WITH lineas AS (
    SELECT d.id_nota_credito,
           ROUND(dv.base_imponible * d.dnc_cantidad / dv.dpe_cantidad, 2) AS base,
           dv.tiv_porcentaje
    FROM detalle_nota_credito d
    JOIN v_detalle_pedido_valor dv ON dv.id_detalle_pedido = d.id_detalle_pedido
), valores AS (
    SELECT id_nota_credito,
           SUM(base)                                        AS subtotal,
           SUM(ROUND(base * tiv_porcentaje / 100, 2))       AS iva
    FROM lineas
    GROUP BY id_nota_credito
)
SELECT nc.id_nota_credito,
       pe.pem_establecimiento || '-' || pe.pem_punto || '-' || LPAD(nc.ncr_secuencial::TEXT, 9, '0') AS numero,
       nc.ncr_fechahora                 AS fecha,
       nc.id_comprobante_venta,
       vf.numero                        AS comprobante_venta,
       m.mde_nombre                     AS motivo,
       nc.ncr_estado                AS estado_sri,
       COALESCE(v.subtotal, 0)          AS subtotal,
       COALESCE(v.iva, 0)               AS iva,
       COALESCE(v.subtotal + v.iva, 0)  AS total,
       u.usu_correo                     AS autorizada_por
FROM nota_credito nc
JOIN punto_emision     pe ON pe.id_punto_emision     = nc.id_punto_emision
JOIN motivo_devolucion m  ON m.id_motivo_devolucion  = nc.id_motivo_devolucion
JOIN v_comprobante_venta         vf ON vf.id_comprobante_venta           = nc.id_comprobante_venta
JOIN usuario           u  ON u.id_usuario            = nc.id_usuario_autoriza
LEFT JOIN valores      v  ON v.id_nota_credito       = nc.id_nota_credito;

-- Ventas por día, canal (físico / e-commerce / WhatsApp), vendedor y tipo de comprobante
CREATE VIEW v_ventas_por_canal AS
SELECT f.fecha::DATE        AS fecha,
       c.cav_nombre         AS canal,
       f.vendedor,
       f.tipo_comprobante,
       COUNT(*)             AS comprobantes,
       SUM(f.total)         AS total_vendido
FROM v_comprobante_venta f
JOIN canal_venta c ON c.id_canal_venta = f.canal
WHERE f.estado_sri <> 'ANULADA'
GROUP BY f.fecha::DATE, c.cav_nombre, f.vendedor, f.tipo_comprobante;

-- Frecuencia de clientes (recencia, frecuencia, monto) y segmento
CREATE VIEW v_frecuencia_cliente AS
WITH compras AS (
    SELECT p.id_cliente, p.id_pedido, p.id_canal_venta, f.cve_fechahora, t.total
    FROM comprobante_venta f
    JOIN pedido p           ON p.id_pedido = f.id_pedido
    JOIN v_pedido_totales t ON t.id_pedido = f.id_pedido
    WHERE f.cve_estado <> 'ANULADA'
), devoluciones AS (
    SELECT p.id_cliente, SUM(n.total) AS devuelto
    FROM v_nota_credito n
    JOIN comprobante_venta f ON f.id_comprobante_venta = n.id_comprobante_venta
    JOIN pedido  p ON p.id_pedido  = f.id_pedido
    WHERE n.estado_sri <> 'ANULADA'
    GROUP BY p.id_cliente
), resumen AS (
    SELECT c.id_cliente,
           COUNT(co.id_pedido)                                 AS compras,
           MIN(co.cve_fechahora)                               AS primera_compra,
           MAX(co.cve_fechahora)                               AS ultima_compra,
           COALESCE(SUM(co.total), 0)                          AS monto_comprado,
           MODE() WITHIN GROUP (ORDER BY co.id_canal_venta)    AS canal_preferido
    FROM cliente c
    LEFT JOIN compras co ON co.id_cliente = c.id_cliente
    WHERE NOT EXISTS (SELECT 1 FROM datos_facturacion df            -- excluye al genérico
                      WHERE df.id_cliente = c.id_cliente AND df.id_tipo_identificacion = '07')
    GROUP BY c.id_cliente
)
SELECT r.id_cliente,
       c.cli_nombres || COALESCE(' ' || c.cli_apellidos, '')   AS cliente,
       r.compras,
       r.primera_compra,
       r.ultima_compra,
       CURRENT_DATE - r.ultima_compra::DATE                     AS dias_sin_comprar,
       ROUND((r.ultima_compra::DATE - r.primera_compra::DATE)::NUMERIC
             / NULLIF(r.compras - 1, 0), 1)                     AS dias_entre_compras,
       r.monto_comprado,
       COALESCE(d.devuelto, 0)                                  AS monto_devuelto,
       r.monto_comprado - COALESCE(d.devuelto, 0)               AS monto_neto,
       r.canal_preferido,
       CASE
           WHEN r.compras = 0                                   THEN 'SIN COMPRAS'
           WHEN CURRENT_DATE - r.ultima_compra::DATE > 180      THEN 'INACTIVO'
           WHEN r.compras >= 5                                  THEN 'FRECUENTE'
           WHEN r.compras >= 2                                  THEN 'RECURRENTE'
           ELSE 'NUEVO'
       END                                                      AS segmento
FROM resumen r
JOIN cliente c ON c.id_cliente = r.id_cliente
LEFT JOIN devoluciones d ON d.id_cliente = r.id_cliente;

-- Cuentas por pagar a proveedores (por factura): total - notas de crédito - pagos
CREATE VIEW v_cuentas_por_pagar AS
SELECT fp.id_comprobante_compra,
       fp.id_proveedor,
       pr.prv_razon_social                                            AS proveedor,
       tc.tco_nombre                                                  AS tipo_comprobante,
       fp.cco_numero                                                  AS numero,
       fp.cco_fecha_emision                                           AS emision,
       fp.cco_fecha_vencimiento                                       AS vencimiento,
       fp.cco_subtotal_0 + fp.cco_subtotal_gravado + fp.cco_iva       AS total,
       COALESCE(nc.monto, 0)                                          AS notas_credito,
       COALESCE(pg.pagado, 0)                                         AS pagado,
       fp.cco_subtotal_0 + fp.cco_subtotal_gravado + fp.cco_iva
         - COALESCE(nc.monto, 0) - COALESCE(pg.pagado, 0)             AS saldo,
       fp.cco_fecha_vencimiento < CURRENT_DATE
         AND fp.cco_subtotal_0 + fp.cco_subtotal_gravado + fp.cco_iva
             - COALESCE(nc.monto, 0) - COALESCE(pg.pagado, 0) > 0     AS vencida
FROM comprobante_compra fp
JOIN proveedor pr ON pr.id_proveedor = fp.id_proveedor
JOIN tipo_comprobante tc ON tc.id_tipo_comprobante = fp.id_tipo_comprobante
LEFT JOIN (SELECT id_comprobante_compra, SUM(ppr_monto) AS pagado
           FROM pago_proveedor GROUP BY id_comprobante_compra) pg ON pg.id_comprobante_compra = fp.id_comprobante_compra
LEFT JOIN (SELECT id_comprobante_compra, SUM(ncp_subtotal_0 + ncp_subtotal_gravado + ncp_iva) AS monto
           FROM nota_credito_proveedor GROUP BY id_comprobante_compra) nc ON nc.id_comprobante_compra = fp.id_comprobante_compra;

-- Valor de cada recepción (COM) o devolución a proveedor (DPR) al costo real
-- del lote, con el IVA estimado según la tarifa de cada producto
CREATE VIEW v_recepcion_valor AS
SELECT m.id_movimiento,
       m.id_tipo_movimiento,
       m.mov_fechahora                                                          AS fecha,
       oc.id_proveedor,
       m.id_orden_compra,
       m.id_comprobante_compra,
       ROUND(SUM(dm.dmo_cantidad * l.lot_costo_unitario), 2)                    AS valor,
       ROUND(SUM(dm.dmo_cantidad * l.lot_costo_unitario * t.tiv_porcentaje / 100), 2) AS iva_estimado
FROM movimiento_inventario m
JOIN orden_compra       oc ON oc.id_orden_compra = m.id_orden_compra
JOIN detalle_movimiento dm ON dm.id_movimiento   = m.id_movimiento
JOIN lote               l  ON l.id_lote          = dm.id_lote
JOIN variante           v  ON v.id_variante      = l.id_variante
JOIN producto           p  ON p.id_producto      = v.id_producto
JOIN tarifa_iva         t  ON t.id_tarifa_iva    = p.id_tarifa_iva
WHERE m.id_tipo_movimiento IN ('COM', 'DPR')
GROUP BY m.id_movimiento, oc.id_proveedor;

-- Mercadería recibida que todavía no tiene factura del proveedor
CREATE VIEW v_recepciones_por_facturar AS
SELECT rv.id_movimiento,
       rv.id_proveedor,
       pr.prv_razon_social                 AS proveedor,
       rv.id_orden_compra,
       rv.fecha,
       rv.valor,
       rv.iva_estimado,
       rv.valor + rv.iva_estimado          AS total_estimado,
       CURRENT_DATE - rv.fecha::DATE       AS dias_sin_factura
FROM v_recepcion_valor rv
JOIN proveedor pr ON pr.id_proveedor = rv.id_proveedor
WHERE rv.id_tipo_movimiento = 'COM' AND rv.id_comprobante_compra IS NULL;

-- Control del valor de ingreso: lo facturado por el proveedor contra lo
-- recibido en bodega al costo real
CREATE VIEW v_conciliacion_compra AS
SELECT fp.id_comprobante_compra,
       pr.prv_razon_social                                              AS proveedor,
       fp.cco_numero                                                    AS numero,
       fp.cco_fecha_emision                                             AS emision,
       fp.cco_subtotal_0 + fp.cco_subtotal_gravado                      AS subtotal_facturado,
       COALESCE(SUM(rv.valor), 0)                                       AS valor_recibido,
       fp.cco_subtotal_0 + fp.cco_subtotal_gravado - COALESCE(SUM(rv.valor), 0) AS diferencia,
       CASE WHEN COUNT(rv.id_movimiento) = 0 THEN 'SIN MERCADERÍA ASOCIADA'
            WHEN ABS(fp.cco_subtotal_0 + fp.cco_subtotal_gravado - SUM(rv.valor)) <= 0.01 THEN 'CUADRA'
            ELSE 'DIFERENCIA' END                                       AS estado
FROM comprobante_compra fp
JOIN proveedor pr ON pr.id_proveedor = fp.id_proveedor
LEFT JOIN v_recepcion_valor rv ON rv.id_comprobante_compra = fp.id_comprobante_compra AND rv.id_tipo_movimiento = 'COM'
GROUP BY fp.id_comprobante_compra, pr.prv_razon_social;

-- Estado de cuenta por proveedor: mercadería, documentos, pagos y deuda
CREATE VIEW v_estado_cuenta_proveedor AS
SELECT pr.id_proveedor,
       pr.prv_razon_social                                    AS proveedor,
       pr.prv_identificacion                                  AS identificacion,
       COALESCE(r.recibido, 0)                                AS mercaderia_recibida,
       COALESCE(r.devuelto, 0)                                AS mercaderia_devuelta,
       COALESCE(c.facturado, 0)                               AS facturado,
       COALESCE(c.notas_credito, 0)                           AS notas_credito,
       COALESCE(c.pagado, 0)                                  AS pagado,
       COALESCE(c.saldo, 0)                                   AS saldo_facturas,
       COALESCE(c.vencido, 0)                                 AS saldo_vencido,
       COALESCE(pf.por_facturar, 0)                           AS por_facturar_estimado,
       COALESCE(c.saldo, 0) + COALESCE(pf.por_facturar, 0)    AS deuda_estimada
FROM proveedor pr
LEFT JOIN (SELECT id_proveedor,
                  SUM(valor) FILTER (WHERE id_tipo_movimiento = 'COM') AS recibido,
                  SUM(valor) FILTER (WHERE id_tipo_movimiento = 'DPR') AS devuelto
           FROM v_recepcion_valor GROUP BY id_proveedor) r ON r.id_proveedor = pr.id_proveedor
LEFT JOIN (SELECT id_proveedor, SUM(total) AS facturado, SUM(notas_credito) AS notas_credito,
                  SUM(pagado) AS pagado, SUM(saldo) AS saldo, SUM(saldo) FILTER (WHERE vencida) AS vencido
           FROM v_cuentas_por_pagar GROUP BY id_proveedor) c ON c.id_proveedor = pr.id_proveedor
LEFT JOIN (SELECT id_proveedor, SUM(total_estimado) AS por_facturar
           FROM v_recepciones_por_facturar GROUP BY id_proveedor) pf ON pf.id_proveedor = pr.id_proveedor;

-- Historial de costos de compra por producto (tabla y serie para gráficas):
-- costo real de cada ingreso, costo pactado en la OC y variación contra la
-- compra anterior del mismo producto
CREATE VIEW v_historial_costo_compra AS
SELECT v.id_variante,
       v.var_sku,
       p.prd_nombre,
       p.id_unidad_medida                                       AS unidad,
       m.mov_fechahora                                          AS fecha,
       pr.prv_razon_social                                      AS proveedor,
       m.id_orden_compra,
       fp.cco_numero                                            AS comprobante_compra,
       l.id_lote,
       l.lot_codigo_proveedor                                   AS codigo_lote,
       dm.dmo_cantidad                                          AS cantidad,
       l.lot_costo_unitario                                     AS costo_unitario,
       dco.dco_costo_unitario                                   AS costo_pactado,
       ROUND((l.lot_costo_unitario - dco.dco_costo_unitario) * 100
             / NULLIF(dco.dco_costo_unitario, 0), 2)            AS dif_vs_pactado_pct,
       LAG(l.lot_costo_unitario) OVER w                         AS costo_anterior,
       ROUND((l.lot_costo_unitario - LAG(l.lot_costo_unitario) OVER w) * 100
             / NULLIF(LAG(l.lot_costo_unitario) OVER w, 0), 2)  AS variacion_pct
FROM detalle_movimiento dm
JOIN movimiento_inventario m    ON m.id_movimiento   = dm.id_movimiento AND m.id_tipo_movimiento = 'COM'
JOIN lote                  l    ON l.id_lote         = dm.id_lote
JOIN variante              v    ON v.id_variante     = l.id_variante
JOIN producto              p    ON p.id_producto     = v.id_producto
JOIN orden_compra          oc   ON oc.id_orden_compra = m.id_orden_compra
JOIN proveedor             pr   ON pr.id_proveedor   = oc.id_proveedor
JOIN detalle_orden_compra  dco  ON dco.id_detalle_orden_compra = dm.id_detalle_orden_compra
LEFT JOIN comprobante_compra fp  ON fp.id_comprobante_compra = m.id_comprobante_compra
WINDOW w AS (PARTITION BY v.id_variante ORDER BY m.mov_fechahora, dm.id_detalle_movimiento);

-- Historial de precios de venta por presentación (vigente, anteriores y programados)
CREATE VIEW v_historial_precio_venta AS
SELECT v.var_sku,
       p.prd_nombre,
       pr.id_presentacion,
       pr.pre_descripcion                                            AS presentacion,
       hp.hpr_precio                                                 AS precio,
       ROUND(hp.hpr_precio * (1 + t.tiv_porcentaje / 100), 2)        AS precio_con_iva,
       hp.hpr_vigente_desde                                          AS vigente_desde,
       LEAD(hp.hpr_vigente_desde) OVER (PARTITION BY hp.id_presentacion
                                        ORDER BY hp.hpr_vigente_desde) AS vigente_hasta,
       hp.hpr_vigente_desde > CURRENT_TIMESTAMP                      AS programado,
       COALESCE(pv.vigente_desde = hp.hpr_vigente_desde, FALSE)      AS vigente,
       u.usu_correo                                                  AS registrado_por
FROM historial_precio hp
JOIN presentacion pr ON pr.id_presentacion = hp.id_presentacion
JOIN variante     v  ON v.id_variante      = pr.id_variante
JOIN producto     p  ON p.id_producto      = v.id_producto
JOIN tarifa_iva   t  ON t.id_tarifa_iva    = p.id_tarifa_iva
JOIN usuario      u  ON u.id_usuario       = hp.id_usuario
LEFT JOIN v_precio_vigente pv ON pv.id_presentacion = hp.id_presentacion;

-- Cuentas por cobrar: crédito de ventas y avances, con saldo y vencimiento
CREATE VIEW v_cuentas_por_cobrar AS
SELECT c.id_cuenta_por_cobrar,
       p.id_cliente,
       cl.cli_nombres || COALESCE(' ' || cl.cli_apellidos, '')    AS cliente,
       c.id_pedido,
       f.numero                                                    AS comprobante_venta,
       c.cxc_tipo                                                  AS tipo,
       ma.mav_nombre                                               AS motivo,
       c.cxc_concepto                                              AS concepto,
       c.cxc_fechahora                                             AS fecha,
       c.cxc_fecha_vencimiento                                     AS vencimiento,
       c.cxc_monto                                                 AS monto,
       COALESCE(a.abonado, 0)                                      AS abonado,
       c.cxc_monto - COALESCE(a.abonado, 0)                        AS saldo,
       CASE WHEN c.cxc_monto - COALESCE(a.abonado, 0) = 0 THEN 'PAGADA'
            WHEN c.cxc_fecha_vencimiento < CURRENT_DATE  THEN 'VENCIDA'
            ELSE 'PENDIENTE' END                                   AS estado,
       CASE WHEN c.cxc_monto - COALESCE(a.abonado, 0) > 0
            THEN GREATEST(CURRENT_DATE - c.cxc_fecha_vencimiento, 0)
            ELSE 0 END                                             AS dias_vencida
FROM cuenta_por_cobrar c
JOIN pedido  p  ON p.id_pedido   = c.id_pedido
JOIN cliente cl ON cl.id_cliente = p.id_cliente
LEFT JOIN (SELECT id_cuenta_por_cobrar, SUM(abo_monto) AS abonado
           FROM abono_cliente GROUP BY id_cuenta_por_cobrar) a ON a.id_cuenta_por_cobrar = c.id_cuenta_por_cobrar
LEFT JOIN motivo_avance ma ON ma.id_motivo_avance = c.id_motivo_avance
LEFT JOIN v_comprobante_venta f ON f.id_pedido = c.id_pedido AND f.estado_sri <> 'ANULADA';

-- Estado de cuenta por cliente (lo que debe por compras a crédito y avances)
CREATE VIEW v_estado_cuenta_cliente AS
SELECT cl.id_cliente,
       cl.cli_nombres || COALESCE(' ' || cl.cli_apellidos, '')            AS cliente,
       cl.cli_limite_credito                                              AS limite_credito,
       COALESCE(SUM(c.saldo) FILTER (WHERE c.tipo = 'CREDITO'), 0)        AS saldo_credito,
       COALESCE(SUM(c.saldo) FILTER (WHERE c.tipo = 'AVANCE'), 0)         AS saldo_avances,
       COALESCE(SUM(c.saldo), 0)                                          AS deuda_total,
       COALESCE(SUM(c.saldo) FILTER (WHERE c.estado = 'VENCIDA'), 0)      AS deuda_vencida,
       cl.cli_limite_credito - COALESCE(SUM(c.saldo), 0)                  AS credito_disponible
FROM cliente cl
LEFT JOIN v_cuentas_por_cobrar c ON c.id_cliente = cl.id_cliente
GROUP BY cl.id_cliente;

-- Cola del SRI: comprobantes que aún no tienen autorización. Desde 2026
-- la transmisión debe ser inmediata, así que una fila con muchos minutos
-- pendiente es una alerta para el servicio de facturación.
CREATE VIEW v_cola_sri AS
SELECT 'FACTURA'::VARCHAR(12)                                              AS tipo,
       f.id_comprobante_venta                                                        AS id,
       vf.numero,
       f.cve_clave_acceso                                                  AS clave_acceso,
       f.cve_fechahora                                                     AS emitido,
       f.cve_estado                                                    AS estado,
       ROUND(EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - f.cve_fechahora)) / 60) AS minutos_pendiente
FROM comprobante_venta f
JOIN v_comprobante_venta vf ON vf.id_comprobante_venta = f.id_comprobante_venta
WHERE f.cve_estado IN ('PENDIENTE', 'RECHAZADA')
UNION ALL
SELECT 'NOTA_CREDITO',
       n.id_nota_credito,
       vn.numero,
       n.ncr_clave_acceso,
       n.ncr_fechahora,
       n.ncr_estado,
       ROUND(EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - n.ncr_fechahora)) / 60)
FROM nota_credito n
JOIN v_nota_credito vn ON vn.id_nota_credito = n.id_nota_credito
WHERE n.ncr_estado IN ('PENDIENTE', 'RECHAZADA');

-- Ventas por presentación y vendedor (p. ej. cuánto se vendió a precio de banda)
CREATE VIEW v_ventas_por_presentacion AS
SELECT f.fecha::DATE          AS fecha,
       f.vendedor,
       v.var_sku,
       pr.pre_descripcion     AS presentacion,
       SUM(d.dpe_cantidad)    AS cantidad,
       SUM(dv.base_imponible) AS subtotal
FROM v_comprobante_venta f
JOIN detalle_pedido         d  ON d.id_pedido          = f.id_pedido
JOIN v_detalle_pedido_valor dv ON dv.id_detalle_pedido = d.id_detalle_pedido
JOIN presentacion           pr ON pr.id_presentacion   = d.id_presentacion
JOIN variante               v  ON v.id_variante        = pr.id_variante
WHERE f.estado_sri <> 'ANULADA'
GROUP BY f.fecha::DATE, f.vendedor, v.var_sku, pr.pre_descripcion;

-- Deudores: cuánto debe cada cliente, con sus identificaciones y teléfonos
-- para poder buscarlo (ver fn_buscar_deuda_cliente)
CREATE VIEW v_deuda_cliente AS
SELECT e.id_cliente,
       e.cliente,
       (SELECT STRING_AGG(DISTINCT df.dfa_identificacion, ', ')
        FROM datos_facturacion df
        WHERE df.id_cliente = e.id_cliente AND df.dfa_activo AND df.id_tipo_identificacion <> '07') AS identificaciones,
       (SELECT STRING_AGG(t.tel_numero, ', ') FROM telefono t WHERE t.id_cliente = e.id_cliente)   AS telefonos,
       e.limite_credito,
       e.saldo_credito,
       e.saldo_avances,
       e.deuda_total,
       e.deuda_vencida,
       e.credito_disponible,
       (SELECT COUNT(*) FROM v_cuentas_por_cobrar c WHERE c.id_cliente = e.id_cliente AND c.saldo > 0) AS cuentas_pendientes,
       (SELECT MIN(c.vencimiento) FROM v_cuentas_por_cobrar c WHERE c.id_cliente = e.id_cliente AND c.saldo > 0) AS proximo_vencimiento,
       (SELECT MAX(c.dias_vencida) FROM v_cuentas_por_cobrar c WHERE c.id_cliente = e.id_cliente) AS max_dias_vencida,
       (SELECT MAX(a.abo_fechahora)
        FROM abono_cliente a
        JOIN cuenta_por_cobrar c ON c.id_cuenta_por_cobrar = a.id_cuenta_por_cobrar
        JOIN pedido p ON p.id_pedido = c.id_pedido
        WHERE p.id_cliente = e.id_cliente)                                                          AS ultimo_abono
FROM v_estado_cuenta_cliente e;

-- Estado de cuenta detallado del cliente: cargos (crédito y avances) y
-- abonos en orden, con el saldo acumulado ("cuentas claras")
CREATE VIEW v_estado_cuenta_movimientos AS
WITH m AS (
    SELECT p.id_cliente, c.cxc_fechahora AS fecha, 1 AS orden, c.id_cuenta_por_cobrar AS id_ref,
           CASE c.cxc_tipo
               WHEN 'CREDITO' THEN 'Crédito de la factura ' || COALESCE(f.numero, '(sin factura)')
               ELSE 'Avance (' || ma.mav_nombre || '): ' || c.cxc_concepto
           END                                                   AS detalle,
           c.cxc_monto                                           AS cargo,
           0::NUMERIC                                            AS abono,
           c.cxc_fecha_vencimiento                               AS vencimiento
    FROM cuenta_por_cobrar c
    JOIN pedido p ON p.id_pedido = c.id_pedido
    LEFT JOIN motivo_avance ma ON ma.id_motivo_avance = c.id_motivo_avance
    LEFT JOIN v_comprobante_venta f ON f.id_pedido = c.id_pedido AND f.estado_sri <> 'ANULADA'
    UNION ALL
    SELECT p.id_cliente, a.abo_fechahora, 2, a.id_abono_cliente,
           CASE WHEN a.id_nota_credito IS NOT NULL
                THEN 'Compensación con la nota de crédito ' || n.numero
                ELSE 'Abono (' || mp.mpa_nombre || ')' || COALESCE(' ref. ' || a.abo_referencia, '')
           END,
           0, a.abo_monto, NULL
    FROM abono_cliente a
    JOIN cuenta_por_cobrar c ON c.id_cuenta_por_cobrar = a.id_cuenta_por_cobrar
    JOIN pedido p ON p.id_pedido = c.id_pedido
    LEFT JOIN metodo_pago mp ON mp.id_metodo_pago = a.id_metodo_pago
    LEFT JOIN v_nota_credito n ON n.id_nota_credito = a.id_nota_credito
)
SELECT m.id_cliente,
       cl.cli_nombres || COALESCE(' ' || cl.cli_apellidos, '')  AS cliente,
       m.fecha,
       m.detalle,
       m.cargo,
       m.abono,
       m.vencimiento,
       SUM(m.cargo - m.abono) OVER (PARTITION BY m.id_cliente ORDER BY m.fecha, m.orden, m.id_ref) AS saldo
FROM m
JOIN cliente cl ON cl.id_cliente = m.id_cliente;

-- Negociaciones de precio: precio de lista contra valor final pactado,
-- porcentaje de descuento resultante y quién lo autorizó
CREATE VIEW v_negociaciones AS
SELECT p.id_pedido,
       p.ped_fechahora                                                    AS fecha,
       p.id_canal_venta                                                   AS canal,
       cl.cli_nombres || COALESCE(' ' || cl.cli_apellidos, '')            AS cliente,
       COALESCE(ev.epl_nombres || ' ' || ev.epl_apellidos, '-')           AS vendedor,
       COALESCE(ea.epl_nombres || ' ' || ea.epl_apellidos, ua.usu_correo) AS autorizado_por,
       v.var_sku,
       pr.pre_descripcion                                                 AS presentacion,
       dv.dpe_cantidad                                                    AS cantidad,
       dv.dpe_precio_unitario                                             AS precio_lista,
       dv.valor_lista + ROUND(dv.valor_lista * dv.tiv_porcentaje / 100, 2) AS valor_lista_con_iva,
       dv.base_imponible + dv.iva                                         AS valor_final_con_iva,
       dv.descuento_oferta,
       dv.dpe_descuento                                                   AS descuento,
       dv.pct_descuento,
       est.id_estado_pedido                                               AS estado,
       f.numero                                                           AS comprobante_venta
FROM v_detalle_pedido_valor dv
JOIN pedido       p   ON p.id_pedido        = dv.id_pedido
JOIN cliente      cl  ON cl.id_cliente      = p.id_cliente
JOIN presentacion pr  ON pr.id_presentacion = dv.id_presentacion
JOIN variante     v   ON v.id_variante      = pr.id_variante
JOIN usuario      ua  ON ua.id_usuario      = dv.id_usuario_descuento
LEFT JOIN empleado ea ON ea.id_usuario      = dv.id_usuario_descuento
LEFT JOIN empleado ev ON ev.id_usuario      = p.id_empleado_vendedor
LEFT JOIN v_pedido_estado_actual est ON est.id_pedido = p.id_pedido
LEFT JOIN v_comprobante_venta f ON f.id_pedido = p.id_pedido AND f.estado_sri <> 'ANULADA'
WHERE dv.dpe_descuento > 0;

-- Ofertas: estado, uso en ventas y descuento otorgado
CREATE VIEW v_oferta AS
SELECT o.id_oferta,
       p.prd_codigo,
       p.prd_nombre,
       o.ofe_porcentaje                 AS porcentaje,
       o.ofe_descripcion                AS descripcion,
       o.ofe_desde                      AS desde,
       o.ofe_hasta                      AS hasta,
       CASE WHEN NOT o.ofe_activa                    THEN 'PAUSADA'
            WHEN o.ofe_desde > CURRENT_TIMESTAMP     THEN 'PROGRAMADA'
            WHEN o.ofe_hasta <= CURRENT_TIMESTAMP    THEN 'FINALIZADA'
            ELSE 'VIGENTE' END          AS estado,
       COALESCE(u.lineas, 0)            AS lineas_vendidas,
       COALESCE(u.descuento, 0)         AS descuento_otorgado,
       us.usu_correo                    AS registrada_por
FROM oferta o
JOIN producto p  ON p.id_producto = o.id_producto
JOIN usuario  us ON us.id_usuario = o.id_usuario_registra
LEFT JOIN (SELECT id_oferta, COUNT(*) AS lineas, SUM(descuento_oferta) AS descuento
           FROM v_detalle_pedido_valor WHERE id_oferta IS NOT NULL
           GROUP BY id_oferta) u ON u.id_oferta = o.id_oferta;

-- Catálogo (tienda y e-commerce): precio vigente, oferta y disponibilidad por presentación
CREATE VIEW v_catalogo AS
SELECT p.id_producto,
       p.prd_codigo,
       p.prd_nombre,
       c.cat_nombre                                            AS categoria,
       v.id_variante,
       v.var_sku,
       car.caracteristicas,
       pr.id_presentacion,
       pr.pre_descripcion                                      AS presentacion,
       pr.pre_cantidad_minima                                  AS cantidad_minima,
       pv.precio,
       t.tiv_porcentaje                                        AS iva_porcentaje,
       ROUND(pv.precio * (1 + t.tiv_porcentaje / 100), 2)      AS precio_con_iva,
       ov.id_oferta,
       ov.ofe_porcentaje                                       AS pct_oferta,
       ov.ofe_hasta                                            AS oferta_hasta,
       ROUND(pv.precio * (1 - COALESCE(ov.ofe_porcentaje, 0) / 100), 2) AS precio_final,
       ROUND(ROUND(pv.precio * (1 - COALESCE(ov.ofe_porcentaje, 0) / 100), 2)
             * (1 + t.tiv_porcentaje / 100), 2)                AS precio_final_con_iva,
       -- en productos por pieza, lo máximo que se puede pedir en una línea
       -- es lo que tiene la pieza más grande
       FLOOR(GREATEST(CASE WHEN p.prd_venta_por_pieza
                           THEN LEAST(s.disponible, COALESCE((SELECT MAX(ls.saldo) FROM v_lote_saldo ls
                                                              WHERE ls.id_variante = v.id_variante), 0))
                           ELSE s.disponible END, 0) / pr.pre_factor) AS disponible,
       p.prd_fecha_creacion >= CURRENT_DATE - 30               AS es_novedad,
       -- datos de vitrina para el e-commerce
       p.prd_imagen_url                                        AS imagen_url,
       p.prd_uso                                               AS uso,
       c.cat_codigo                                            AS categoria_codigo,
       COALESCE(cp.cat_codigo, c.cat_codigo)                   AS linea_codigo,
       COALESCE(cp.cat_nombre, c.cat_nombre)                   AS linea,
       p.prd_fecha_creacion                                    AS fecha_creacion,
       p.id_unidad_medida                                      AS unidad_codigo,
       um.umd_nombre                                           AS unidad
FROM producto p
JOIN categoria         c  ON c.id_categoria     = p.id_categoria
LEFT JOIN categoria    cp ON cp.id_categoria    = c.id_categoria_padre
JOIN unidad_medida     um ON um.id_unidad_medida = p.id_unidad_medida
JOIN tarifa_iva        t  ON t.id_tarifa_iva    = p.id_tarifa_iva
JOIN variante          v  ON v.id_producto      = p.id_producto
JOIN presentacion      pr ON pr.id_variante     = v.id_variante
JOIN v_precio_vigente  pv ON pv.id_presentacion = pr.id_presentacion
JOIN v_stock_variante  s  ON s.id_variante      = v.id_variante
LEFT JOIN v_oferta_vigente ov ON ov.id_producto = p.id_producto
LEFT JOIN LATERAL (
    SELECT STRING_AGG(a.atr_nombre || ': ' || va.val_valor, ', ' ORDER BY a.atr_nombre) AS caracteristicas
    FROM variante_valor vv
    JOIN valor_atributo va ON va.id_valor_atributo = vv.id_valor_atributo
    JOIN atributo       a  ON a.id_atributo        = vv.id_atributo
    WHERE vv.id_variante = v.id_variante
) car ON TRUE
WHERE p.prd_publicado AND v.var_activa AND pr.pre_activa AND c.cat_activa;

-- Categorías principales (raíz: sin categoría padre, es decir, que no son
-- subcategoría de otra), con sus subcategorías directas, los productos
-- publicados de TODO su árbol (recorrido recursivo, sirve a cualquier
-- profundidad) y la imagen del primer producto como portada.
CREATE VIEW v_categoria_principal AS
WITH RECURSIVE arbol AS (
    SELECT c.id_categoria AS id_raiz, c.id_categoria
    FROM categoria c
    WHERE c.id_categoria_padre IS NULL AND c.cat_activa
    UNION ALL
    SELECT a.id_raiz, h.id_categoria
    FROM arbol a
    JOIN categoria h ON h.id_categoria_padre = a.id_categoria
    WHERE h.cat_activa
), publicados AS (
    SELECT DISTINCT a.id_raiz, v.id_producto, v.prd_codigo, v.imagen_url
    FROM arbol a
    JOIN categoria  c ON c.id_categoria = a.id_categoria
    JOIN v_catalogo v ON v.categoria_codigo = c.cat_codigo
)
SELECT r.id_categoria,
       r.cat_codigo                                            AS codigo,
       r.cat_nombre                                            AS nombre,
       (SELECT STRING_AGG(s.cat_nombre, ' · ' ORDER BY s.cat_nombre)
        FROM categoria s
        WHERE s.id_categoria_padre = r.id_categoria AND s.cat_activa) AS subcategorias,
       (SELECT COUNT(*) FROM publicados p WHERE p.id_raiz = r.id_categoria) AS productos,
       (SELECT p.imagen_url FROM publicados p
        WHERE p.id_raiz = r.id_categoria AND p.imagen_url IS NOT NULL
        ORDER BY p.prd_codigo LIMIT 1)                         AS imagen_url
FROM categoria r
WHERE r.id_categoria_padre IS NULL AND r.cat_activa;


-- =====================================================================
-- B. DISPARADORES
-- =====================================================================

-- B1. Registros que nunca se editan ni se borran (bitácoras y kárdex)
CREATE FUNCTION tg_inmutable() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = produccion, public AS $$
BEGIN
    RAISE EXCEPTION 'Los registros de % no se modifican ni se eliminan. %',
        TG_TABLE_NAME, COALESCE(TG_ARGV[0], '');
END $$;

CREATE TRIGGER tr_lote_inmutable                 BEFORE UPDATE OR DELETE ON lote
    FOR EACH ROW EXECUTE FUNCTION tg_inmutable('Registre un ajuste de inventario.');
CREATE TRIGGER tr_nota_credito_proveedor_inmutable BEFORE UPDATE OR DELETE ON nota_credito_proveedor
    FOR EACH ROW EXECUTE FUNCTION tg_inmutable('');

-- Cabecera del kárdex: inmutable, salvo asociar UNA vez la factura del
-- proveedor a una recepción que llegó sin ella (el documento llega después)
CREATE FUNCTION tg_movimiento_proteger() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = produccion, public AS $$
BEGIN
    IF TG_OP = 'DELETE'
       OR (NEW.id_movimiento, NEW.id_tipo_movimiento, NEW.mov_fechahora, NEW.id_usuario, NEW.mov_motivo,
           NEW.id_orden_compra, NEW.id_comprobante_venta, NEW.id_nota_credito)
          IS DISTINCT FROM
          (OLD.id_movimiento, OLD.id_tipo_movimiento, OLD.mov_fechahora, OLD.id_usuario, OLD.mov_motivo,
           OLD.id_orden_compra, OLD.id_comprobante_venta, OLD.id_nota_credito)
       OR NEW.id_comprobante_compra IS NULL THEN
        RAISE EXCEPTION 'Los registros de movimiento_inventario no se modifican ni se eliminan. Registre un ajuste de inventario.';
    END IF;
    IF OLD.id_comprobante_compra IS NOT NULL THEN
        RAISE EXCEPTION 'La recepción % ya tiene asociada una factura del proveedor', OLD.id_movimiento;
    END IF;
    IF OLD.id_tipo_movimiento <> 'COM' THEN
        RAISE EXCEPTION 'Solo una recepción de compra lleva factura de proveedor';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM comprobante_compra fp JOIN orden_compra oc ON oc.id_proveedor = fp.id_proveedor
                   WHERE fp.id_comprobante_compra = NEW.id_comprobante_compra AND oc.id_orden_compra = OLD.id_orden_compra) THEN
        RAISE EXCEPTION 'La factura de proveedor no corresponde al proveedor de la OC %', OLD.id_orden_compra;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER tr_movimiento_inmutable           BEFORE UPDATE OR DELETE ON movimiento_inventario
    FOR EACH ROW EXECUTE FUNCTION tg_movimiento_proteger();
CREATE TRIGGER tr_detalle_movimiento_inmutable   BEFORE UPDATE OR DELETE ON detalle_movimiento
    FOR EACH ROW EXECUTE FUNCTION tg_inmutable('Registre un ajuste de inventario.');
CREATE TRIGGER tr_historial_estado_inmutable     BEFORE UPDATE OR DELETE ON historial_estado_pedido
    FOR EACH ROW EXECUTE FUNCTION tg_inmutable('Registre un nuevo estado.');
CREATE TRIGGER tr_historial_precio_inmutable     BEFORE UPDATE OR DELETE ON historial_precio
    FOR EACH ROW EXECUTE FUNCTION tg_inmutable('Registre un nuevo precio.');
CREATE TRIGGER tr_detalle_nc_inmutable           BEFORE UPDATE OR DELETE ON detalle_nota_credito
    FOR EACH ROW EXECUTE FUNCTION tg_inmutable('Emita otra nota de crédito.');
CREATE TRIGGER tr_reembolso_inmutable            BEFORE UPDATE OR DELETE ON reembolso
    FOR EACH ROW EXECUTE FUNCTION tg_inmutable('');
CREATE TRIGGER tr_pago_proveedor_inmutable       BEFORE UPDATE OR DELETE ON pago_proveedor
    FOR EACH ROW EXECUTE FUNCTION tg_inmutable('');
CREATE TRIGGER tr_cuenta_por_cobrar_inmutable    BEFORE UPDATE OR DELETE ON cuenta_por_cobrar
    FOR EACH ROW EXECUTE FUNCTION tg_inmutable('Registre un abono.');
CREATE TRIGGER tr_abono_cliente_inmutable        BEFORE UPDATE OR DELETE ON abono_cliente
    FOR EACH ROW EXECUTE FUNCTION tg_inmutable('');
CREATE TRIGGER tr_log_evento_inmutable           BEFORE UPDATE OR DELETE ON log_evento
    FOR EACH ROW EXECUTE FUNCTION tg_inmutable('La bitácora solo se inserta.');
CREATE TRIGGER tr_auditoria_inmutable            BEFORE UPDATE OR DELETE ON auditoria
    FOR EACH ROW EXECUTE FUNCTION tg_inmutable('La auditoría solo se inserta.');


-- B2. Un pedido solo se edita mientras está pendiente de pago
CREATE FUNCTION tg_pedido_editable() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    v_pedido INTEGER;
    v_estado VARCHAR(3);
BEGIN
    v_pedido := CASE WHEN TG_OP = 'DELETE' THEN OLD.id_pedido ELSE NEW.id_pedido END;
    SELECT id_estado_pedido INTO v_estado FROM v_pedido_estado_actual WHERE id_pedido = v_pedido;
    IF v_estado IS NOT NULL AND v_estado <> 'PEN' THEN
        RAISE EXCEPTION 'El pedido % está en estado % y ya no se puede modificar', v_pedido, v_estado;
    END IF;
    IF TG_OP = 'UPDATE' AND NEW.id_pedido <> OLD.id_pedido THEN
        RAISE EXCEPTION 'No se puede mover una línea a otro pedido';
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;

CREATE TRIGGER tr_pedido_editable BEFORE UPDATE OR DELETE ON pedido
    FOR EACH ROW EXECUTE FUNCTION tg_pedido_editable();
CREATE TRIGGER tr_detalle_pedido_editable BEFORE INSERT OR UPDATE OR DELETE ON detalle_pedido
    FOR EACH ROW EXECUTE FUNCTION tg_pedido_editable();

-- Descuentos de una línea:
--  · Oferta: la pone la base, la vigente del producto al crear el pedido
--    (en cualquier canal). No se elige ni se cambia: así, en el e-commerce
--    nadie puede inventar un descuento durante la compra.
--  · Negociado: solo en tienda o WhatsApp, lo autoriza alguien con el
--    permiso PRECIO_NEGOCIAR y parte del precio que ya tiene la oferta.
CREATE FUNCTION tg_detalle_pedido_descuento() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    v_vigente INTEGER;
    v_neto    NUMERIC;
BEGIN
    IF TG_OP = 'INSERT' OR NEW.id_presentacion <> OLD.id_presentacion THEN
        SELECT ov.id_oferta INTO v_vigente
        FROM presentacion pr
        JOIN variante v ON v.id_variante = pr.id_variante
        JOIN v_oferta_vigente ov ON ov.id_producto = v.id_producto
        WHERE pr.id_presentacion = NEW.id_presentacion;
        IF TG_OP = 'INSERT' AND NEW.id_oferta IS NOT NULL AND NEW.id_oferta IS DISTINCT FROM v_vigente THEN
            RAISE EXCEPTION 'La oferta % no está vigente para este producto: las ofertas las aplica el catálogo, no se eligen al comprar',
                NEW.id_oferta;
        END IF;
        NEW.id_oferta := v_vigente;
    ELSIF NEW.id_oferta IS DISTINCT FROM OLD.id_oferta THEN
        RAISE EXCEPTION 'La oferta de una línea se fija al crear el pedido y no se cambia';
    END IF;

    IF NEW.dpe_descuento > 0 THEN
        IF (SELECT id_canal_venta FROM pedido WHERE id_pedido = NEW.id_pedido) = 'WEB' THEN
            RAISE EXCEPTION 'Los descuentos negociados solo se permiten en tienda o WhatsApp, no en el e-commerce';
        END IF;
        IF NEW.id_usuario_descuento IS NULL THEN
            RAISE EXCEPTION 'Indique quién autorizó el descuento';
        END IF;
        PERFORM fn_exigir_permiso(NEW.id_usuario_descuento, 'PRECIO_NEGOCIAR');
        v_neto := ROUND(NEW.dpe_cantidad * NEW.dpe_precio_unitario, 2)
                - ROUND(NEW.dpe_cantidad * NEW.dpe_precio_unitario
                        * COALESCE((SELECT ofe_porcentaje FROM oferta WHERE id_oferta = NEW.id_oferta), 0) / 100, 2);
        IF NEW.dpe_descuento > v_neto THEN
            RAISE EXCEPTION 'El descuento negociado (%) supera el precio con oferta de la línea (%)', NEW.dpe_descuento, v_neto;
        END IF;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER tr_detalle_pedido_descuento BEFORE INSERT OR UPDATE ON detalle_pedido
    FOR EACH ROW EXECUTE FUNCTION tg_detalle_pedido_descuento();

-- El costo y la dirección del envío se fijan antes de pagar;
-- transportista y guía se pueden completar al despachar.
CREATE FUNCTION tg_envio_editable() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    v_pedido INTEGER;
    v_estado VARCHAR(3);
BEGIN
    IF TG_OP = 'UPDATE'
       AND (NEW.id_pedido, NEW.id_direccion, NEW.env_costo, NEW.id_tarifa_iva)
           IS NOT DISTINCT FROM (OLD.id_pedido, OLD.id_direccion, OLD.env_costo, OLD.id_tarifa_iva) THEN
        RETURN NEW;
    END IF;
    v_pedido := CASE WHEN TG_OP = 'DELETE' THEN OLD.id_pedido ELSE NEW.id_pedido END;
    SELECT id_estado_pedido INTO v_estado FROM v_pedido_estado_actual WHERE id_pedido = v_pedido;
    IF v_estado IS NOT NULL AND v_estado <> 'PEN' THEN
        RAISE EXCEPTION 'El costo y la dirección del envío del pedido % ya no se pueden cambiar (estado %)', v_pedido, v_estado;
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;

CREATE TRIGGER tr_envio_editable BEFORE INSERT OR UPDATE OR DELETE ON envio
    FOR EACH ROW EXECUTE FUNCTION tg_envio_editable();


-- B3. Transiciones válidas del pedido:
--     (nuevo) → PEN → PAG → FAC → DES → ENT     (FAC → ENT si se retira en tienda)
--     PEN/PAG → CAN
CREATE FUNCTION tg_historial_estado_validar() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    v_actual VARCHAR(3);
    v_envio  BOOLEAN;
BEGIN
    PERFORM 1 FROM pedido WHERE id_pedido = NEW.id_pedido FOR UPDATE;
    SELECT id_estado_pedido INTO v_actual FROM v_pedido_estado_actual WHERE id_pedido = NEW.id_pedido;
    v_envio := EXISTS (SELECT 1 FROM envio WHERE id_pedido = NEW.id_pedido);

    IF NOT (   (v_actual IS NULL AND NEW.id_estado_pedido = 'PEN')
            OR (v_actual = 'PEN' AND NEW.id_estado_pedido IN ('PAG', 'CAN'))
            OR (v_actual = 'PAG' AND NEW.id_estado_pedido IN ('FAC', 'CAN'))
            OR (v_actual = 'FAC' AND NEW.id_estado_pedido = 'DES' AND v_envio)
            OR (v_actual = 'FAC' AND NEW.id_estado_pedido = 'ENT' AND NOT v_envio)
            OR (v_actual = 'DES' AND NEW.id_estado_pedido = 'ENT')) THEN
        RAISE EXCEPTION 'Transición no permitida en el pedido %: % → % %',
            NEW.id_pedido, COALESCE(v_actual, '(nuevo)'), NEW.id_estado_pedido,
            CASE WHEN v_actual = 'FAC' AND v_envio     THEN '(tiene envío: debe despacharse primero)'
                 WHEN v_actual = 'FAC' AND NOT v_envio THEN '(sin envío: se entrega en tienda)'
                 ELSE '' END;
    END IF;

    IF NEW.id_estado_pedido = 'PAG'
       AND (SELECT cubierto FROM v_pedido_pagos  WHERE id_pedido = NEW.id_pedido)
         < (SELECT total    FROM v_pedido_totales WHERE id_pedido = NEW.id_pedido) THEN
        RAISE EXCEPTION 'Los pagos aprobados y el crédito no cubren el total del pedido %', NEW.id_pedido;
    END IF;

    IF NEW.id_estado_pedido = 'CAN' AND EXISTS (
           SELECT 1 FROM cuenta_por_cobrar WHERE id_pedido = NEW.id_pedido AND cxc_tipo = 'CREDITO') THEN
        RAISE EXCEPTION 'El pedido % tiene crédito otorgado y no se puede cancelar', NEW.id_pedido;
    END IF;

    IF NEW.id_estado_pedido = 'FAC' AND NOT EXISTS (
           SELECT 1 FROM comprobante_venta WHERE id_pedido = NEW.id_pedido AND cve_estado <> 'ANULADA') THEN
        RAISE EXCEPTION 'El pedido % no tiene una factura emitida', NEW.id_pedido;
    END IF;

    RETURN NEW;
END $$;

CREATE TRIGGER tr_historial_estado_validar BEFORE INSERT ON historial_estado_pedido
    FOR EACH ROW EXECUTE FUNCTION tg_historial_estado_validar();


-- B4. Cabecera del kárdex: origen coherente y sin fechas futuras
CREATE FUNCTION tg_movimiento_validar() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    v_estado    VARCHAR(8);
    v_proveedor INTEGER;
BEGIN
    IF NEW.mov_fechahora > CURRENT_TIMESTAMP + INTERVAL '1 minute' THEN
        RAISE EXCEPTION 'No se registran movimientos con fecha futura';
    END IF;
    IF NEW.id_tipo_movimiento = 'COM' THEN
        SELECT oc_estado, id_proveedor INTO v_estado, v_proveedor
        FROM orden_compra WHERE id_orden_compra = NEW.id_orden_compra;
        IF v_estado <> 'EMITIDA' THEN
            RAISE EXCEPTION 'Solo se recibe mercadería de una OC emitida (OC % en estado %)', NEW.id_orden_compra, v_estado;
        END IF;
        IF NEW.id_comprobante_compra IS NOT NULL AND NOT EXISTS (
               SELECT 1 FROM comprobante_compra
               WHERE id_comprobante_compra = NEW.id_comprobante_compra AND id_proveedor = v_proveedor) THEN
            RAISE EXCEPTION 'La factura de proveedor no corresponde al proveedor de la OC %', NEW.id_orden_compra;
        END IF;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER tr_movimiento_validar BEFORE INSERT ON movimiento_inventario
    FOR EACH ROW EXECUTE FUNCTION tg_movimiento_validar();


-- B5. Línea del kárdex: documento correcto, misma variante, lote nuevo en
--     cada ingreso y nunca saldo negativo
CREATE FUNCTION tg_detalle_movimiento_validar() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    m           RECORD;
    v_var_lote  INTEGER;
    v_var_doc   INTEGER;
    v_saldo     NUMERIC;
    v_con_movs  BOOLEAN;
    v_origen    INTEGER;
BEGIN
    SELECT mi.id_tipo_movimiento, mi.id_orden_compra, mi.id_comprobante_venta, mi.id_nota_credito, t.tmv_signo
      INTO m
    FROM movimiento_inventario mi
    JOIN tipo_movimiento t ON t.id_tipo_movimiento = mi.id_tipo_movimiento
    WHERE mi.id_movimiento = NEW.id_movimiento;

    SELECT id_variante, id_lote_origen INTO v_var_lote, v_origen FROM lote WHERE id_lote = NEW.id_lote FOR UPDATE;
    v_con_movs := EXISTS (SELECT 1 FROM detalle_movimiento WHERE id_lote = NEW.id_lote);

    -- 1) Cada tipo referencia la línea de su documento
    IF m.id_tipo_movimiento = 'COM' THEN
        SELECT id_variante INTO v_var_doc FROM detalle_orden_compra
        WHERE id_detalle_orden_compra = NEW.id_detalle_orden_compra
          AND id_orden_compra = m.id_orden_compra;
        IF v_var_doc IS NULL THEN
            RAISE EXCEPTION 'La recepción debe referenciar una línea de la OC %', m.id_orden_compra;
        END IF;
    ELSIF m.id_tipo_movimiento = 'VEN' THEN
        SELECT pr.id_variante INTO v_var_doc
        FROM detalle_pedido d
        JOIN presentacion pr ON pr.id_presentacion = d.id_presentacion
        JOIN comprobante_venta f       ON f.id_pedido        = d.id_pedido
        WHERE d.id_detalle_pedido = NEW.id_detalle_pedido
          AND f.id_comprobante_venta = m.id_comprobante_venta;
        IF v_var_doc IS NULL THEN
            RAISE EXCEPTION 'El despacho debe referenciar una línea del pedido facturado';
        END IF;
    ELSIF m.id_tipo_movimiento = 'DCL' THEN
        SELECT pr.id_variante INTO v_var_doc
        FROM detalle_nota_credito dn
        JOIN detalle_pedido d ON d.id_detalle_pedido = dn.id_detalle_pedido
        JOIN presentacion  pr ON pr.id_presentacion  = d.id_presentacion
        WHERE dn.id_detalle_nota_credito = NEW.id_detalle_nota_credito
          AND dn.id_nota_credito = m.id_nota_credito;
        IF v_var_doc IS NULL THEN
            RAISE EXCEPTION 'La devolución debe referenciar una línea de la nota de crédito';
        END IF;
    ELSE
        IF num_nonnulls(NEW.id_detalle_orden_compra, NEW.id_detalle_pedido, NEW.id_detalle_nota_credito) > 0 THEN
            RAISE EXCEPTION 'Los movimientos % no referencian líneas de documentos', m.id_tipo_movimiento;
        END IF;
        v_var_doc := v_var_lote;
    END IF;

    IF v_var_doc <> v_var_lote THEN
        RAISE EXCEPTION 'El lote % no pertenece a la variante del documento', NEW.id_lote;
    END IF;

    -- 2) Todo ingreso nuevo (compra, inicial, ajuste +, paquete) abre su
    --    propio lote; solo un fraccionamiento crea lotes con pieza de
    --    origen; la devolución de cliente vuelve a un lote existente
    IF m.id_tipo_movimiento IN ('COM', 'INI', 'AJP', 'FRE') AND v_con_movs THEN
        RAISE EXCEPTION 'Cada ingreso (%) debe crear su propio lote', m.id_tipo_movimiento;
    END IF;
    IF (m.id_tipo_movimiento = 'FRE') <> (v_origen IS NOT NULL) AND NOT v_con_movs THEN
        RAISE EXCEPTION 'Solo un fraccionamiento (FRE) crea lotes con pieza de origen';
    END IF;
    IF m.id_tipo_movimiento = 'DCL' AND NOT v_con_movs THEN
        RAISE EXCEPTION 'La devolución de cliente debe regresar a un lote existente';
    END IF;

    -- 3) La devolución a proveedor sale de un lote de esa misma OC
    IF m.id_tipo_movimiento = 'DPR' AND NOT EXISTS (
           SELECT 1 FROM detalle_movimiento dm
           JOIN movimiento_inventario mi ON mi.id_movimiento = dm.id_movimiento
           WHERE dm.id_lote = NEW.id_lote AND mi.id_tipo_movimiento = 'COM'
             AND mi.id_orden_compra = m.id_orden_compra) THEN
        RAISE EXCEPTION 'El lote % no fue recibido en la OC %', NEW.id_lote, m.id_orden_compra;
    END IF;

    -- 4) Ninguna salida deja el lote en negativo
    IF m.tmv_signo = -1 THEN
        SELECT COALESCE(SUM(dm.dmo_cantidad * t.tmv_signo), 0) INTO v_saldo
        FROM detalle_movimiento dm
        JOIN movimiento_inventario mi ON mi.id_movimiento = dm.id_movimiento
        JOIN tipo_movimiento t        ON t.id_tipo_movimiento = mi.id_tipo_movimiento
        WHERE dm.id_lote = NEW.id_lote;
        IF v_saldo < NEW.dmo_cantidad THEN
            RAISE EXCEPTION 'Stock insuficiente en el lote % (saldo %, se requieren %)',
                NEW.id_lote, v_saldo, NEW.dmo_cantidad;
        END IF;
    END IF;

    RETURN NEW;
END $$;

CREATE TRIGGER tr_detalle_movimiento_validar BEFORE INSERT ON detalle_movimiento
    FOR EACH ROW EXECUTE FUNCTION tg_detalle_movimiento_validar();


-- B6. Factura y nota de crédito: solo cambian sus datos de autorización SRI
CREATE FUNCTION tg_comprobante_venta_protegido() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = produccion, public AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Los comprobantes de venta no se eliminan; se anulan o se corrigen con nota de crédito';
    END IF;
    IF (NEW.id_tipo_comprobante, NEW.id_pedido, NEW.id_datos_facturacion, NEW.id_punto_emision, NEW.cve_secuencial,
        NEW.cve_fechahora, NEW.id_usuario_emite)
       IS DISTINCT FROM
       (OLD.id_tipo_comprobante, OLD.id_pedido, OLD.id_datos_facturacion, OLD.id_punto_emision, OLD.cve_secuencial,
        OLD.cve_fechahora, OLD.id_usuario_emite) THEN
        RAISE EXCEPTION 'De un comprobante emitido solo se actualizan su estado y los datos de autorización del SRI';
    END IF;
    IF NEW.cve_estado = 'ANULADA' AND OLD.cve_estado <> 'ANULADA' AND NEW.id_tipo_comprobante = '01'
       AND (SELECT id_tipo_identificacion FROM datos_facturacion
            WHERE id_datos_facturacion = NEW.id_datos_facturacion) = '07' THEN
        RAISE EXCEPTION 'Una factura a consumidor final no se anula una vez transmitida al SRI (regla vigente desde 2026)';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER tr_comprobante_venta_protegido BEFORE UPDATE OR DELETE ON comprobante_venta
    FOR EACH ROW EXECUTE FUNCTION tg_comprobante_venta_protegido();

CREATE FUNCTION tg_nota_credito_protegida() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = produccion, public AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Las notas de crédito no se eliminan';
    END IF;
    IF (NEW.id_comprobante_venta, NEW.id_punto_emision, NEW.ncr_secuencial, NEW.ncr_fechahora,
        NEW.id_motivo_devolucion, NEW.id_usuario_autoriza, NEW.ncr_observacion)
       IS DISTINCT FROM
       (OLD.id_comprobante_venta, OLD.id_punto_emision, OLD.ncr_secuencial, OLD.ncr_fechahora,
        OLD.id_motivo_devolucion, OLD.id_usuario_autoriza, OLD.ncr_observacion) THEN
        RAISE EXCEPTION 'De una nota de crédito emitida solo se actualizan los datos de autorización del SRI';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER tr_nota_credito_protegida BEFORE UPDATE OR DELETE ON nota_credito
    FOR EACH ROW EXECUTE FUNCTION tg_nota_credito_protegida();

-- Aviso inmediato al servicio que firma y transmite al SRI (LISTEN cola_sri).
-- El aviso sale al confirmar la transacción; si se deshace, no se envía.
CREATE FUNCTION tg_avisar_sri() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    v JSONB := to_jsonb(NEW);
BEGIN
    -- Solo los comprobantes electrónicos (con clave de acceso) van al SRI
    IF COALESCE(v ->> 'cve_clave_acceso', v ->> 'ncr_clave_acceso') IS NULL THEN
        RETURN NULL;
    END IF;
    PERFORM pg_notify('cola_sri', jsonb_build_object(
        'tipo',         TG_TABLE_NAME,
        'id',           COALESCE(v ->> 'id_comprobante_venta', v ->> 'id_nota_credito'),
        'clave_acceso', COALESCE(v ->> 'cve_clave_acceso', v ->> 'ncr_clave_acceso'))::TEXT);
    RETURN NULL;
END $$;

CREATE TRIGGER tr_comprobante_venta_avisar_sri AFTER INSERT ON comprobante_venta
    FOR EACH ROW EXECUTE FUNCTION tg_avisar_sri();
CREATE TRIGGER tr_nota_credito_avisar_sri AFTER INSERT ON nota_credito
    FOR EACH ROW EXECUTE FUNCTION tg_avisar_sri();


-- B7. Datos usados en documentos no se editan: se desactivan y se crea otro registro
CREATE FUNCTION tg_datos_facturacion_inmutable() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = produccion, public AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM comprobante_venta WHERE id_datos_facturacion = OLD.id_datos_facturacion)
       AND (NEW.id_cliente, NEW.id_tipo_identificacion, NEW.dfa_identificacion, NEW.dfa_razon_social,
            NEW.dfa_correo, NEW.id_direccion)
           IS DISTINCT FROM
           (OLD.id_cliente, OLD.id_tipo_identificacion, OLD.dfa_identificacion, OLD.dfa_razon_social,
            OLD.dfa_correo, OLD.id_direccion) THEN
        RAISE EXCEPTION 'Estos datos ya constan en una factura: desactívelos y registre unos nuevos';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER tr_datos_facturacion_inmutable BEFORE UPDATE ON datos_facturacion
    FOR EACH ROW EXECUTE FUNCTION tg_datos_facturacion_inmutable();

CREATE FUNCTION tg_direccion_inmutable() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = produccion, public AS $$
BEGIN
    IF (   EXISTS (SELECT 1 FROM envio WHERE id_direccion = OLD.id_direccion)
        OR EXISTS (SELECT 1 FROM datos_facturacion df JOIN comprobante_venta f USING (id_datos_facturacion)
                   WHERE df.id_direccion = OLD.id_direccion))
       AND (NEW.id_cliente, NEW.id_ciudad, NEW.dir_calle_principal, NEW.dir_numero,
            NEW.dir_calle_secundaria, NEW.dir_referencia)
           IS DISTINCT FROM
           (OLD.id_cliente, OLD.id_ciudad, OLD.dir_calle_principal, OLD.dir_numero,
            OLD.dir_calle_secundaria, OLD.dir_referencia) THEN
        RAISE EXCEPTION 'La dirección ya se usó en un envío o factura: desactívela y registre una nueva';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER tr_direccion_inmutable BEFORE UPDATE ON direccion
    FOR EACH ROW EXECUTE FUNCTION tg_direccion_inmutable();


-- B8. Catálogo: categorías sin ciclos y atributos acordes a la categoría
CREATE FUNCTION tg_categoria_sin_ciclos() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = produccion, public AS $$
BEGIN
    IF NEW.id_categoria_padre IS NOT NULL AND EXISTS (
        WITH RECURSIVE ancestros AS (
            SELECT id_categoria, id_categoria_padre FROM categoria WHERE id_categoria = NEW.id_categoria_padre
            UNION ALL
            SELECT c.id_categoria, c.id_categoria_padre
            FROM categoria c JOIN ancestros a ON c.id_categoria = a.id_categoria_padre
        )
        SELECT 1 FROM ancestros WHERE id_categoria = NEW.id_categoria) THEN
        RAISE EXCEPTION 'La categoría % no puede depender de una de sus subcategorías', NEW.cat_codigo;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER tr_categoria_sin_ciclos BEFORE UPDATE OF id_categoria_padre ON categoria
    FOR EACH ROW EXECUTE FUNCTION tg_categoria_sin_ciclos();

CREATE FUNCTION tg_variante_valor_validar() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = produccion, public AS $$
BEGIN
    IF NOT EXISTS (
        WITH RECURSIVE ancestros AS (
            SELECT c.id_categoria, c.id_categoria_padre
            FROM categoria c
            JOIN producto p ON p.id_categoria = c.id_categoria
            JOIN variante v ON v.id_producto  = p.id_producto
            WHERE v.id_variante = NEW.id_variante
            UNION ALL
            SELECT c.id_categoria, c.id_categoria_padre
            FROM categoria c JOIN ancestros a ON c.id_categoria = a.id_categoria_padre
        )
        SELECT 1 FROM ancestros a
        JOIN categoria_atributo ca ON ca.id_categoria = a.id_categoria
        WHERE ca.id_atributo = NEW.id_atributo) THEN
        RAISE EXCEPTION 'El atributo % no está definido para la categoría del producto (ni para sus categorías padre)',
            NEW.id_atributo;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER tr_variante_valor_validar BEFORE INSERT OR UPDATE ON variante_valor
    FOR EACH ROW EXECUTE FUNCTION tg_variante_valor_validar();


-- B9. Compras: OC editable solo en borrador y transiciones de estado válidas
CREATE FUNCTION tg_orden_compra_validar() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = produccion, public AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.oc_estado <> 'BORRADOR' THEN
            RAISE EXCEPTION 'Solo se elimina una OC en borrador; anúlela';
        END IF;
        RETURN OLD;
    END IF;

    IF OLD.oc_estado <> 'BORRADOR'
       AND (NEW.id_proveedor, NEW.oc_fecha, NEW.oc_fecha_entrega_esperada, NEW.id_usuario_crea)
           IS DISTINCT FROM (OLD.id_proveedor, OLD.oc_fecha, OLD.oc_fecha_entrega_esperada, OLD.id_usuario_crea) THEN
        RAISE EXCEPTION 'La OC % ya fue emitida y no se puede modificar', OLD.id_orden_compra;
    END IF;

    IF NEW.oc_estado <> OLD.oc_estado THEN
        IF NOT (   (OLD.oc_estado = 'BORRADOR' AND NEW.oc_estado IN ('EMITIDA', 'ANULADA'))
                OR (OLD.oc_estado = 'EMITIDA'  AND NEW.oc_estado IN ('CERRADA', 'ANULADA'))) THEN
            RAISE EXCEPTION 'Transición no permitida en la OC %: % → %', OLD.id_orden_compra, OLD.oc_estado, NEW.oc_estado;
        END IF;
        IF NEW.oc_estado = 'EMITIDA' AND NOT EXISTS (
               SELECT 1 FROM detalle_orden_compra WHERE id_orden_compra = NEW.id_orden_compra) THEN
            RAISE EXCEPTION 'La OC % no tiene líneas', NEW.id_orden_compra;
        END IF;
        IF NEW.oc_estado = 'ANULADA' AND EXISTS (
               SELECT 1 FROM movimiento_inventario WHERE id_orden_compra = NEW.id_orden_compra) THEN
            RAISE EXCEPTION 'La OC % ya tiene recepciones: ciérrela en lugar de anularla', NEW.id_orden_compra;
        END IF;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER tr_orden_compra_validar BEFORE UPDATE OR DELETE ON orden_compra
    FOR EACH ROW EXECUTE FUNCTION tg_orden_compra_validar();

CREATE FUNCTION tg_detalle_oc_editable() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    v_estado VARCHAR(8);
BEGIN
    SELECT oc_estado INTO v_estado FROM orden_compra
    WHERE id_orden_compra = CASE WHEN TG_OP = 'DELETE' THEN OLD.id_orden_compra ELSE NEW.id_orden_compra END;
    IF v_estado <> 'BORRADOR' THEN
        RAISE EXCEPTION 'Las líneas de una OC solo se editan en borrador (estado actual: %)', v_estado;
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;

CREATE TRIGGER tr_detalle_oc_editable BEFORE INSERT OR UPDATE OR DELETE ON detalle_orden_compra
    FOR EACH ROW EXECUTE FUNCTION tg_detalle_oc_editable();


-- B10. Topes: no pagar más de lo facturado por el proveedor ni reembolsar
--      más que la nota de crédito
CREATE FUNCTION tg_pago_proveedor_tope() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    v_saldo NUMERIC;
BEGIN
    PERFORM 1 FROM comprobante_compra WHERE id_comprobante_compra = NEW.id_comprobante_compra FOR UPDATE;
    SELECT saldo INTO v_saldo FROM v_cuentas_por_pagar WHERE id_comprobante_compra = NEW.id_comprobante_compra;
    IF NEW.ppr_monto > v_saldo THEN
        RAISE EXCEPTION 'El pago (%) supera el saldo pendiente de la factura (%)', NEW.ppr_monto, v_saldo;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER tr_pago_proveedor_tope BEFORE INSERT ON pago_proveedor
    FOR EACH ROW EXECUTE FUNCTION tg_pago_proveedor_tope();

CREATE FUNCTION tg_reembolso_tope() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    v_total       NUMERIC;
    v_reembolsado NUMERIC;
    v_aplicado    NUMERIC;
BEGIN
    PERFORM 1 FROM nota_credito WHERE id_nota_credito = NEW.id_nota_credito FOR UPDATE;
    SELECT total INTO v_total FROM v_nota_credito WHERE id_nota_credito = NEW.id_nota_credito;
    SELECT COALESCE(SUM(ree_monto), 0) INTO v_reembolsado FROM reembolso WHERE id_nota_credito = NEW.id_nota_credito;
    SELECT COALESCE(SUM(abo_monto), 0) INTO v_aplicado FROM abono_cliente WHERE id_nota_credito = NEW.id_nota_credito;
    IF v_reembolsado + v_aplicado + NEW.ree_monto > v_total THEN
        RAISE EXCEPTION 'El reembolso supera lo disponible de la nota de crédito (total %, reembolsado %, compensado con deudas %)',
            v_total, v_reembolsado, v_aplicado;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER tr_reembolso_tope BEFORE INSERT ON reembolso
    FOR EACH ROW EXECUTE FUNCTION tg_reembolso_tope();

-- Nota de crédito del proveedor: número único por proveedor, fecha no anterior
-- a la factura y sin acreditar más de lo facturado
CREATE FUNCTION tg_nota_credito_proveedor_validar() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    v_fp     RECORD;
    v_previo NUMERIC;
    v_nueva  NUMERIC := NEW.ncp_subtotal_0 + NEW.ncp_subtotal_gravado + NEW.ncp_iva;
BEGIN
    SELECT * INTO v_fp FROM comprobante_compra WHERE id_comprobante_compra = NEW.id_comprobante_compra FOR UPDATE;
    IF v_fp.id_tipo_comprobante = '00' THEN
        RAISE EXCEPTION 'Una compra sin comprobante (recibo) no admite nota de crédito del proveedor: registre la devolución y ajuste con el proveedor';
    END IF;
    IF EXISTS (SELECT 1 FROM nota_credito_proveedor n
               JOIN comprobante_compra f ON f.id_comprobante_compra = n.id_comprobante_compra
               WHERE f.id_proveedor = v_fp.id_proveedor AND n.ncp_numero = NEW.ncp_numero) THEN
        RAISE EXCEPTION 'El proveedor ya tiene registrada la nota de crédito %', NEW.ncp_numero;
    END IF;
    IF NEW.ncp_fecha_emision < v_fp.cco_fecha_emision THEN
        RAISE EXCEPTION 'La nota de crédito no puede ser anterior al comprobante que modifica';
    END IF;
    SELECT COALESCE(SUM(ncp_subtotal_0 + ncp_subtotal_gravado + ncp_iva), 0) INTO v_previo
    FROM nota_credito_proveedor WHERE id_comprobante_compra = NEW.id_comprobante_compra;
    IF v_previo + v_nueva > v_fp.cco_subtotal_0 + v_fp.cco_subtotal_gravado + v_fp.cco_iva THEN
        RAISE EXCEPTION 'La nota de crédito (%) supera lo facturado que queda por acreditar (%)',
            v_nueva, v_fp.cco_subtotal_0 + v_fp.cco_subtotal_gravado + v_fp.cco_iva - v_previo;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER tr_nota_credito_proveedor_validar BEFORE INSERT ON nota_credito_proveedor
    FOR EACH ROW EXECUTE FUNCTION tg_nota_credito_proveedor_validar();

-- Comprobante de compra: el tipo debe servir para compras. Factura y nota
-- de venta llevan el número SRI (001-001-000000123); la clave de acceso
-- (49 dígitos) solo existe en una factura electrónica. Los montos por tipo
-- los controla ckt_comprobante_compra.
CREATE FUNCTION tg_comprobante_compra_validar() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = produccion, public AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM tipo_comprobante WHERE id_tipo_comprobante = NEW.id_tipo_comprobante AND tco_en_compra) THEN
        RAISE EXCEPTION 'El tipo de comprobante % no se usa en compras', NEW.id_tipo_comprobante;
    END IF;
    IF NEW.id_tipo_comprobante IN ('01', '02') AND NEW.cco_numero !~ '^[0-9]{3}-[0-9]{3}-[0-9]{9}$' THEN
        RAISE EXCEPTION 'El número % no tiene el formato del SRI (001-001-000000123)', NEW.cco_numero;
    END IF;
    IF NEW.cco_clave_acceso IS NOT NULL AND NEW.cco_clave_acceso !~ '^[0-9]{49}$' THEN
        RAISE EXCEPTION 'La clave de acceso debe tener 49 dígitos';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER tr_comprobante_compra_validar BEFORE INSERT OR UPDATE ON comprobante_compra
    FOR EACH ROW EXECUTE FUNCTION tg_comprobante_compra_validar();

-- Cuenta por cobrar: cliente identificado, momento correcto del pedido y
-- límite de crédito. CREDITO solo sobre un pedido pendiente (se factura en
-- la misma operación); AVANCE solo sobre una compra ya facturada.
CREATE FUNCTION tg_cuenta_por_cobrar_validar() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    v_cliente  INTEGER;
    v_estado   VARCHAR(3);
    v_limite   NUMERIC;
    v_deuda    NUMERIC;
    v_total    NUMERIC;
    v_cubierto NUMERIC;
BEGIN
    SELECT id_cliente INTO v_cliente FROM pedido WHERE id_pedido = NEW.id_pedido FOR UPDATE;
    SELECT id_estado_pedido INTO v_estado FROM v_pedido_estado_actual WHERE id_pedido = NEW.id_pedido;

    IF NOT EXISTS (SELECT 1 FROM datos_facturacion
                   WHERE id_cliente = v_cliente AND dfa_activo AND id_tipo_identificacion <> '07') THEN
        RAISE EXCEPTION 'Crédito y avances solo para clientes identificados (cédula, RUC o pasaporte), no para consumidor final';
    END IF;
    IF NEW.cxc_fecha_vencimiento < CURRENT_DATE THEN
        RAISE EXCEPTION 'El vencimiento no puede ser anterior a hoy';
    END IF;

    IF NEW.cxc_tipo = 'CREDITO' THEN
        IF v_estado IS DISTINCT FROM 'PEN' THEN
            RAISE EXCEPTION 'El crédito se otorga sobre un pedido pendiente, al facturarlo (pedido % en estado %)',
                NEW.id_pedido, COALESCE(v_estado, '-');
        END IF;
        SELECT total    INTO v_total    FROM v_pedido_totales WHERE id_pedido = NEW.id_pedido;
        SELECT cubierto INTO v_cubierto FROM v_pedido_pagos   WHERE id_pedido = NEW.id_pedido;
        IF NEW.cxc_monto > v_total - v_cubierto THEN
            RAISE EXCEPTION 'El crédito (%) supera el saldo por pagar del pedido (%)', NEW.cxc_monto, v_total - v_cubierto;
        END IF;
    ELSIF v_estado IS NULL OR v_estado NOT IN ('FAC', 'DES', 'ENT') THEN
        RAISE EXCEPTION 'El avance se entrega sobre una compra ya facturada (pedido % en estado %)',
            NEW.id_pedido, COALESCE(v_estado, '-');
    END IF;

    SELECT cli_limite_credito INTO v_limite FROM cliente WHERE id_cliente = v_cliente FOR UPDATE;
    SELECT deuda_total INTO v_deuda FROM v_estado_cuenta_cliente WHERE id_cliente = v_cliente;
    IF v_deuda + NEW.cxc_monto > v_limite THEN
        RAISE EXCEPTION 'Supera el límite de crédito del cliente (límite %, deuda actual %, solicitado %)',
            v_limite, v_deuda, NEW.cxc_monto;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER tr_cuenta_por_cobrar_validar BEFORE INSERT ON cuenta_por_cobrar
    FOR EACH ROW EXECUTE FUNCTION tg_cuenta_por_cobrar_validar();

-- Abono: no supera el saldo de la cuenta; si compensa una nota de crédito,
-- esta debe ser del mismo cliente y tener valor disponible
CREATE FUNCTION tg_abono_validar() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    v_saldo      NUMERIC;
    v_cliente    INTEGER;
    v_cliente_nc INTEGER;
    v_disponible NUMERIC;
BEGIN
    PERFORM 1 FROM cuenta_por_cobrar WHERE id_cuenta_por_cobrar = NEW.id_cuenta_por_cobrar FOR UPDATE;
    SELECT saldo, id_cliente INTO v_saldo, v_cliente
    FROM v_cuentas_por_cobrar WHERE id_cuenta_por_cobrar = NEW.id_cuenta_por_cobrar;
    IF NEW.abo_monto > v_saldo THEN
        RAISE EXCEPTION 'El abono (%) supera el saldo de la cuenta (%)', NEW.abo_monto, v_saldo;
    END IF;

    IF NEW.id_nota_credito IS NOT NULL THEN
        PERFORM 1 FROM nota_credito WHERE id_nota_credito = NEW.id_nota_credito FOR UPDATE;
        SELECT p.id_cliente INTO v_cliente_nc
        FROM nota_credito n JOIN comprobante_venta f ON f.id_comprobante_venta = n.id_comprobante_venta JOIN pedido p ON p.id_pedido = f.id_pedido
        WHERE n.id_nota_credito = NEW.id_nota_credito;
        IF v_cliente_nc <> v_cliente THEN
            RAISE EXCEPTION 'La nota de crédito es de otro cliente';
        END IF;
        SELECT n.total
             - COALESCE((SELECT SUM(ree_monto) FROM reembolso     WHERE id_nota_credito = n.id_nota_credito), 0)
             - COALESCE((SELECT SUM(abo_monto) FROM abono_cliente WHERE id_nota_credito = n.id_nota_credito), 0)
          INTO v_disponible
        FROM v_nota_credito n WHERE n.id_nota_credito = NEW.id_nota_credito;
        IF NEW.abo_monto > v_disponible THEN
            RAISE EXCEPTION 'La nota de crédito solo tiene % disponibles', v_disponible;
        END IF;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER tr_abono_validar BEFORE INSERT ON abono_cliente
    FOR EACH ROW EXECUTE FUNCTION tg_abono_validar();

-- Un paquete solo se corta de una pieza de la misma variante
CREATE FUNCTION tg_lote_validar() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = produccion, public AS $$
BEGIN
    IF NEW.id_lote_origen IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM lote WHERE id_lote = NEW.id_lote_origen AND id_variante = NEW.id_variante) THEN
        RAISE EXCEPTION 'La pieza de origen debe ser de la misma variante';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER tr_lote_validar BEFORE INSERT ON lote
    FOR EACH ROW EXECUTE FUNCTION tg_lote_validar();


-- B11. Ofertas: sin solapes por producto; una oferta ya aplicada en ventas
--      no cambia su producto, porcentaje ni inicio (solo se pausa, se
--      reactiva o se le pone fin) y no se elimina.
CREATE FUNCTION tg_oferta_validar() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    v_otra INTEGER;
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') AND EXISTS (SELECT 1 FROM detalle_pedido WHERE id_oferta = OLD.id_oferta) THEN
        IF TG_OP = 'DELETE' THEN
            RAISE EXCEPTION 'La oferta % ya se aplicó en ventas: no se elimina, se desactiva', OLD.id_oferta;
        END IF;
        IF (NEW.id_producto, NEW.ofe_porcentaje, NEW.ofe_desde) IS DISTINCT FROM (OLD.id_producto, OLD.ofe_porcentaje, OLD.ofe_desde) THEN
            RAISE EXCEPTION 'La oferta % ya se aplicó en ventas: solo se puede pausar, reactivar o cambiar su fecha de fin. Para otro porcentaje registre una oferta nueva',
                OLD.id_oferta;
        END IF;
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    IF NEW.ofe_activa THEN
        SELECT o.id_oferta INTO v_otra
        FROM oferta o
        WHERE o.id_producto = NEW.id_producto AND o.ofe_activa AND o.id_oferta <> NEW.id_oferta
          AND o.ofe_desde < COALESCE(NEW.ofe_hasta, 'infinity'::TIMESTAMP)
          AND NEW.ofe_desde < COALESCE(o.ofe_hasta, 'infinity'::TIMESTAMP)
        LIMIT 1;
        IF v_otra IS NOT NULL THEN
            RAISE EXCEPTION 'El producto ya tiene una oferta activa en ese período (oferta %)', v_otra;
        END IF;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER tr_oferta_validar BEFORE INSERT OR UPDATE OR DELETE ON oferta
    FOR EACH ROW EXECUTE FUNCTION tg_oferta_validar();


-- B12. Auditoría de tablas sensibles: guarda la fila antes y después del
--      cambio, quién lo hizo (usuario de la aplicación tomado de la sesión
--      con app.id_usuario, que fija fn_exigir_permiso) y desde qué
--      conexión. Nunca guarda hashes de clave; el último acceso no audita.
--      Argumentos del disparador: columnas de la clave primaria.
CREATE FUNCTION tg_auditar() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    v_ant  JSONB;
    v_nue  JSONB;
    v_fila JSONB;
    v_id   TEXT := '';
    v_usu  INTEGER;
    i      INTEGER;
BEGIN
    IF TG_OP <> 'INSERT' THEN v_ant := to_jsonb(OLD) - 'usu_ultimo_acceso'; END IF;
    IF TG_OP <> 'DELETE' THEN v_nue := to_jsonb(NEW) - 'usu_ultimo_acceso'; END IF;
    IF v_ant ? 'usu_hash_clave' OR v_nue ? 'usu_hash_clave' THEN
        IF TG_OP = 'UPDATE' AND v_ant ->> 'usu_hash_clave' IS DISTINCT FROM v_nue ->> 'usu_hash_clave' THEN
            v_ant := jsonb_set(v_ant, '{usu_hash_clave}', '"(oculta)"');
            v_nue := jsonb_set(v_nue, '{usu_hash_clave}', '"(cambiada)"');
        ELSE
            IF v_ant IS NOT NULL THEN v_ant := jsonb_set(v_ant, '{usu_hash_clave}', '"(oculta)"'); END IF;
            IF v_nue IS NOT NULL THEN v_nue := jsonb_set(v_nue, '{usu_hash_clave}', '"(oculta)"'); END IF;
        END IF;
    END IF;
    IF TG_OP = 'UPDATE' AND v_ant = v_nue THEN
        RETURN NULL;
    END IF;
    v_fila := COALESCE(v_nue, v_ant);
    FOR i IN 0 .. TG_NARGS - 1 LOOP
        v_id := v_id || CASE WHEN i > 0 THEN ',' ELSE '' END || COALESCE(v_fila ->> TG_ARGV[i], '');
    END LOOP;
    BEGIN
        v_usu := NULLIF(current_setting('app.id_usuario', TRUE), '')::INTEGER;
    EXCEPTION WHEN invalid_text_representation THEN
        v_usu := NULL;
    END;
    INSERT INTO auditoria (aud_tabla, aud_operacion, aud_id_registro, aud_valores_anteriores, aud_valores_nuevos, id_usuario)
    VALUES (TG_TABLE_NAME, LEFT(TG_OP, 1), v_id, v_ant::TEXT, v_nue::TEXT,
            (SELECT id_usuario FROM usuario WHERE id_usuario = v_usu));
    RETURN NULL;
END $$;

CREATE TRIGGER tr_usuario_auditar            AFTER INSERT OR UPDATE OR DELETE ON usuario
    FOR EACH ROW EXECUTE FUNCTION tg_auditar('id_usuario');
CREATE TRIGGER tr_usuario_rol_auditar        AFTER INSERT OR UPDATE OR DELETE ON usuario_rol
    FOR EACH ROW EXECUTE FUNCTION tg_auditar('id_usuario', 'id_rol');
CREATE TRIGGER tr_rol_permiso_auditar        AFTER INSERT OR UPDATE OR DELETE ON rol_permiso
    FOR EACH ROW EXECUTE FUNCTION tg_auditar('id_rol', 'id_permiso');
CREATE TRIGGER tr_empleado_auditar           AFTER INSERT OR UPDATE OR DELETE ON empleado
    FOR EACH ROW EXECUTE FUNCTION tg_auditar('id_usuario');
CREATE TRIGGER tr_cliente_auditar            AFTER INSERT OR UPDATE OR DELETE ON cliente
    FOR EACH ROW EXECUTE FUNCTION tg_auditar('id_cliente');
CREATE TRIGGER tr_datos_facturacion_auditar  AFTER INSERT OR UPDATE OR DELETE ON datos_facturacion
    FOR EACH ROW EXECUTE FUNCTION tg_auditar('id_datos_facturacion');
CREATE TRIGGER tr_empresa_auditar            AFTER INSERT OR UPDATE OR DELETE ON empresa
    FOR EACH ROW EXECUTE FUNCTION tg_auditar('id_empresa');
CREATE TRIGGER tr_punto_emision_auditar      AFTER INSERT OR UPDATE OR DELETE ON punto_emision
    FOR EACH ROW EXECUTE FUNCTION tg_auditar('id_punto_emision');
CREATE TRIGGER tr_categoria_auditar          AFTER INSERT OR UPDATE OR DELETE ON categoria
    FOR EACH ROW EXECUTE FUNCTION tg_auditar('id_categoria');
CREATE TRIGGER tr_producto_auditar           AFTER INSERT OR UPDATE OR DELETE ON producto
    FOR EACH ROW EXECUTE FUNCTION tg_auditar('id_producto');
CREATE TRIGGER tr_variante_auditar           AFTER INSERT OR UPDATE OR DELETE ON variante
    FOR EACH ROW EXECUTE FUNCTION tg_auditar('id_variante');
CREATE TRIGGER tr_presentacion_auditar       AFTER INSERT OR UPDATE OR DELETE ON presentacion
    FOR EACH ROW EXECUTE FUNCTION tg_auditar('id_presentacion');
CREATE TRIGGER tr_oferta_auditar             AFTER INSERT OR UPDATE OR DELETE ON oferta
    FOR EACH ROW EXECUTE FUNCTION tg_auditar('id_oferta');
CREATE TRIGGER tr_proveedor_auditar          AFTER INSERT OR UPDATE OR DELETE ON proveedor
    FOR EACH ROW EXECUTE FUNCTION tg_auditar('id_proveedor');
CREATE TRIGGER tr_orden_compra_auditar       AFTER INSERT OR UPDATE OR DELETE ON orden_compra
    FOR EACH ROW EXECUTE FUNCTION tg_auditar('id_orden_compra');
CREATE TRIGGER tr_detalle_oc_auditar         AFTER INSERT OR UPDATE OR DELETE ON detalle_orden_compra
    FOR EACH ROW EXECUTE FUNCTION tg_auditar('id_detalle_orden_compra');
CREATE TRIGGER tr_comprobante_venta_auditar            AFTER UPDATE OR DELETE ON comprobante_venta
    FOR EACH ROW EXECUTE FUNCTION tg_auditar('id_comprobante_venta');
CREATE TRIGGER tr_nota_credito_auditar       AFTER UPDATE OR DELETE ON nota_credito
    FOR EACH ROW EXECUTE FUNCTION tg_auditar('id_nota_credito');


-- =====================================================================
-- C. FUNCIONES DEL FLUJO
-- =====================================================================

-- C1. Control de permisos por rol
CREATE FUNCTION fn_exigir_permiso(p_usuario INTEGER, p_permiso VARCHAR)
RETURNS VOID LANGUAGE plpgsql SET search_path = produccion, public AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM usuario u
        JOIN usuario_rol ur ON ur.id_usuario = u.id_usuario
        JOIN rol_permiso rp ON rp.id_rol     = ur.id_rol
        JOIN permiso     pe ON pe.id_permiso = rp.id_permiso
        WHERE u.id_usuario = p_usuario AND u.usu_activo AND pe.per_codigo = p_permiso) THEN
        RAISE EXCEPTION 'El usuario % no tiene el permiso %',
            COALESCE((SELECT usu_correo FROM usuario WHERE id_usuario = p_usuario), p_usuario::TEXT), p_permiso
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    -- Quien actúa queda en la sesión: la auditoría lo toma de aquí
    PERFORM set_config('app.id_usuario', p_usuario::TEXT, TRUE);
END $$;


-- C1b. Bitácora del sistema interno. Se registra dentro de la transacción
--      del proceso: si el proceso falla, su evento tampoco queda (los
--      intentos fallidos, como un acceso con clave errada, los registra
--      la aplicación con fn_registrar_acceso en su propia transacción).
CREATE FUNCTION fn_log(p_nivel VARCHAR, p_origen VARCHAR, p_evento VARCHAR, p_mensaje VARCHAR,
                       p_usuario INTEGER DEFAULT NULL, p_detalle JSONB DEFAULT NULL, p_ip VARCHAR DEFAULT NULL)
RETURNS BIGINT LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    v_id BIGINT;
BEGIN
    INSERT INTO log_evento (lev_nivel, lev_origen, lev_evento, lev_mensaje, id_usuario, lev_ip, lev_detalle)
    VALUES (p_nivel, p_origen, p_evento, LEFT(p_mensaje, 500), p_usuario, p_ip, p_detalle::TEXT)
    RETURNING id_log_evento INTO v_id;
    RETURN v_id;
END $$;

-- C1c. Usuario de la aplicación en la sesión, para cambios hechos directo
--      en las tablas (las funciones del flujo lo fijan solas)
CREATE FUNCTION fn_usuario_sesion(p_usuario INTEGER)
RETURNS VOID LANGUAGE plpgsql SET search_path = produccion, public AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM usuario WHERE id_usuario = p_usuario AND usu_activo) THEN
        RAISE EXCEPTION 'El usuario % no existe o está inactivo', p_usuario;
    END IF;
    PERFORM set_config('app.id_usuario', p_usuario::TEXT, TRUE);
END $$;

-- C1d. Inicio de sesión del personal (la aplicación valida la clave y
--      registra aquí el resultado). Devuelve el usuario si el acceso vale.
CREATE FUNCTION fn_registrar_acceso(p_correo VARCHAR, p_exito BOOLEAN, p_ip VARCHAR DEFAULT NULL)
RETURNS INTEGER LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    u RECORD;
BEGIN
    SELECT id_usuario, usu_activo INTO u FROM usuario WHERE usu_correo = LOWER(TRIM(p_correo));
    IF p_exito AND FOUND AND u.usu_activo THEN
        UPDATE usuario SET usu_ultimo_acceso = CURRENT_TIMESTAMP WHERE id_usuario = u.id_usuario;
        PERFORM fn_log('INFO', 'SEGURIDAD', 'LOGIN_OK', 'Inicio de sesión de ' || LOWER(TRIM(p_correo)), u.id_usuario, NULL, p_ip);
        RETURN u.id_usuario;
    END IF;
    PERFORM fn_log('AVISO', 'SEGURIDAD',
                   CASE WHEN FOUND AND NOT u.usu_activo THEN 'LOGIN_BLOQUEADO' ELSE 'LOGIN_FALLIDO' END,
                   'Acceso rechazado para ' || LOWER(TRIM(p_correo)), u.id_usuario, NULL, p_ip);
    RETURN NULL;
END $$;


-- C2. Clave de acceso SRI (49 dígitos, dígito verificador módulo 11)
--     p_tipo: '01' factura, '04' nota de crédito
CREATE FUNCTION fn_clave_acceso(p_fecha DATE, p_tipo CHAR(2), p_punto INTEGER, p_secuencial INTEGER)
RETURNS CHAR(49) LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    v_base  TEXT;
    v_suma  INTEGER := 0;
    v_peso  INTEGER := 2;
    v_dv    INTEGER;
    i       INTEGER;
BEGIN
    SELECT TO_CHAR(p_fecha, 'DDMMYYYY') || p_tipo || e.emp_ruc || e.emp_ambiente_sri
           || pe.pem_establecimiento || pe.pem_punto || LPAD(p_secuencial::TEXT, 9, '0')
           || LPAD((FLOOR(RANDOM() * 100000000))::BIGINT::TEXT, 8, '0')   -- código numérico
           || '1'                                                         -- emisión normal
      INTO v_base
    FROM empresa e, punto_emision pe
    WHERE pe.id_punto_emision = p_punto;

    FOR i IN REVERSE LENGTH(v_base)..1 LOOP
        v_suma := v_suma + SUBSTR(v_base, i, 1)::INTEGER * v_peso;
        v_peso := CASE WHEN v_peso = 7 THEN 2 ELSE v_peso + 1 END;
    END LOOP;
    v_dv := 11 - (v_suma % 11);
    v_dv := CASE v_dv WHEN 11 THEN 0 WHEN 10 THEN 1 ELSE v_dv END;
    RETURN v_base || v_dv;
END $$;


-- C3. Cambio de estado del pedido (las transiciones se validan en B3)
CREATE FUNCTION fn_cambiar_estado_pedido(p_pedido INTEGER, p_estado VARCHAR,
                                         p_usuario INTEGER DEFAULT NULL, p_observacion VARCHAR DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SET search_path = produccion, public AS $$
BEGIN
    IF p_estado IN ('DES', 'ENT') THEN
        IF p_usuario IS NULL THEN
            RAISE EXCEPTION 'Indique el usuario que despacha o entrega el pedido';
        END IF;
        PERFORM fn_exigir_permiso(p_usuario, 'PEDIDO_DESPACHAR');
    END IF;
    INSERT INTO historial_estado_pedido (id_pedido, id_estado_pedido, id_usuario, hep_observacion)
    VALUES (p_pedido, p_estado, p_usuario, p_observacion);
END $$;


-- C4. Crear un pedido (venta web, en tienda o por WhatsApp)
--     p_lineas: [{"id_presentacion": 5, "cantidad": 2, "valor_final": 20.00}, ...]
--     Toma el precio vigente, la oferta vigente y la tarifa de IVA del
--     producto en ese momento y reserva el stock (falla si no hay disponible).
--     Los pedidos web los pide el nodo e-commerce (fn_crear_pedido_desde_carrito).
CREATE FUNCTION fn_crear_pedido(p_cliente INTEGER, p_canal VARCHAR, p_lineas JSONB,
                                p_vendedor INTEGER DEFAULT NULL,
                                p_observacion VARCHAR DEFAULT NULL)
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = produccion, public AS $$
DECLARE
    v_pedido  INTEGER;
    v_usuario INTEGER;
    v_desc    NUMERIC;
    v_lista   NUMERIC;
    v_base    NUMERIC;
    r         RECORD;
    pr        RECORD;
BEGIN
    IF p_lineas IS NULL OR jsonb_array_length(p_lineas) = 0 THEN
        RAISE EXCEPTION 'El pedido no tiene líneas';
    END IF;

    -- Quién registra: el vendedor en tienda/WhatsApp. En la web no hay usuario
    -- interno: el pedido lo pide el nodo e-commerce, que ya validó la cuenta
    -- del cliente (en el historial queda sin usuario)
    IF p_canal = 'WEB' THEN
        IF NOT EXISTS (SELECT 1 FROM cliente WHERE id_cliente = p_cliente) THEN
            RAISE EXCEPTION 'El cliente % no existe', p_cliente;
        END IF;
    ELSE
        IF p_vendedor IS NULL THEN
            RAISE EXCEPTION 'Las ventas del canal % requieren vendedor', p_canal;
        END IF;
        PERFORM fn_exigir_permiso(p_vendedor, 'VENTA_REGISTRAR');
        v_usuario := p_vendedor;
    END IF;

    -- Serializa las reservas por variante (evita vender dos veces el mismo stock)
    PERFORM pg_advisory_xact_lock(1, s.id_variante)
    FROM (SELECT DISTINCT pr2.id_variante
          FROM jsonb_to_recordset(p_lineas) AS x(id_presentacion INTEGER)
          JOIN presentacion pr2 ON pr2.id_presentacion = x.id_presentacion
          ORDER BY pr2.id_variante) s;

    INSERT INTO pedido (id_cliente, id_canal_venta, id_empleado_vendedor, ped_observacion)
    VALUES (p_cliente, p_canal, CASE WHEN p_canal = 'WEB' THEN NULL ELSE p_vendedor END, p_observacion)
    RETURNING id_pedido INTO v_pedido;

    -- Cada línea puede traer un descuento en monto o, mejor, el valor final
    -- pactado con el cliente (con IVA): la base calcula el descuento
    FOR r IN SELECT x.id_presentacion, x.cantidad, COALESCE(x.descuento, 0) AS descuento, x.valor_final
             FROM jsonb_to_recordset(p_lineas) AS x(id_presentacion INTEGER, cantidad NUMERIC, descuento NUMERIC,
                                                    valor_final NUMERIC)
    LOOP
        SELECT pre.pre_descripcion, pre.pre_cantidad_minima, v.var_sku, p.id_tarifa_iva, pv.precio, t.tiv_porcentaje,
               COALESCE(ov.ofe_porcentaje, 0) AS pct_oferta
          INTO pr
        FROM presentacion pre
        JOIN variante v  ON v.id_variante = pre.id_variante
        JOIN producto p  ON p.id_producto = v.id_producto
        JOIN tarifa_iva t ON t.id_tarifa_iva = p.id_tarifa_iva
        JOIN v_precio_vigente pv ON pv.id_presentacion = pre.id_presentacion
        LEFT JOIN v_oferta_vigente ov ON ov.id_producto = p.id_producto
        WHERE pre.id_presentacion = r.id_presentacion
          AND pre.pre_activa AND v.var_activa;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'La presentación % no está disponible para la venta', r.id_presentacion;
        END IF;
        IF r.cantidad < pr.pre_cantidad_minima THEN
            RAISE EXCEPTION 'La compra mínima de % (%) es %', pr.var_sku, pr.pre_descripcion, pr.pre_cantidad_minima;
        END IF;
        v_desc := r.descuento;
        IF r.valor_final IS NOT NULL THEN
            -- se negocia desde el precio que ya tiene la oferta
            v_lista := ROUND(r.cantidad * pr.precio, 2) - ROUND(r.cantidad * pr.precio * pr.pct_oferta / 100, 2);
            v_base  := fn_base_desde_final(r.valor_final, pr.tiv_porcentaje, TRUE);
            IF v_base > v_lista THEN
                RAISE EXCEPTION 'El valor pactado (%) supera el precio de lista de % (%); la negociación solo baja el precio',
                    r.valor_final, pr.var_sku, v_lista + ROUND(v_lista * pr.tiv_porcentaje / 100, 2);
            END IF;
            v_desc := v_lista - v_base;
        END IF;
        IF v_desc > 0 AND p_canal = 'WEB' THEN
            RAISE EXCEPTION 'Los descuentos negociados solo se permiten en tienda o WhatsApp, no en el e-commerce';
        END IF;
        INSERT INTO detalle_pedido (id_pedido, id_presentacion, dpe_cantidad, dpe_precio_unitario, dpe_descuento,
                                    id_tarifa_iva, id_usuario_descuento)
        VALUES (v_pedido, r.id_presentacion, r.cantidad, pr.precio, v_desc, pr.id_tarifa_iva,
                CASE WHEN v_desc > 0 THEN p_vendedor END);
    END LOOP;

    INSERT INTO historial_estado_pedido (id_pedido, id_estado_pedido, id_usuario, hep_observacion)
    VALUES (v_pedido, 'PEN', v_usuario, 'Pedido creado');

    -- Productos que se venden por pieza (cuero): cada línea debe caber en
    -- una sola pieza, porque los retazos de varias piezas no se juntan
    FOR r IN SELECT v.var_sku, dv.cantidad_base, p.id_unidad_medida AS unidad,
                    (SELECT MAX(s.saldo) FROM v_lote_saldo s WHERE s.id_variante = dv.id_variante) AS mayor
             FROM v_detalle_pedido_valor dv
             JOIN variante v ON v.id_variante = dv.id_variante
             JOIN producto p ON p.id_producto = v.id_producto
             WHERE dv.id_pedido = v_pedido AND p.prd_venta_por_pieza
    LOOP
        IF COALESCE(r.mayor, 0) < r.cantidad_base THEN
            RAISE EXCEPTION 'Ninguna pieza de % alcanza para % % (la mayor tiene % %)',
                r.var_sku, r.cantidad_base, r.unidad, COALESCE(r.mayor, 0), r.unidad;
        END IF;
    END LOOP;

    -- Con este pedido ya reservado, ninguna variante puede quedar con disponible negativo
    FOR r IN SELECT s.var_sku, s.disponible, s.unidad
             FROM v_stock_variante s
             WHERE s.disponible < 0
               AND s.id_variante IN (SELECT id_variante FROM v_detalle_pedido_valor WHERE id_pedido = v_pedido)
    LOOP
        RAISE EXCEPTION 'Stock insuficiente para %: faltan % %', r.var_sku, -r.disponible, r.unidad;
    END LOOP;

    RETURN v_pedido;
END $$;


-- C4b. Negociación de precios (tienda y WhatsApp).
--      El vendedor escribe el VALOR FINAL que pactó con el cliente y la base
--      calcula el descuento. fn_base_desde_final convierte ese valor (con IVA)
--      a base imponible, de forma que base + IVA redondeado quede igual al
--      valor pactado; si por el redondeo no es posible exacto, queda al
--      centavo inmediatamente inferior (el cliente nunca paga de más).
CREATE FUNCTION fn_base_desde_final(p_valor_final NUMERIC, p_porcentaje_iva NUMERIC, p_con_iva BOOLEAN DEFAULT TRUE)
RETURNS NUMERIC LANGUAGE plpgsql IMMUTABLE SET search_path = produccion, public AS $$
DECLARE
    v_base        NUMERIC;
    v_candidata   NUMERIC;
    v_total       NUMERIC;
    v_mejor       NUMERIC;
    v_mejor_total NUMERIC;
    i             INTEGER;
BEGIN
    IF p_valor_final IS NULL OR p_valor_final <= 0 THEN
        RAISE EXCEPTION 'El valor pactado debe ser mayor que cero';
    END IF;
    IF NOT p_con_iva OR p_porcentaje_iva = 0 THEN
        RETURN ROUND(p_valor_final, 2);
    END IF;
    v_base := ROUND(p_valor_final / (1 + p_porcentaje_iva / 100), 2);
    FOR i IN -2..2 LOOP
        v_candidata := v_base + i * 0.01;
        v_total := v_candidata + ROUND(v_candidata * p_porcentaje_iva / 100, 2);
        IF v_candidata > 0 AND v_total <= p_valor_final AND (v_mejor_total IS NULL OR v_total > v_mejor_total) THEN
            v_mejor := v_candidata;
            v_mejor_total := v_total;
        END IF;
    END LOOP;
    RETURN v_mejor;
END $$;

-- Negociar una línea: devuelve el nuevo valor de la línea con IVA
CREATE FUNCTION fn_negociar_linea(p_detalle_pedido INTEGER, p_valor_final NUMERIC, p_usuario INTEGER,
                                  p_con_iva BOOLEAN DEFAULT TRUE)
RETURNS NUMERIC LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    r       RECORD;
    v_lista NUMERIC;
    v_base  NUMERIC;
    v_estado VARCHAR(3);
BEGIN
    PERFORM fn_exigir_permiso(p_usuario, 'PRECIO_NEGOCIAR');
    SELECT d.id_pedido, d.dpe_cantidad, d.dpe_precio_unitario, t.tiv_porcentaje, p.id_canal_venta
      INTO r
    FROM detalle_pedido d
    JOIN pedido p ON p.id_pedido = d.id_pedido
    JOIN tarifa_iva t ON t.id_tarifa_iva = d.id_tarifa_iva
    WHERE d.id_detalle_pedido = p_detalle_pedido;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La línea de pedido % no existe', p_detalle_pedido;
    END IF;
    PERFORM 1 FROM pedido WHERE id_pedido = r.id_pedido FOR UPDATE;
    IF r.id_canal_venta = 'WEB' THEN
        RAISE EXCEPTION 'Los descuentos negociados solo se permiten en tienda o WhatsApp, no en el e-commerce';
    END IF;
    SELECT id_estado_pedido INTO v_estado FROM v_pedido_estado_actual WHERE id_pedido = r.id_pedido;
    IF v_estado <> 'PEN' THEN
        RAISE EXCEPTION 'El pedido % está en estado % y ya no se puede modificar', r.id_pedido, v_estado;
    END IF;

    -- se negocia desde el precio que ya tiene la oferta
    SELECT valor_lista - descuento_oferta INTO v_lista
    FROM v_detalle_pedido_valor WHERE id_detalle_pedido = p_detalle_pedido;
    v_base  := fn_base_desde_final(p_valor_final, r.tiv_porcentaje, p_con_iva);
    IF v_base > v_lista THEN
        RAISE EXCEPTION 'El valor pactado supera el precio de lista (% con IVA); la negociación solo baja el precio',
            v_lista + ROUND(v_lista * r.tiv_porcentaje / 100, 2);
    END IF;
    UPDATE detalle_pedido
    SET dpe_descuento = v_lista - v_base,
        id_usuario_descuento = CASE WHEN v_lista - v_base > 0 THEN p_usuario END
    WHERE id_detalle_pedido = p_detalle_pedido;
    RETURN (SELECT base_imponible + iva FROM v_detalle_pedido_valor WHERE id_detalle_pedido = p_detalle_pedido);
END $$;

-- Negociar el total del pedido ("le dejo todo en 100"): el valor final
-- incluye el envío, que no se rebaja; el descuento de los productos se
-- reparte en proporción al valor de cada línea. Devuelve el nuevo total.
CREATE FUNCTION fn_negociar_pedido(p_pedido INTEGER, p_total_final NUMERIC, p_usuario INTEGER,
                                   p_con_iva BOOLEAN DEFAULT TRUE)
RETURNS NUMERIC LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    v_canal    VARCHAR(3);
    v_estado   VARCHAR(3);
    v_envio    NUMERIC;
    v_objetivo NUMERIC;
    v_suma     NUMERIC;
    v_acum     NUMERIC := 0;
    v_meta     NUMERIC;
    v_base     NUMERIC;
    v_n        INTEGER;
    v_i        INTEGER := 0;
    r          RECORD;
BEGIN
    PERFORM fn_exigir_permiso(p_usuario, 'PRECIO_NEGOCIAR');
    SELECT id_canal_venta INTO v_canal FROM pedido WHERE id_pedido = p_pedido FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El pedido % no existe', p_pedido;
    END IF;
    IF v_canal = 'WEB' THEN
        RAISE EXCEPTION 'Los descuentos negociados solo se permiten en tienda o WhatsApp, no en el e-commerce';
    END IF;
    SELECT id_estado_pedido INTO v_estado FROM v_pedido_estado_actual WHERE id_pedido = p_pedido;
    IF v_estado <> 'PEN' THEN
        RAISE EXCEPTION 'El pedido % está en estado % y ya no se puede modificar', p_pedido, v_estado;
    END IF;

    SELECT COALESCE(SUM(e.env_costo + CASE WHEN p_con_iva THEN ROUND(e.env_costo * t.tiv_porcentaje / 100, 2) ELSE 0 END), 0)
      INTO v_envio
    FROM envio e JOIN tarifa_iva t ON t.id_tarifa_iva = e.id_tarifa_iva
    WHERE e.id_pedido = p_pedido;
    v_objetivo := p_total_final - v_envio;

    -- valor_lista aquí es el precio con oferta: la negociación parte de él
    SELECT SUM(valor_lista + CASE WHEN p_con_iva THEN ROUND(valor_lista * tiv_porcentaje / 100, 2) ELSE 0 END), COUNT(*)
      INTO v_suma, v_n
    FROM (SELECT valor_lista - descuento_oferta AS valor_lista, tiv_porcentaje
          FROM v_detalle_pedido_valor WHERE id_pedido = p_pedido) x;
    IF v_objetivo <= 0 THEN
        RAISE EXCEPTION 'El valor pactado no cubre ni el envío (%)', v_envio;
    END IF;
    IF v_objetivo > v_suma THEN
        RAISE EXCEPTION 'El valor pactado supera el precio de lista (%); la negociación solo baja el precio', v_suma + v_envio;
    END IF;

    -- La línea de mayor valor va al final y absorbe el redondeo
    FOR r IN SELECT id_detalle_pedido, valor_lista, tiv_porcentaje,
                    valor_lista + CASE WHEN p_con_iva THEN ROUND(valor_lista * tiv_porcentaje / 100, 2) ELSE 0 END AS referencia
             FROM (SELECT id_detalle_pedido, valor_lista - descuento_oferta AS valor_lista, tiv_porcentaje
                   FROM v_detalle_pedido_valor WHERE id_pedido = p_pedido) x
             ORDER BY 4, id_detalle_pedido
    LOOP
        v_i := v_i + 1;
        v_meta := CASE WHEN v_i < v_n THEN ROUND(v_objetivo * r.referencia / v_suma, 2) ELSE v_objetivo - v_acum END;
        v_base := LEAST(fn_base_desde_final(v_meta, r.tiv_porcentaje, p_con_iva), r.valor_lista);
        v_acum := v_acum + v_base + CASE WHEN p_con_iva THEN ROUND(v_base * r.tiv_porcentaje / 100, 2) ELSE 0 END;
        UPDATE detalle_pedido
        SET dpe_descuento = r.valor_lista - v_base,
            id_usuario_descuento = CASE WHEN r.valor_lista - v_base > 0 THEN p_usuario END
        WHERE id_detalle_pedido = r.id_detalle_pedido;
    END LOOP;
    RETURN (SELECT total FROM v_pedido_totales WHERE id_pedido = p_pedido);
END $$;


-- C5. Registrar un cliente (lo usa la tienda y el registro del e-commerce).
--     Si ya existe un cliente con ese correo, devuelve el mismo: un cliente
--     que compraba en tienda conserva su historial y su crédito al abrir
--     una cuenta en la web.
CREATE FUNCTION fn_registrar_cliente(p_nombres VARCHAR, p_apellidos VARCHAR, p_correo VARCHAR,
                                     p_telefono VARCHAR DEFAULT NULL)
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = produccion, public AS $$
DECLARE
    v_cliente INTEGER;
    v_correo  VARCHAR := NULLIF(LOWER(TRIM(p_correo)), '');
BEGIN
    IF COALESCE(TRIM(p_nombres), '') = '' THEN
        RAISE EXCEPTION 'Indique el nombre del cliente';
    END IF;
    IF v_correo IS NOT NULL THEN
        SELECT id_cliente INTO v_cliente FROM cliente WHERE cli_correo = v_correo;
    END IF;
    IF v_cliente IS NULL THEN
        INSERT INTO cliente (cli_nombres, cli_apellidos, cli_correo)
        VALUES (TRIM(p_nombres), NULLIF(TRIM(p_apellidos), ''), v_correo)
        RETURNING id_cliente INTO v_cliente;
    END IF;
    IF p_telefono IS NOT NULL AND NOT EXISTS (SELECT 1 FROM telefono WHERE id_cliente = v_cliente AND tel_numero = p_telefono) THEN
        INSERT INTO telefono (id_cliente, tel_numero) VALUES (v_cliente, p_telefono);
    END IF;
    RETURN v_cliente;
END $$;


-- C6. Pagos: cuando los aprobados cubren el total, el pedido pasa a PAG
CREATE FUNCTION fn_verificar_pago_completo(p_pedido INTEGER, p_usuario INTEGER)
RETURNS VOID LANGUAGE plpgsql SET search_path = produccion, public AS $$
BEGIN
    IF (SELECT id_estado_pedido FROM v_pedido_estado_actual WHERE id_pedido = p_pedido) = 'PEN'
       AND (SELECT cubierto FROM v_pedido_pagos  WHERE id_pedido = p_pedido)
        >= (SELECT total    FROM v_pedido_totales WHERE id_pedido = p_pedido) THEN
        PERFORM fn_cambiar_estado_pedido(p_pedido, 'PAG', p_usuario,
            CASE WHEN (SELECT credito FROM v_pedido_pagos WHERE id_pedido = p_pedido) > 0
                 THEN 'Pago inicial y crédito aprobado' ELSE 'Pago completo' END);
    END IF;
END $$;

CREATE FUNCTION fn_registrar_pago(p_pedido INTEGER, p_metodo INTEGER, p_monto NUMERIC, p_usuario INTEGER,
                                  p_referencia VARCHAR DEFAULT NULL, p_aprobado BOOLEAN DEFAULT TRUE)
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = produccion, public AS $$
DECLARE
    v_pago   INTEGER;
    v_estado VARCHAR(3);
BEGIN
    PERFORM fn_exigir_permiso(p_usuario, 'PAGO_REGISTRAR');
    PERFORM 1 FROM pedido WHERE id_pedido = p_pedido FOR UPDATE;
    SELECT id_estado_pedido INTO v_estado FROM v_pedido_estado_actual WHERE id_pedido = p_pedido;
    IF v_estado IS DISTINCT FROM 'PEN' THEN
        RAISE EXCEPTION 'Solo se registran pagos de pedidos pendientes (pedido % en estado %)', p_pedido, COALESCE(v_estado, '-');
    END IF;
    INSERT INTO pago (id_pedido, id_metodo_pago, pag_monto, pag_referencia, pag_estado, id_usuario_registra)
    VALUES (p_pedido, p_metodo, p_monto, p_referencia,
            CASE WHEN p_aprobado THEN 'APROBADO' ELSE 'PENDIENTE' END, p_usuario)
    RETURNING id_pago INTO v_pago;
    PERFORM fn_verificar_pago_completo(p_pedido, p_usuario);
    RETURN v_pago;
END $$;

-- Respuesta de la pasarela o validación de una transferencia
CREATE FUNCTION fn_confirmar_pago(p_pago INTEGER, p_aprobado BOOLEAN, p_usuario INTEGER)
RETURNS VOID LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    v_pedido INTEGER;
BEGIN
    PERFORM fn_exigir_permiso(p_usuario, 'PAGO_REGISTRAR');
    UPDATE pago SET pag_estado = CASE WHEN p_aprobado THEN 'APROBADO' ELSE 'RECHAZADO' END
    WHERE id_pago = p_pago AND pag_estado = 'PENDIENTE'
    RETURNING id_pedido INTO v_pedido;
    IF v_pedido IS NULL THEN
        RAISE EXCEPTION 'El pago % no existe o ya fue confirmado', p_pago;
    END IF;
    PERFORM fn_verificar_pago_completo(v_pedido, p_usuario);
END $$;


-- C7. Consumo de lotes por FEFO/PEPS: primero lo que vence antes,
--     luego lo que ingresó primero. Puede repartir una salida en varios lotes.
CREATE FUNCTION fn_consumir_lotes(p_movimiento INTEGER, p_variante INTEGER, p_cantidad NUMERIC,
                                  p_detalle_pedido INTEGER DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    v_pendiente NUMERIC := p_cantidad;
    v_tomar     NUMERIC;
    r           RECORD;
BEGIN
    PERFORM pg_advisory_xact_lock(1, p_variante);
    PERFORM 1 FROM lote WHERE id_variante = p_variante ORDER BY id_lote FOR UPDATE;

    FOR r IN SELECT id_lote, saldo
             FROM v_lote_saldo
             WHERE id_variante = p_variante AND saldo > 0
             ORDER BY lot_fecha_vencimiento NULLS LAST, fecha_ingreso, id_lote
    LOOP
        EXIT WHEN v_pendiente <= 0;
        v_tomar := LEAST(r.saldo, v_pendiente);
        INSERT INTO detalle_movimiento (id_movimiento, id_lote, dmo_cantidad, id_detalle_pedido)
        VALUES (p_movimiento, r.id_lote, v_tomar, p_detalle_pedido);
        v_pendiente := v_pendiente - v_tomar;
    END LOOP;

    IF v_pendiente > 0 THEN
        RAISE EXCEPTION 'Stock insuficiente para %: faltan % %',
            (SELECT var_sku FROM variante WHERE id_variante = p_variante), v_pendiente,
            (SELECT p.id_unidad_medida FROM variante v JOIN producto p USING (id_producto) WHERE v.id_variante = p_variante);
    END IF;
END $$;


-- C8. Emitir el comprobante del pedido pagado: factura (por defecto) o
--     nota de venta (p_tipo_comprobante = '02'). Descarga el inventario
--     (movimiento VEN por lotes) y pasa el pedido a FAC.
--     · Factura: exige comprador, respeta el tope de consumidor final,
--       genera la clave de acceso y entra a la cola del SRI.
--     · Nota de venta: comprador opcional, sin clave ni SRI; el número
--       puede ser el del talonario (p_secuencial) o el siguiente.
--     Punto de emisión según el canal: tienda o e-commerce.
--     p_lotes (opcional): [{"id_detalle_pedido": 9, "id_lote": 14}, ...]
--       la pieza o lote que el vendedor escoge para cada línea; la línea
--       sale entera de ese lote. Sin elección: productos por pieza toman la
--       pieza más pequeña que alcance (aprovecha retazos); el resto, FEFO/PEPS.
CREATE FUNCTION fn_facturar_pedido(p_pedido INTEGER, p_datos_facturacion INTEGER,
                                   p_punto_emision INTEGER, p_usuario INTEGER,
                                   p_lotes JSONB DEFAULT NULL,
                                   p_tipo_comprobante CHAR(2) DEFAULT '01',
                                   p_secuencial INTEGER DEFAULT NULL)
RETURNS INTEGER LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    v_cliente    INTEGER;
    v_estado     VARCHAR(3);
    v_df         RECORD;
    v_max_cf     NUMERIC;
    v_total      NUMERIC;
    v_secuencial INTEGER;
    v_comprobante INTEGER;
    v_movimiento INTEGER;
    v_lote       INTEGER;
    v_tipo       RECORD;
    r            RECORD;
BEGIN
    PERFORM fn_exigir_permiso(p_usuario, 'VENTA_FACTURAR');
    SELECT * INTO v_tipo FROM tipo_comprobante WHERE id_tipo_comprobante = p_tipo_comprobante AND tco_en_venta;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El tipo de comprobante % no se usa en ventas', p_tipo_comprobante;
    END IF;

    SELECT id_cliente INTO v_cliente FROM pedido WHERE id_pedido = p_pedido FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El pedido % no existe', p_pedido;
    END IF;
    SELECT id_estado_pedido INTO v_estado FROM v_pedido_estado_actual WHERE id_pedido = p_pedido;
    IF v_estado IS DISTINCT FROM 'PAG' THEN
        RAISE EXCEPTION 'Solo se factura un pedido pagado (pedido % en estado %)', p_pedido, COALESCE(v_estado, '-');
    END IF;

    IF p_datos_facturacion IS NULL AND v_tipo.tco_electronico_sri THEN
        RAISE EXCEPTION 'La factura exige los datos del comprador (cédula, RUC o consumidor final)';
    END IF;
    IF p_datos_facturacion IS NOT NULL THEN
        SELECT * INTO v_df FROM datos_facturacion WHERE id_datos_facturacion = p_datos_facturacion;
        IF NOT FOUND OR NOT v_df.dfa_activo THEN
            RAISE EXCEPTION 'Los datos de facturación % no existen o están inactivos', p_datos_facturacion;
        END IF;
        IF v_df.id_cliente <> v_cliente AND v_df.id_tipo_identificacion <> '07' THEN
            RAISE EXCEPTION 'Los datos de facturación no pertenecen al cliente del pedido';
        END IF;
    END IF;
    IF p_secuencial IS NOT NULL AND v_tipo.tco_electronico_sri THEN
        RAISE EXCEPTION 'El número de una factura electrónica lo asigna el sistema';
    END IF;
    SELECT total INTO v_total FROM v_pedido_totales WHERE id_pedido = p_pedido;
    SELECT emp_max_consumidor_final INTO v_max_cf FROM empresa;
    IF v_tipo.tco_electronico_sri AND p_datos_facturacion IS NOT NULL
       AND (SELECT id_tipo_identificacion FROM datos_facturacion WHERE id_datos_facturacion = p_datos_facturacion) = '07'
       AND v_total > v_max_cf THEN
        RAISE EXCEPTION 'Las facturas de más de USD % deben identificar al comprador (SRI); total del pedido: %', v_max_cf, v_total;
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(p_lotes, '[]'::JSONB)) x
               WHERE NOT EXISTS (SELECT 1 FROM detalle_pedido d
                                 WHERE d.id_detalle_pedido = (x ->> 'id_detalle_pedido')::INTEGER
                                   AND d.id_pedido = p_pedido)) THEN
        RAISE EXCEPTION 'Se indicaron lotes para líneas que no son del pedido %', p_pedido;
    END IF;

    -- Secuencial por tipo y punto de emisión (bloqueo para que no se repita).
    -- La nota de venta puede traer el número impreso del talonario.
    PERFORM 1 FROM punto_emision WHERE id_punto_emision = p_punto_emision AND pem_activo FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Punto de emisión % inexistente o inactivo', p_punto_emision;
    END IF;
    IF p_secuencial IS NOT NULL THEN
        IF EXISTS (SELECT 1 FROM comprobante_venta WHERE id_tipo_comprobante = p_tipo_comprobante
                   AND id_punto_emision = p_punto_emision AND cve_secuencial = p_secuencial) THEN
            RAISE EXCEPTION 'La % número % ya fue registrada', LOWER(v_tipo.tco_nombre), p_secuencial;
        END IF;
        v_secuencial := p_secuencial;
    ELSE
        SELECT COALESCE(MAX(cve_secuencial), 0) + 1 INTO v_secuencial
        FROM comprobante_venta WHERE id_tipo_comprobante = p_tipo_comprobante AND id_punto_emision = p_punto_emision;
    END IF;

    INSERT INTO comprobante_venta (id_tipo_comprobante, id_pedido, id_datos_facturacion, id_punto_emision,
                                   cve_secuencial, id_usuario_emite, cve_clave_acceso, cve_estado)
    VALUES (p_tipo_comprobante, p_pedido, p_datos_facturacion, p_punto_emision, v_secuencial, p_usuario,
            CASE WHEN v_tipo.tco_electronico_sri
                 THEN fn_clave_acceso(CURRENT_DATE, p_tipo_comprobante, p_punto_emision, v_secuencial) END,
            CASE WHEN v_tipo.tco_electronico_sri THEN 'PENDIENTE' ELSE 'EMITIDA' END)
    RETURNING id_comprobante_venta INTO v_comprobante;

    -- Salida de inventario en unidad base
    INSERT INTO movimiento_inventario (id_tipo_movimiento, id_usuario, id_comprobante_venta)
    VALUES ('VEN', p_usuario, v_comprobante)
    RETURNING id_movimiento INTO v_movimiento;

    FOR r IN SELECT dv.id_detalle_pedido, dv.id_variante, dv.cantidad_base, v.var_sku,
                    p.prd_venta_por_pieza AS por_pieza, p.id_unidad_medida AS unidad,
                    (SELECT (x ->> 'id_lote')::INTEGER
                     FROM jsonb_array_elements(COALESCE(p_lotes, '[]'::JSONB)) x
                     WHERE (x ->> 'id_detalle_pedido')::INTEGER = dv.id_detalle_pedido
                     LIMIT 1) AS id_lote_elegido
             FROM v_detalle_pedido_valor dv
             JOIN variante v ON v.id_variante = dv.id_variante
             JOIN producto p ON p.id_producto = v.id_producto
             WHERE dv.id_pedido = p_pedido
             ORDER BY dv.id_variante, dv.id_detalle_pedido
    LOOP
        IF r.id_lote_elegido IS NOT NULL THEN
            IF NOT EXISTS (SELECT 1 FROM lote WHERE id_lote = r.id_lote_elegido AND id_variante = r.id_variante) THEN
                RAISE EXCEPTION 'El lote % no es de la variante %', r.id_lote_elegido, r.var_sku;
            END IF;
            INSERT INTO detalle_movimiento (id_movimiento, id_lote, dmo_cantidad, id_detalle_pedido)
            VALUES (v_movimiento, r.id_lote_elegido, r.cantidad_base, r.id_detalle_pedido);
        ELSIF r.por_pieza THEN
            PERFORM pg_advisory_xact_lock(1, r.id_variante);
            SELECT id_lote INTO v_lote
            FROM v_lote_saldo
            WHERE id_variante = r.id_variante AND saldo >= r.cantidad_base
            ORDER BY saldo, fecha_ingreso, id_lote
            LIMIT 1;
            IF v_lote IS NULL THEN
                RAISE EXCEPTION 'Ninguna pieza de % alcanza para % % (los retazos no se juntan)',
                    r.var_sku, r.cantidad_base, r.unidad;
            END IF;
            INSERT INTO detalle_movimiento (id_movimiento, id_lote, dmo_cantidad, id_detalle_pedido)
            VALUES (v_movimiento, v_lote, r.cantidad_base, r.id_detalle_pedido);
        ELSE
            PERFORM fn_consumir_lotes(v_movimiento, r.id_variante, r.cantidad_base, r.id_detalle_pedido);
        END IF;
    END LOOP;

    PERFORM fn_cambiar_estado_pedido(p_pedido, 'FAC', p_usuario, v_tipo.tco_nombre || ' emitida');
    PERFORM fn_log('INFO', 'FACTURACION',
                   CASE WHEN v_tipo.tco_electronico_sri THEN 'FACTURA_EMITIDA' ELSE 'NOTA_VENTA_EMITIDA' END,
                   v_tipo.tco_nombre || ' ' || v_comprobante || ' del pedido ' || p_pedido,
                   p_usuario, jsonb_build_object('id_comprobante_venta', v_comprobante, 'id_pedido', p_pedido));
    RETURN v_comprobante;
END $$;


-- C8b. Venta a crédito: el saldo no pagado del pedido queda como cuenta
--      por cobrar y la factura se emite en el mismo momento (la entrega
--      del bien es la que obliga a facturar, no el cobro).
CREATE FUNCTION fn_facturar_a_credito(p_pedido INTEGER, p_plazo_dias INTEGER, p_datos_facturacion INTEGER,
                                      p_punto_emision INTEGER, p_usuario INTEGER,
                                      p_lotes JSONB DEFAULT NULL,
                                      p_tipo_comprobante CHAR(2) DEFAULT '01',
                                      p_secuencial INTEGER DEFAULT NULL)
RETURNS INTEGER LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    v_saldo NUMERIC;
BEGIN
    PERFORM fn_exigir_permiso(p_usuario, 'CREDITO_OTORGAR');
    IF p_plazo_dias IS NULL OR p_plazo_dias <= 0 THEN
        RAISE EXCEPTION 'Indique el plazo del crédito en días';
    END IF;
    PERFORM 1 FROM pedido WHERE id_pedido = p_pedido FOR UPDATE;
    IF p_datos_facturacion IS NULL
       OR (SELECT id_tipo_identificacion FROM datos_facturacion WHERE id_datos_facturacion = p_datos_facturacion) = '07' THEN
        RAISE EXCEPTION 'Una venta a crédito debe emitirse con la identificación del cliente, no a consumidor final';
    END IF;
    SELECT t.total - pp.cubierto INTO v_saldo
    FROM v_pedido_totales t JOIN v_pedido_pagos pp ON pp.id_pedido = t.id_pedido
    WHERE t.id_pedido = p_pedido;
    IF v_saldo IS NULL OR v_saldo <= 0 THEN
        RAISE EXCEPTION 'El pedido % no tiene saldo por financiar', p_pedido;
    END IF;

    INSERT INTO cuenta_por_cobrar (id_pedido, cxc_tipo, cxc_monto, cxc_concepto, cxc_fecha_vencimiento, id_usuario_autoriza)
    VALUES (p_pedido, 'CREDITO', v_saldo, 'Saldo de la compra a crédito (' || p_plazo_dias || ' días)',
            CURRENT_DATE + p_plazo_dias, p_usuario);

    PERFORM fn_verificar_pago_completo(p_pedido, p_usuario);
    RETURN fn_facturar_pedido(p_pedido, p_datos_facturacion, p_punto_emision, p_usuario, p_lotes,
                              p_tipo_comprobante, p_secuencial);
END $$;

-- C8a. Nota de venta: atajo de fn_facturar_pedido con tipo 02. El número
--      del talonario es opcional (si no se indica, el siguiente).
CREATE FUNCTION fn_emitir_nota_venta(p_pedido INTEGER, p_punto_emision INTEGER, p_usuario INTEGER,
                                     p_secuencial INTEGER DEFAULT NULL, p_datos_facturacion INTEGER DEFAULT NULL,
                                     p_lotes JSONB DEFAULT NULL)
RETURNS INTEGER LANGUAGE plpgsql SET search_path = produccion, public AS $$
BEGIN
    RETURN fn_facturar_pedido(p_pedido, p_datos_facturacion, p_punto_emision, p_usuario, p_lotes, '02', p_secuencial);
END $$;


-- C8c. Avance de dinero sobre una compra ya facturada (pasaje, material
--      en otro local). No es una venta: no va en la factura; queda como
--      deuda del cliente, dentro de su límite de crédito.
--      p_motivo: motivo_avance (Pasaje, Compra en otro establecimiento...);
--      si no se indica, 'Otro'.
CREATE FUNCTION fn_registrar_avance(p_pedido INTEGER, p_monto NUMERIC, p_concepto VARCHAR,
                                    p_metodo_entrega INTEGER, p_plazo_dias INTEGER, p_usuario INTEGER,
                                    p_motivo INTEGER DEFAULT NULL)
RETURNS INTEGER LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    v_id INTEGER;
BEGIN
    PERFORM fn_exigir_permiso(p_usuario, 'CREDITO_OTORGAR');
    IF p_plazo_dias IS NULL OR p_plazo_dias <= 0 THEN
        RAISE EXCEPTION 'Indique el plazo para devolver el avance';
    END IF;
    INSERT INTO cuenta_por_cobrar (id_pedido, cxc_tipo, cxc_monto, cxc_concepto, cxc_fecha_vencimiento,
                                   id_metodo_entrega, id_motivo_avance, id_usuario_autoriza)
    VALUES (p_pedido, 'AVANCE', p_monto, p_concepto, CURRENT_DATE + p_plazo_dias, p_metodo_entrega,
            COALESCE(p_motivo, (SELECT id_motivo_avance FROM motivo_avance WHERE mav_nombre = 'Otro')), p_usuario)
    RETURNING id_cuenta_por_cobrar INTO v_id;
    RETURN v_id;
END $$;


-- C8d. Abonos del cliente: a una cuenta concreta, o repartido desde lo que
--      vence primero
CREATE FUNCTION fn_registrar_abono(p_cuenta INTEGER, p_monto NUMERIC, p_metodo INTEGER, p_usuario INTEGER,
                                   p_referencia VARCHAR DEFAULT NULL)
RETURNS INTEGER LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    v_id INTEGER;
BEGIN
    PERFORM fn_exigir_permiso(p_usuario, 'PAGO_REGISTRAR');
    INSERT INTO abono_cliente (id_cuenta_por_cobrar, id_metodo_pago, abo_monto, abo_referencia, id_usuario_registra)
    VALUES (p_cuenta, p_metodo, p_monto, p_referencia, p_usuario)
    RETURNING id_abono_cliente INTO v_id;
    RETURN v_id;
END $$;

CREATE FUNCTION fn_abonar_cliente(p_cliente INTEGER, p_monto NUMERIC, p_metodo INTEGER, p_usuario INTEGER,
                                  p_referencia VARCHAR DEFAULT NULL)
RETURNS INTEGER LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    v_deuda     NUMERIC;
    v_pendiente NUMERIC := p_monto;
    v_tomar     NUMERIC;
    v_cuentas   INTEGER := 0;
    c           RECORD;
BEGIN
    PERFORM fn_exigir_permiso(p_usuario, 'PAGO_REGISTRAR');
    IF p_monto IS NULL OR p_monto <= 0 THEN
        RAISE EXCEPTION 'El abono debe ser mayor que cero';
    END IF;
    PERFORM 1 FROM cliente WHERE id_cliente = p_cliente FOR UPDATE;
    SELECT deuda_total INTO v_deuda FROM v_estado_cuenta_cliente WHERE id_cliente = p_cliente;
    IF p_monto > COALESCE(v_deuda, 0) THEN
        RAISE EXCEPTION 'El abono (%) supera la deuda del cliente (%)', p_monto, COALESCE(v_deuda, 0);
    END IF;

    FOR c IN SELECT id_cuenta_por_cobrar, saldo
             FROM v_cuentas_por_cobrar
             WHERE id_cliente = p_cliente AND saldo > 0
             ORDER BY vencimiento, fecha, id_cuenta_por_cobrar
    LOOP
        EXIT WHEN v_pendiente <= 0;
        v_tomar := LEAST(c.saldo, v_pendiente);
        INSERT INTO abono_cliente (id_cuenta_por_cobrar, id_metodo_pago, abo_monto, abo_referencia, id_usuario_registra)
        VALUES (c.id_cuenta_por_cobrar, p_metodo, v_tomar, p_referencia, p_usuario);
        v_pendiente := v_pendiente - v_tomar;
        v_cuentas := v_cuentas + 1;
    END LOOP;
    RETURN v_cuentas;
END $$;


-- C9. Nota de crédito por devolución (política de devoluciones)
--     p_lineas: [{"id_detalle_pedido": 7, "cantidad": 1, "reingresa": true}, ...]
--     · Valida el plazo (empresa.emp_dias_devolucion) y que no se devuelva
--       más de lo facturado (sumando notas anteriores).
--     · Lo que reingresa vuelve a los MISMOS lotes de los que salió
--       (conserva costo y antigüedad); lo dañado no reingresa.
CREATE FUNCTION fn_emitir_nota_credito(p_comprobante INTEGER, p_motivo INTEGER, p_usuario INTEGER,
                                       p_punto_emision INTEGER, p_lineas JSONB,
                                       p_observacion VARCHAR DEFAULT NULL)
RETURNS INTEGER LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    v_fac        RECORD;
    v_dias       SMALLINT;
    v_secuencial INTEGER;
    v_nc         INTEGER;
    v_dnc        INTEGER;
    v_movimiento INTEGER;
    v_facturado  NUMERIC;
    v_factor     NUMERIC;
    v_acreditado NUMERIC;
    v_pendiente  NUMERIC;
    v_tomar      NUMERIC;
    v_disponible NUMERIC;
    r            RECORD;
    l            RECORD;
    c            RECORD;
BEGIN
    PERFORM fn_exigir_permiso(p_usuario, 'NC_EMITIR');

    SELECT * INTO v_fac FROM comprobante_venta WHERE id_comprobante_venta = p_comprobante FOR UPDATE;
    IF NOT FOUND OR v_fac.cve_estado = 'ANULADA' THEN
        RAISE EXCEPTION 'El comprobante % no existe o está anulado', p_comprobante;
    END IF;
    IF v_fac.id_tipo_comprobante = '01' AND (SELECT id_tipo_identificacion FROM datos_facturacion
        WHERE id_datos_facturacion = v_fac.id_datos_facturacion) = '07' THEN
        RAISE EXCEPTION 'Una factura a consumidor final no admite nota de crédito (regla del SRI vigente desde 2026)';
    END IF;
    SELECT emp_dias_devolucion INTO v_dias FROM empresa;
    IF v_fac.cve_fechahora + MAKE_INTERVAL(days => v_dias) < CURRENT_TIMESTAMP THEN
        RAISE EXCEPTION 'El comprobante % superó el plazo de devolución de % días', p_comprobante, v_dias;
    END IF;
    IF p_lineas IS NULL OR jsonb_array_length(p_lineas) = 0 THEN
        RAISE EXCEPTION 'La nota de crédito no tiene líneas';
    END IF;

    PERFORM 1 FROM punto_emision WHERE id_punto_emision = p_punto_emision AND pem_activo FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Punto de emisión % inexistente o inactivo', p_punto_emision;
    END IF;
    SELECT COALESCE(MAX(ncr_secuencial), 0) + 1 INTO v_secuencial
    FROM nota_credito WHERE id_punto_emision = p_punto_emision;

    -- Sobre una factura la nota es electrónica (va al SRI); sobre una nota
    -- de venta se registra (estado EMITIDA, sin clave de acceso)
    INSERT INTO nota_credito (id_comprobante_venta, id_punto_emision, ncr_secuencial, id_motivo_devolucion,
                              id_usuario_autoriza, ncr_observacion, ncr_clave_acceso, ncr_estado)
    VALUES (p_comprobante, p_punto_emision, v_secuencial, p_motivo, p_usuario, p_observacion,
            CASE WHEN v_fac.id_tipo_comprobante = '01' THEN fn_clave_acceso(CURRENT_DATE, '04', p_punto_emision, v_secuencial) END,
            CASE WHEN v_fac.id_tipo_comprobante = '01' THEN 'PENDIENTE' ELSE 'EMITIDA' END)
    RETURNING id_nota_credito INTO v_nc;

    FOR r IN SELECT x.id_detalle_pedido, x.cantidad, COALESCE(x.reingresa, TRUE) AS reingresa
             FROM jsonb_to_recordset(p_lineas) AS x(id_detalle_pedido INTEGER, cantidad NUMERIC, reingresa BOOLEAN)
    LOOP
        SELECT d.dpe_cantidad, pr.pre_factor INTO v_facturado, v_factor
        FROM detalle_pedido d
        JOIN presentacion pr ON pr.id_presentacion = d.id_presentacion
        WHERE d.id_detalle_pedido = r.id_detalle_pedido AND d.id_pedido = v_fac.id_pedido;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'La línea % no pertenece al comprobante %', r.id_detalle_pedido, p_comprobante;
        END IF;

        SELECT COALESCE(SUM(dn.dnc_cantidad), 0) INTO v_acreditado
        FROM detalle_nota_credito dn
        JOIN nota_credito n ON n.id_nota_credito = dn.id_nota_credito
        WHERE dn.id_detalle_pedido = r.id_detalle_pedido AND n.ncr_estado <> 'ANULADA';
        IF v_acreditado + r.cantidad > v_facturado THEN
            RAISE EXCEPTION 'Se intenta devolver % de la línea %, pero solo quedan % por devolver',
                r.cantidad, r.id_detalle_pedido, v_facturado - v_acreditado;
        END IF;

        INSERT INTO detalle_nota_credito (id_nota_credito, id_detalle_pedido, dnc_cantidad, dnc_reingresa_stock)
        VALUES (v_nc, r.id_detalle_pedido, r.cantidad, r.reingresa)
        RETURNING id_detalle_nota_credito INTO v_dnc;

        IF r.reingresa THEN
            IF v_movimiento IS NULL THEN
                INSERT INTO movimiento_inventario (id_tipo_movimiento, id_usuario, id_nota_credito)
                VALUES ('DCL', p_usuario, v_nc)
                RETURNING id_movimiento INTO v_movimiento;
            END IF;

            -- Devuelve a los lotes de origen, empezando por el último consumido
            v_pendiente := r.cantidad * v_factor;
            FOR l IN
                SELECT dm.id_lote,
                       SUM(dm.dmo_cantidad) - COALESCE((
                           SELECT SUM(dd.dmo_cantidad)
                           FROM detalle_movimiento dd
                           JOIN detalle_nota_credito dn2 ON dn2.id_detalle_nota_credito = dd.id_detalle_nota_credito
                           WHERE dn2.id_detalle_pedido = r.id_detalle_pedido AND dd.id_lote = dm.id_lote), 0) AS devolvible,
                       MAX(dm.id_detalle_movimiento) AS orden
                FROM detalle_movimiento dm
                WHERE dm.id_detalle_pedido = r.id_detalle_pedido
                GROUP BY dm.id_lote
                ORDER BY orden DESC
            LOOP
                EXIT WHEN v_pendiente <= 0;
                CONTINUE WHEN l.devolvible <= 0;
                v_tomar := LEAST(l.devolvible, v_pendiente);
                INSERT INTO detalle_movimiento (id_movimiento, id_lote, dmo_cantidad, id_detalle_nota_credito)
                VALUES (v_movimiento, l.id_lote, v_tomar, v_dnc);
                v_pendiente := v_pendiente - v_tomar;
            END LOOP;
            IF v_pendiente > 0 THEN
                RAISE EXCEPTION 'No se encontró el lote de origen de la línea %', r.id_detalle_pedido;
            END IF;
        END IF;
    END LOOP;

    -- Si el cliente debe algo de esa misma compra (crédito o avance), la nota
    -- de crédito se compensa primero con esa deuda; lo que sobre se reembolsa
    SELECT total INTO v_disponible FROM v_nota_credito WHERE id_nota_credito = v_nc;
    FOR c IN SELECT id_cuenta_por_cobrar, saldo
             FROM v_cuentas_por_cobrar
             WHERE id_pedido = v_fac.id_pedido AND saldo > 0
             ORDER BY CASE tipo WHEN 'CREDITO' THEN 0 ELSE 1 END, fecha, id_cuenta_por_cobrar
    LOOP
        EXIT WHEN v_disponible <= 0;
        v_tomar := LEAST(c.saldo, v_disponible);
        INSERT INTO abono_cliente (id_cuenta_por_cobrar, id_nota_credito, abo_monto, abo_referencia, id_usuario_registra)
        VALUES (c.id_cuenta_por_cobrar, v_nc, v_tomar, 'Compensación con nota de crédito', p_usuario);
        v_disponible := v_disponible - v_tomar;
    END LOOP;

    PERFORM fn_log('INFO', 'FACTURACION', 'NC_EMITIDA', 'Nota de crédito ' || v_nc || ' sobre la factura ' || p_comprobante,
                   p_usuario, jsonb_build_object('id_nota_credito', v_nc, 'id_comprobante_venta', p_comprobante));
    RETURN v_nc;
END $$;


-- C9b. Respuesta del SRI (la registra el servicio que transmite)
CREATE FUNCTION fn_registrar_respuesta_sri(p_tipo VARCHAR, p_id INTEGER, p_estado VARCHAR, p_usuario INTEGER,
                                           p_fecha_autorizacion TIMESTAMP DEFAULT CURRENT_TIMESTAMP)
RETURNS VOID LANGUAGE plpgsql SET search_path = produccion, public AS $$
BEGIN
    PERFORM fn_exigir_permiso(p_usuario, 'SRI_GESTIONAR');
    IF p_estado NOT IN ('AUTORIZADA', 'RECHAZADA') THEN
        RAISE EXCEPTION 'Respuesta del SRI no válida: %', p_estado;
    END IF;
    IF p_tipo = 'FACTURA' THEN
        UPDATE comprobante_venta
        SET cve_estado = p_estado,
            cve_fecha_autorizacion = CASE WHEN p_estado = 'AUTORIZADA' THEN p_fecha_autorizacion END
        WHERE id_comprobante_venta = p_id AND cve_estado IN ('PENDIENTE', 'RECHAZADA');
    ELSIF p_tipo = 'NOTA_CREDITO' THEN
        UPDATE nota_credito
        SET ncr_estado = p_estado,
            ncr_fecha_autorizacion = CASE WHEN p_estado = 'AUTORIZADA' THEN p_fecha_autorizacion END
        WHERE id_nota_credito = p_id AND ncr_estado IN ('PENDIENTE', 'RECHAZADA');
    ELSE
        RAISE EXCEPTION 'Tipo de comprobante no válido: %', p_tipo;
    END IF;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El comprobante % % no existe o ya fue procesado', p_tipo, p_id;
    END IF;
    PERFORM fn_log(CASE WHEN p_estado = 'RECHAZADA' THEN 'ERROR' ELSE 'INFO' END, 'SRI', 'SRI_' || p_estado,
                   'Comprobante ' || p_tipo || ' ' || p_id || ': ' || p_estado || ' por el SRI', p_usuario,
                   jsonb_build_object('tipo', p_tipo, 'id', p_id));
END $$;


-- C10. Compras: cambio de estado de la OC con permiso
CREATE FUNCTION fn_cambiar_estado_oc(p_orden INTEGER, p_estado VARCHAR, p_usuario INTEGER)
RETURNS VOID LANGUAGE plpgsql SET search_path = produccion, public AS $$
BEGIN
    PERFORM fn_exigir_permiso(p_usuario, 'COMPRA_GESTIONAR');
    UPDATE orden_compra SET oc_estado = p_estado WHERE id_orden_compra = p_orden;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La OC % no existe', p_orden;
    END IF;
END $$;


-- C11. Recepción de mercadería (total o parcial). Cada línea crea un lote
--      con el costo real (si no se indica, el pactado en la OC).
--      p_lineas: [{"id_detalle_orden_compra": 1, "cantidad": 90,
--                  "costo_unitario": 4.10, "fecha_vencimiento": "2027-01-15",
--                  "codigo_lote": "L-889"}, ...]
CREATE FUNCTION fn_recepcionar_compra(p_orden INTEGER, p_usuario INTEGER, p_lineas JSONB,
                                      p_comprobante_compra INTEGER DEFAULT NULL,
                                      p_fechahora TIMESTAMP DEFAULT CURRENT_TIMESTAMP)
RETURNS INTEGER LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    v_movimiento INTEGER;
    v_lote       INTEGER;
    r            RECORD;
    d            RECORD;
BEGIN
    PERFORM fn_exigir_permiso(p_usuario, 'INV_RECEPCIONAR');
    PERFORM 1 FROM orden_compra WHERE id_orden_compra = p_orden FOR UPDATE;

    INSERT INTO movimiento_inventario (id_tipo_movimiento, mov_fechahora, id_usuario, id_orden_compra, id_comprobante_compra)
    VALUES ('COM', p_fechahora, p_usuario, p_orden, p_comprobante_compra)
    RETURNING id_movimiento INTO v_movimiento;

    FOR r IN SELECT *
             FROM jsonb_to_recordset(p_lineas) AS x(id_detalle_orden_compra INTEGER, cantidad NUMERIC,
                                                    costo_unitario NUMERIC, fecha_vencimiento DATE,
                                                    codigo_lote VARCHAR)
    LOOP
        SELECT * INTO d FROM v_orden_compra_detalle
        WHERE id_detalle_orden_compra = r.id_detalle_orden_compra AND id_orden_compra = p_orden;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'La línea % no pertenece a la OC %', r.id_detalle_orden_compra, p_orden;
        END IF;
        IF r.cantidad > d.cantidad_pendiente THEN
            RAISE EXCEPTION 'Se intenta recibir % de %, pero solo quedan % pendientes',
                r.cantidad, d.var_sku, d.cantidad_pendiente;
        END IF;

        INSERT INTO lote (id_variante, lot_costo_unitario, lot_fecha_vencimiento, lot_codigo_proveedor)
        VALUES (d.id_variante, COALESCE(r.costo_unitario, d.costo_pactado), r.fecha_vencimiento, r.codigo_lote)
        RETURNING id_lote INTO v_lote;

        INSERT INTO detalle_movimiento (id_movimiento, id_lote, dmo_cantidad, id_detalle_orden_compra)
        VALUES (v_movimiento, v_lote, r.cantidad, r.id_detalle_orden_compra);
    END LOOP;

    RETURN v_movimiento;
END $$;


-- C12. Devolución a proveedor de mercadería de un lote recibido
CREATE FUNCTION fn_devolver_a_proveedor(p_lote INTEGER, p_cantidad NUMERIC, p_motivo VARCHAR, p_usuario INTEGER)
RETURNS INTEGER LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    v_orden      INTEGER;
    v_movimiento INTEGER;
BEGIN
    PERFORM fn_exigir_permiso(p_usuario, 'COMPRA_GESTIONAR');
    SELECT m.id_orden_compra INTO v_orden
    FROM detalle_movimiento dm
    JOIN movimiento_inventario m ON m.id_movimiento = dm.id_movimiento
    WHERE dm.id_lote = p_lote AND m.id_tipo_movimiento = 'COM';
    IF v_orden IS NULL THEN
        RAISE EXCEPTION 'El lote % no proviene de una compra', p_lote;
    END IF;

    INSERT INTO movimiento_inventario (id_tipo_movimiento, id_usuario, mov_motivo, id_orden_compra)
    VALUES ('DPR', p_usuario, p_motivo, v_orden)
    RETURNING id_movimiento INTO v_movimiento;
    INSERT INTO detalle_movimiento (id_movimiento, id_lote, dmo_cantidad)
    VALUES (v_movimiento, p_lote, p_cantidad);
    RETURN v_movimiento;
END $$;


-- C13. Inventario inicial, ajustes por conteo físico y mermas
--      INI / AJP crean un lote (costo obligatorio en INI; en AJP, si no se
--      indica, se usa el del último lote). AJN / MER consumen por FEFO/PEPS
--      o de un lote específico (p_lote).
CREATE FUNCTION fn_registrar_ajuste(p_variante INTEGER, p_tipo CHAR(3), p_cantidad NUMERIC,
                                    p_motivo VARCHAR, p_usuario INTEGER,
                                    p_costo_unitario NUMERIC DEFAULT NULL,
                                    p_fecha_vencimiento DATE DEFAULT NULL,
                                    p_lote INTEGER DEFAULT NULL,
                                    p_fechahora TIMESTAMP DEFAULT CURRENT_TIMESTAMP)
RETURNS INTEGER LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    v_movimiento INTEGER;
    v_lote       INTEGER;
    v_costo      NUMERIC := p_costo_unitario;
BEGIN
    PERFORM fn_exigir_permiso(p_usuario, 'INV_AJUSTAR');
    IF p_tipo NOT IN ('INI', 'AJP', 'AJN', 'MER') THEN
        RAISE EXCEPTION 'Tipo de ajuste no válido: %', p_tipo;
    END IF;
    IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
        RAISE EXCEPTION 'La cantidad del ajuste debe ser mayor que cero';
    END IF;

    INSERT INTO movimiento_inventario (id_tipo_movimiento, mov_fechahora, id_usuario, mov_motivo)
    VALUES (p_tipo, p_fechahora, p_usuario, p_motivo)
    RETURNING id_movimiento INTO v_movimiento;

    IF p_tipo IN ('INI', 'AJP') THEN
        IF v_costo IS NULL AND p_tipo = 'AJP' THEN
            SELECT lot_costo_unitario INTO v_costo FROM lote
            WHERE id_variante = p_variante ORDER BY id_lote DESC LIMIT 1;
        END IF;
        IF v_costo IS NULL THEN
            RAISE EXCEPTION 'Indique el costo unitario del ingreso';
        END IF;
        INSERT INTO lote (id_variante, lot_costo_unitario, lot_fecha_vencimiento)
        VALUES (p_variante, v_costo, p_fecha_vencimiento)
        RETURNING id_lote INTO v_lote;
        INSERT INTO detalle_movimiento (id_movimiento, id_lote, dmo_cantidad)
        VALUES (v_movimiento, v_lote, p_cantidad);
    ELSIF p_lote IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM lote WHERE id_lote = p_lote AND id_variante = p_variante) THEN
            RAISE EXCEPTION 'El lote % no pertenece a la variante indicada', p_lote;
        END IF;
        INSERT INTO detalle_movimiento (id_movimiento, id_lote, dmo_cantidad)
        VALUES (v_movimiento, p_lote, p_cantidad);
    ELSE
        PERFORM fn_consumir_lotes(v_movimiento, p_variante, p_cantidad);
    END IF;

    PERFORM fn_log(CASE WHEN p_tipo IN ('AJN', 'MER') THEN 'AVISO' ELSE 'INFO' END, 'INVENTARIO', 'AJUSTE_INVENTARIO',
                   p_tipo || ' de ' || p_cantidad || ' (variante ' || p_variante || '): ' || COALESCE(p_motivo, ''),
                   p_usuario, jsonb_build_object('id_movimiento', v_movimiento));
    RETURN v_movimiento;
END $$;


-- C13b. Fraccionar una pieza (banda) en paquetes, p. ej. dos medias bandas.
--       p_piezas: [11.20, 11.20] en unidad base. Sale lo cortado de la pieza
--       (FRS) y entra cada paquete como lote nuevo (FRE) con la pieza de
--       origen: conserva costo, vencimiento y antigüedad. Lo que no se corta
--       queda en la pieza original.
CREATE FUNCTION fn_fraccionar_lote(p_lote INTEGER, p_piezas JSONB, p_usuario INTEGER,
                                   p_motivo VARCHAR DEFAULT NULL)
RETURNS INTEGER[] LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    v_l      RECORD;
    v_total  NUMERIC;
    v_motivo VARCHAR(200);
    v_frs    INTEGER;
    v_fre    INTEGER;
    v_nuevo  INTEGER;
    v_lotes  INTEGER[] := '{}';
    v_n      INTEGER := 0;
    v_pieza  NUMERIC;
BEGIN
    PERFORM fn_exigir_permiso(p_usuario, 'INV_FRACCIONAR');
    SELECT * INTO v_l FROM lote WHERE id_lote = p_lote;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El lote % no existe', p_lote;
    END IF;
    IF p_piezas IS NULL OR jsonb_typeof(p_piezas) <> 'array' OR jsonb_array_length(p_piezas) = 0 THEN
        RAISE EXCEPTION 'Indique las medidas de los paquetes';
    END IF;
    IF NOT (SELECT BOOL_AND(x::NUMERIC > 0) FROM jsonb_array_elements_text(p_piezas) x) THEN
        RAISE EXCEPTION 'Cada paquete debe medir más de cero';
    END IF;
    SELECT SUM(x::NUMERIC) INTO v_total FROM jsonb_array_elements_text(p_piezas) x;
    v_motivo := COALESCE(p_motivo, 'Fraccionamiento de ' || COALESCE(v_l.lot_codigo_proveedor, 'lote ' || p_lote));

    INSERT INTO movimiento_inventario (id_tipo_movimiento, id_usuario, mov_motivo)
    VALUES ('FRS', p_usuario, v_motivo) RETURNING id_movimiento INTO v_frs;
    INSERT INTO detalle_movimiento (id_movimiento, id_lote, dmo_cantidad)
    VALUES (v_frs, p_lote, v_total);

    INSERT INTO movimiento_inventario (id_tipo_movimiento, id_usuario, mov_motivo)
    VALUES ('FRE', p_usuario, v_motivo) RETURNING id_movimiento INTO v_fre;
    FOR v_pieza IN SELECT x::NUMERIC FROM jsonb_array_elements_text(p_piezas) x LOOP
        v_n := v_n + 1;
        INSERT INTO lote (id_variante, lot_costo_unitario, lot_fecha_vencimiento, lot_codigo_proveedor, id_lote_origen)
        VALUES (v_l.id_variante, v_l.lot_costo_unitario, v_l.lot_fecha_vencimiento,
                LEFT(COALESCE(v_l.lot_codigo_proveedor, 'L' || p_lote), 26) || '-' || v_n, p_lote)
        RETURNING id_lote INTO v_nuevo;
        INSERT INTO detalle_movimiento (id_movimiento, id_lote, dmo_cantidad)
        VALUES (v_fre, v_nuevo, v_pieza);
        v_lotes := v_lotes || v_nuevo;
    END LOOP;
    RETURN v_lotes;
END $$;


-- C13c. Buscar cuánto debe un cliente por nombre, cédula/RUC, teléfono o correo
CREATE FUNCTION fn_buscar_deuda_cliente(p_texto TEXT)
RETURNS SETOF v_deuda_cliente LANGUAGE sql STABLE SET search_path = produccion, public AS $$
    SELECT d.*
    FROM v_deuda_cliente d
    JOIN cliente c ON c.id_cliente = d.id_cliente
    WHERE d.cliente ILIKE '%' || p_texto || '%'
       OR d.identificaciones ILIKE '%' || p_texto || '%'
       OR d.telefonos ILIKE '%' || p_texto || '%'
       OR c.cli_correo ILIKE '%' || p_texto || '%'
    ORDER BY d.deuda_total DESC, d.cliente
$$;

-- C13d. Proveedores: asociar la factura que llegó después de la mercadería,
--       y registrar la nota de crédito del proveedor (p. ej. por devolución)
CREATE FUNCTION fn_asociar_comprobante_compra(p_movimiento INTEGER, p_comprobante_compra INTEGER, p_usuario INTEGER)
RETURNS VOID LANGUAGE plpgsql SET search_path = produccion, public AS $$
BEGIN
    PERFORM fn_exigir_permiso(p_usuario, 'COMPRA_GESTIONAR');
    UPDATE movimiento_inventario SET id_comprobante_compra = p_comprobante_compra WHERE id_movimiento = p_movimiento;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La recepción % no existe', p_movimiento;
    END IF;
END $$;

CREATE FUNCTION fn_registrar_nc_proveedor(p_comprobante_compra INTEGER, p_numero VARCHAR, p_fecha DATE,
                                          p_subtotal_0 NUMERIC, p_subtotal_gravado NUMERIC, p_iva NUMERIC,
                                          p_motivo VARCHAR, p_usuario INTEGER, p_clave_acceso CHAR(49) DEFAULT NULL)
RETURNS INTEGER LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    v_id INTEGER;
BEGIN
    PERFORM fn_exigir_permiso(p_usuario, 'COMPRA_GESTIONAR');
    INSERT INTO nota_credito_proveedor (id_comprobante_compra, ncp_numero, ncp_clave_acceso, ncp_fecha_emision,
                                        ncp_subtotal_0, ncp_subtotal_gravado, ncp_iva, ncp_motivo, id_usuario_registra)
    VALUES (p_comprobante_compra, p_numero, p_clave_acceso, p_fecha, COALESCE(p_subtotal_0, 0),
            COALESCE(p_subtotal_gravado, 0), COALESCE(p_iva, 0), p_motivo, p_usuario)
    RETURNING id_nota_credito_proveedor INTO v_id;
    RETURN v_id;
END $$;


-- C16. Registrar el comprobante de una compra: factura (con sus datos del
--      SRI e IVA), nota de venta o sin comprobante (recibo). Las dos
--      últimas van sin IVA (su valor completo en p_subtotal_0).
CREATE FUNCTION fn_registrar_comprobante_compra(p_proveedor INTEGER, p_tipo CHAR(2), p_numero VARCHAR,
                                                p_fecha_emision DATE, p_fecha_vencimiento DATE,
                                                p_subtotal_0 NUMERIC, p_subtotal_gravado NUMERIC, p_iva NUMERIC,
                                                p_usuario INTEGER, p_clave_acceso VARCHAR DEFAULT NULL)
RETURNS INTEGER LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    v_id INTEGER;
BEGIN
    PERFORM fn_exigir_permiso(p_usuario, 'COMPRA_GESTIONAR');
    INSERT INTO comprobante_compra (id_proveedor, id_tipo_comprobante, cco_numero, cco_clave_acceso, cco_fecha_emision,
                                    cco_fecha_vencimiento, cco_subtotal_0, cco_subtotal_gravado, cco_iva, id_usuario_registra)
    VALUES (p_proveedor, p_tipo, TRIM(p_numero), p_clave_acceso, p_fecha_emision, p_fecha_vencimiento,
            COALESCE(p_subtotal_0, 0), COALESCE(p_subtotal_gravado, 0), COALESCE(p_iva, 0), p_usuario)
    RETURNING id_comprobante_compra INTO v_id;
    RETURN v_id;
END $$;


-- C15. Ofertas: el descuento preestablecido de un producto. Registrar una
--      oferta (inmediata o programada) y cambiar su estado (pausar,
--      reactivar o ponerle fin). El porcentaje no se edita una vez usada.
CREATE FUNCTION fn_registrar_oferta(p_producto INTEGER, p_porcentaje NUMERIC, p_usuario INTEGER,
                                    p_desde TIMESTAMP DEFAULT CURRENT_TIMESTAMP, p_hasta TIMESTAMP DEFAULT NULL,
                                    p_descripcion VARCHAR DEFAULT NULL)
RETURNS INTEGER LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    v_id INTEGER;
BEGIN
    PERFORM fn_exigir_permiso(p_usuario, 'PRECIO_GESTIONAR');
    INSERT INTO oferta (id_producto, ofe_porcentaje, ofe_descripcion, ofe_desde, ofe_hasta, id_usuario_registra)
    VALUES (p_producto, p_porcentaje, p_descripcion, p_desde, p_hasta, p_usuario)
    RETURNING id_oferta INTO v_id;
    RETURN v_id;
END $$;

CREATE FUNCTION fn_cambiar_estado_oferta(p_oferta INTEGER, p_activa BOOLEAN, p_usuario INTEGER,
                                         p_hasta TIMESTAMP DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SET search_path = produccion, public AS $$
BEGIN
    PERFORM fn_exigir_permiso(p_usuario, 'PRECIO_GESTIONAR');
    UPDATE oferta
    SET ofe_activa = p_activa,
        ofe_hasta  = COALESCE(p_hasta, ofe_hasta)
    WHERE id_oferta = p_oferta;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La oferta % no existe', p_oferta;
    END IF;
END $$;


-- C14. Cambio de precio (inmediato o programado)
CREATE FUNCTION fn_registrar_precio(p_presentacion INTEGER, p_precio NUMERIC, p_usuario INTEGER,
                                    p_vigente_desde TIMESTAMP DEFAULT CURRENT_TIMESTAMP)
RETURNS INTEGER LANGUAGE plpgsql SET search_path = produccion, public AS $$
DECLARE
    v_id INTEGER;
BEGIN
    PERFORM fn_exigir_permiso(p_usuario, 'PRECIO_GESTIONAR');
    INSERT INTO historial_precio (id_presentacion, hpr_precio, hpr_vigente_desde, id_usuario)
    VALUES (p_presentacion, p_precio, p_vigente_desde, p_usuario)
    RETURNING id_historial_precio INTO v_id;
    RETURN v_id;
END $$;



-- =====================================================================
-- D. NODO E-COMMERCE (esquema ecommerce)
--    Lo que la tienda en línea escribe por su cuenta (cuentas web,
--    carritos y su bitácora) y su interfaz con producción:
--    · lee catálogo, pedidos y clientes por vistas (al separar los
--      nodos: vistas materializadas o réplicas de solo lectura);
--    · le pide a producción crear clientes y pedidos llamando a sus
--      funciones (al separar los nodos: por enlace de base de datos).
--    Producción nunca lee ni escribe este esquema. Todo lo que viene de
--    producción se escribe con el prefijo produccion. para que se vea.
-- =====================================================================
SET search_path = ecommerce, public;

-- D1. Interfaz de lectura hacia producción

-- Catálogo publicado con precio, oferta y disponibilidad
CREATE VIEW v_catalogo_web AS
SELECT * FROM produccion.v_catalogo;

-- Categorías principales (las que no son subcategoría) para la portada y los filtros
CREATE VIEW v_categoria_web AS
SELECT * FROM produccion.v_categoria_principal;

-- Pedidos web con su estado, total y factura ("mis pedidos")
CREATE VIEW v_pedido_web AS
SELECT p.id_pedido,
       p.id_cliente,
       cw.id_cuenta_web,
       c.id_carrito,
       p.ped_fechahora            AS fecha,
       e.id_estado_pedido         AS estado,
       e.estado                   AS estado_nombre,
       t.total,
       f.numero                   AS comprobante_venta
FROM produccion.pedido p
JOIN produccion.v_pedido_estado_actual e ON e.id_pedido = p.id_pedido
JOIN produccion.v_pedido_totales       t ON t.id_pedido = p.id_pedido
LEFT JOIN produccion.v_comprobante_venta         f ON f.id_pedido = p.id_pedido AND f.estado_sri <> 'ANULADA'
LEFT JOIN carrito                      c ON c.id_pedido = p.id_pedido
LEFT JOIN cuenta_web                  cw ON cw.id_cliente = p.id_cliente
WHERE p.id_canal_venta = 'WEB';

-- Cuentas web con la actividad de compra del cliente (en todos los canales)
CREATE VIEW v_cuenta_web AS
SELECT cw.id_cuenta_web,
       cw.cwe_correo              AS correo,
       cw.cwe_activa              AS activa,
       cw.cwe_creada              AS creada,
       cw.cwe_ultimo_acceso       AS ultimo_acceso,
       cw.id_cliente,
       cl.cli_nombres || COALESCE(' ' || cl.cli_apellidos, '') AS cliente,
       COALESCE(f.compras, 0)     AS compras,
       f.ultima_compra,
       COALESCE(f.segmento, 'SIN COMPRAS') AS segmento
FROM cuenta_web cw
JOIN produccion.cliente                   cl ON cl.id_cliente = cw.id_cliente
LEFT JOIN produccion.v_frecuencia_cliente f  ON f.id_cliente  = cw.id_cliente;

-- Carritos abandonados: con productos, sin pedido y sin actividad hace más de un día
CREATE VIEW v_carrito_abandonado AS
SELECT c.id_carrito,
       c.car_token,
       c.id_cliente,
       cw.cwe_correo              AS correo,
       c.car_actualizado          AS ultima_actividad,
       COUNT(*)                   AS productos,
       SUM(i.ica_cantidad * cat.precio_final_con_iva) AS valor_estimado
FROM carrito c
JOIN item_carrito i         ON i.id_carrito = c.id_carrito
LEFT JOIN cuenta_web cw     ON cw.id_cliente = c.id_cliente
LEFT JOIN v_catalogo_web cat ON cat.id_presentacion = i.id_presentacion
WHERE c.id_pedido IS NULL
  AND c.car_actualizado < CURRENT_TIMESTAMP - INTERVAL '1 day'
GROUP BY c.id_carrito, c.car_token, c.id_cliente, cw.cwe_correo, c.car_actualizado;


-- D2. Disparadores del nodo (cada nodo lleva los suyos)
CREATE FUNCTION tg_inmutable() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = ecommerce, public AS $$
BEGIN
    RAISE EXCEPTION 'Los registros de % no se modifican ni se eliminan. %',
        TG_TABLE_NAME, COALESCE(TG_ARGV[0], '');
END $$;

CREATE TRIGGER tr_log_evento_web_inmutable BEFORE UPDATE OR DELETE ON log_evento_web
    FOR EACH ROW EXECUTE FUNCTION tg_inmutable('La bitácora solo se inserta.');

-- Última actividad del carrito (para detectar abandonos). Un carrito ya
-- convertido en pedido no se toca: el pedido vive en producción.
CREATE FUNCTION tg_carrito_actividad() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = ecommerce, public AS $$
DECLARE
    v_carrito INTEGER := CASE WHEN TG_OP = 'DELETE' THEN OLD.id_carrito ELSE NEW.id_carrito END;
    v_pedido  INTEGER;
BEGIN
    SELECT id_pedido INTO v_pedido FROM carrito WHERE id_carrito = v_carrito;
    IF v_pedido IS NOT NULL THEN
        RAISE EXCEPTION 'El carrito % ya se convirtió en el pedido % y no se modifica', v_carrito, v_pedido;
    END IF;
    UPDATE carrito SET car_actualizado = CURRENT_TIMESTAMP WHERE id_carrito = v_carrito;
    RETURN NULL;
END $$;

CREATE TRIGGER tr_carrito_actividad AFTER INSERT OR UPDATE OR DELETE ON item_carrito
    FOR EACH ROW EXECUTE FUNCTION tg_carrito_actividad();

-- El pedido de un carrito se fija una sola vez
CREATE FUNCTION tg_carrito_pedido() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = ecommerce, public AS $$
BEGIN
    IF OLD.id_pedido IS NOT NULL AND NEW.id_pedido IS DISTINCT FROM OLD.id_pedido THEN
        RAISE EXCEPTION 'El carrito % ya se convirtió en el pedido %', OLD.id_carrito, OLD.id_pedido;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER tr_carrito_pedido BEFORE UPDATE OF id_pedido ON carrito
    FOR EACH ROW EXECUTE FUNCTION tg_carrito_pedido();


-- D3. Funciones del nodo

-- Bitácora del e-commerce
CREATE FUNCTION fn_log_web(p_nivel VARCHAR, p_evento VARCHAR, p_mensaje VARCHAR, p_cuenta INTEGER DEFAULT NULL,
                           p_sesion VARCHAR DEFAULT NULL, p_ip VARCHAR DEFAULT NULL, p_agente VARCHAR DEFAULT NULL,
                           p_detalle JSONB DEFAULT NULL)
RETURNS BIGINT LANGUAGE plpgsql SET search_path = ecommerce, public AS $$
DECLARE
    v_id BIGINT;
BEGIN
    INSERT INTO log_evento_web (lew_nivel, lew_evento, lew_mensaje, id_cuenta_web, lew_sesion, lew_ip, lew_agente, lew_detalle)
    VALUES (p_nivel, p_evento, LEFT(p_mensaje, 500), p_cuenta, p_sesion, p_ip, LEFT(p_agente, 250), p_detalle::TEXT)
    RETURNING id_log_evento_web INTO v_id;
    RETURN v_id;
END $$;

-- Registro en la tienda en línea: el cliente se crea (o se reconoce por
-- su correo) en producción y la cuenta queda en este nodo
CREATE FUNCTION fn_registrar_cuenta_web(p_nombres VARCHAR, p_apellidos VARCHAR, p_correo VARCHAR,
                                        p_hash_clave VARCHAR, p_telefono VARCHAR DEFAULT NULL,
                                        p_ip VARCHAR DEFAULT NULL)
RETURNS INTEGER LANGUAGE plpgsql SET search_path = ecommerce, public AS $$
DECLARE
    v_correo  VARCHAR := LOWER(TRIM(p_correo));
    v_cliente INTEGER;
    v_cuenta  INTEGER;
BEGIN
    IF COALESCE(v_correo, '') = '' OR COALESCE(p_hash_clave, '') = '' THEN
        RAISE EXCEPTION 'El correo y la clave son obligatorios';
    END IF;
    IF EXISTS (SELECT 1 FROM cuenta_web WHERE cwe_correo = v_correo) THEN
        RAISE EXCEPTION 'Ya existe una cuenta con el correo %', v_correo;
    END IF;
    -- Llamada a producción (al separar los nodos: por enlace de base de datos)
    v_cliente := produccion.fn_registrar_cliente(p_nombres, p_apellidos, v_correo, p_telefono);
    IF EXISTS (SELECT 1 FROM cuenta_web WHERE id_cliente = v_cliente) THEN
        RAISE EXCEPTION 'Ese cliente ya tiene una cuenta web';
    END IF;
    INSERT INTO cuenta_web (id_cliente, cwe_correo, cwe_hash_clave)
    VALUES (v_cliente, v_correo, p_hash_clave)
    RETURNING id_cuenta_web INTO v_cuenta;
    PERFORM fn_log_web('INFO', 'REGISTRO', 'Cuenta creada para ' || v_correo, v_cuenta, NULL, p_ip);
    RETURN v_cuenta;
END $$;

-- Inicio de sesión de un cliente (la aplicación valida la clave y registra
-- aquí el resultado). Devuelve la cuenta si el acceso vale.
CREATE FUNCTION fn_registrar_acceso_web(p_correo VARCHAR, p_exito BOOLEAN, p_sesion VARCHAR DEFAULT NULL,
                                        p_ip VARCHAR DEFAULT NULL, p_agente VARCHAR DEFAULT NULL)
RETURNS INTEGER LANGUAGE plpgsql SET search_path = ecommerce, public AS $$
DECLARE
    c RECORD;
BEGIN
    SELECT id_cuenta_web, cwe_activa INTO c FROM cuenta_web WHERE cwe_correo = LOWER(TRIM(p_correo));
    IF p_exito AND FOUND AND c.cwe_activa THEN
        UPDATE cuenta_web SET cwe_ultimo_acceso = CURRENT_TIMESTAMP WHERE id_cuenta_web = c.id_cuenta_web;
        PERFORM fn_log_web('INFO', 'LOGIN_OK', 'Inicio de sesión de ' || LOWER(TRIM(p_correo)),
                           c.id_cuenta_web, p_sesion, p_ip, p_agente);
        RETURN c.id_cuenta_web;
    END IF;
    PERFORM fn_log_web('AVISO', CASE WHEN FOUND AND NOT c.cwe_activa THEN 'LOGIN_BLOQUEADO' ELSE 'LOGIN_FALLIDO' END,
                       'Acceso rechazado para ' || LOWER(TRIM(p_correo)), c.id_cuenta_web, p_sesion, p_ip, p_agente);
    RETURN NULL;
END $$;

-- Confirmar el carrito: producción crea el pedido web (con el precio y la
-- oferta vigentes de cada producto) y el carrito queda cerrado con ese pedido.
-- El carrito no lleva precios ni descuentos: no hay forma de colar uno.
CREATE FUNCTION fn_crear_pedido_desde_carrito(p_carrito INTEGER, p_observacion VARCHAR DEFAULT NULL,
                                              p_sesion VARCHAR DEFAULT NULL, p_ip VARCHAR DEFAULT NULL)
RETURNS INTEGER LANGUAGE plpgsql SET search_path = ecommerce, public AS $$
DECLARE
    c        RECORD;
    v_cuenta RECORD;
    v_lineas JSONB;
    v_pedido INTEGER;
BEGIN
    SELECT * INTO c FROM carrito WHERE id_carrito = p_carrito FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El carrito % no existe', p_carrito;
    END IF;
    IF c.id_pedido IS NOT NULL THEN
        RAISE EXCEPTION 'El carrito % ya se convirtió en el pedido %', p_carrito, c.id_pedido;
    END IF;
    IF c.id_cliente IS NULL THEN
        RAISE EXCEPTION 'Identifique al cliente (cuenta o datos de invitado) antes de confirmar el carrito';
    END IF;
    SELECT id_cuenta_web, cwe_activa INTO v_cuenta FROM cuenta_web WHERE id_cliente = c.id_cliente;
    IF FOUND AND NOT v_cuenta.cwe_activa THEN
        RAISE EXCEPTION 'La cuenta web del cliente está desactivada';
    END IF;
    SELECT jsonb_agg(jsonb_build_object('id_presentacion', id_presentacion, 'cantidad', ica_cantidad))
      INTO v_lineas
    FROM item_carrito WHERE id_carrito = p_carrito;
    IF v_lineas IS NULL THEN
        RAISE EXCEPTION 'El carrito % está vacío', p_carrito;
    END IF;

    -- Llamada a producción (al separar los nodos: por enlace de base de datos)
    v_pedido := produccion.fn_crear_pedido(c.id_cliente, 'WEB', v_lineas, NULL, p_observacion);

    UPDATE carrito SET id_pedido = v_pedido WHERE id_carrito = p_carrito;
    PERFORM fn_log_web('INFO', 'CHECKOUT', 'Carrito ' || p_carrito || ' confirmado como pedido ' || v_pedido,
                       v_cuenta.id_cuenta_web, COALESCE(p_sesion, c.car_token), p_ip, NULL,
                       jsonb_build_object('id_carrito', p_carrito, 'id_pedido', v_pedido));
    RETURN v_pedido;
END $$;


-- =====================================================================
-- E. CONTRATO ENTRE NODOS
--    Un rol por nodo. El e-commerce solo puede leer las vistas de
--    catálogo, pedidos y clientes, registrar contactos y direcciones de
--    sus clientes, y ejecutar fn_crear_pedido, fn_registrar_cliente y
--    fn_registrar_pago (corren con los permisos de producción). Si la
--    sesión no puede crear roles, el contrato queda documentado y la
--    base funciona igual.
-- =====================================================================
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'elite_produccion') THEN
        CREATE ROLE elite_produccion NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'elite_ecommerce') THEN
        CREATE ROLE elite_ecommerce NOLOGIN;
    END IF;

    REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA produccion, ecommerce FROM PUBLIC;

    -- Producción: todo su esquema
    GRANT USAGE ON SCHEMA produccion TO elite_produccion;
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA produccion TO elite_produccion;
    GRANT USAGE ON ALL SEQUENCES IN SCHEMA produccion TO elite_produccion;
    GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA produccion TO elite_produccion;

    -- E-commerce: todo su esquema...
    GRANT USAGE ON SCHEMA ecommerce TO elite_ecommerce;
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA ecommerce TO elite_ecommerce;
    GRANT USAGE ON ALL SEQUENCES IN SCHEMA ecommerce TO elite_ecommerce;
    GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA ecommerce TO elite_ecommerce;
    -- ...y de producción, solo lo que necesita
    GRANT USAGE ON SCHEMA produccion TO elite_ecommerce;
    GRANT SELECT ON produccion.v_catalogo, produccion.v_categoria_principal, produccion.v_oferta_vigente, produccion.v_pedido_estado_actual,
                    produccion.v_pedido_totales, produccion.v_comprobante_venta, produccion.v_frecuencia_cliente,
                    produccion.pedido, produccion.cliente, produccion.telefono, produccion.direccion,
                    produccion.datos_facturacion, produccion.ciudad, produccion.provincia,
                    produccion.tipo_identificacion
        TO elite_ecommerce;
    GRANT INSERT ON produccion.telefono, produccion.direccion, produccion.datos_facturacion TO elite_ecommerce;
    GRANT USAGE ON SEQUENCE produccion.telefono_id_telefono_seq, produccion.direccion_id_direccion_seq,
                            produccion.datos_facturacion_id_datos_facturacion_seq
        TO elite_ecommerce;
    GRANT REFERENCES ON produccion.cliente, produccion.pedido, produccion.presentacion TO elite_ecommerce;
    GRANT EXECUTE ON FUNCTION produccion.fn_crear_pedido(INTEGER, VARCHAR, JSONB, INTEGER, VARCHAR),
                              produccion.fn_registrar_cliente(VARCHAR, VARCHAR, VARCHAR, VARCHAR),
                              produccion.fn_registrar_pago(INTEGER, INTEGER, NUMERIC, INTEGER, VARCHAR, BOOLEAN)
        TO elite_ecommerce;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'Sin permiso para crear roles: el contrato entre nodos queda documentado y no se aplica (%)', SQLERRM;
END $$;


-- =====================================================================
-- F. AL SEPARAR LOS NODOS (referencia, no se ejecuta)
--  Oracle: cada esquema pasa a su propia PDB (o servidor). El e-commerce
--    crea un DATABASE LINK hacia producción y:
--      · v_catalogo_web pasa a MATERIALIZED VIEW sobre el enlace, con
--        refresco programado (por ejemplo, cada 5 minutos);
--      · produccion.fn_crear_pedido(...) pasa a fn_crear_pedido@produccion(...)
--        (lo mismo con fn_registrar_cliente y fn_registrar_pago);
--      · fkx_item_carrito_presentacion apunta a la réplica local del catálogo;
--      · fkx_carrito_cliente, fkx_cuenta_web_cliente y fkx_carrito_pedido
--        se eliminan: los validan las funciones del e-commerce.
--  PostgreSQL: cada esquema pasa a su base o servidor. El e-commerce lee
--    el catálogo por replicación lógica (PUBLICATION en producción,
--    SUBSCRIPTION en e-commerce) o con postgres_fdw, y llama a las
--    funciones de producción con dblink o desde la aplicación.
--  Ninguna tabla se escribe en los dos nodos, así que las secuencias no
--  chocan y no hace falta resolver conflictos.
-- =====================================================================
