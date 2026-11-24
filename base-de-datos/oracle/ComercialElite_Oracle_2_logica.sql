/*==============================================================*/
/* COMERCIAL ELITE - Lógica de la base (versión Oracle 19c / 21c)*/
/* 2. LÓGICA: datos base, vistas, disparadores, funciones del    */
/*    flujo, nodo e-commerce y contrato entre nodos.             */
/*    Equivale a ComercialElite_logica.sql de PostgreSQL, con    */
/*    los mismos nombres de vistas, funciones y disparadores.    */
/*                                                               */
/* Se ejecuta después del script 1, como SYSTEM (o un DBA). Los  */
/* objetos se crean en el esquema de cada nodo con               */
/* ALTER SESSION SET CURRENT_SCHEMA.                             */
/*                                                               */
/* Cómo se usan las funciones desde SQL*Plus / SQL Developer:    */
/*   · Las que en PostgreSQL devuelven VOID son procedimientos:  */
/*       EXEC produccion.fn_cambiar_estado_oc(1, 'EMITIDA', 5)   */
/*   · Las que registran algo y devuelven su número se llaman    */
/*     desde un bloque (Oracle no deja hacer cambios desde un    */
/*     SELECT):                                                  */
/*       VAR id NUMBER                                           */
/*       EXEC :id := produccion.fn_crear_pedido(3, 'TDA',        */
/*            '[{"id_presentacion": 1, "cantidad": 2}]', 5)      */
/*       PRINT id                                                */
/*   · Parámetros JSON: texto JSON (CLOB). Sí/no: 1 / 0.         */
/*   · Errores de negocio: ORA-20001; sin permiso: ORA-20003.    */
/*   · La cola del SRI se consulta en produccion.v_cola_sri (no  */
/*     hay pg_notify en Oracle).                                 */
/*                                                               */
/* Requiere Oracle 19c o superior (LISTAGG DISTINCT, JSON_TABLE, */
/* JSON_OBJECT ... RETURNING CLOB).                              */
/*==============================================================*/

SET DEFINE OFF
SET SQLBLANKLINES ON
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR EXIT FAILURE

ALTER SESSION SET CURRENT_SCHEMA = produccion;


-- =====================================================================
-- 0. APOYO: errores de negocio, sesión y comparación con nulos
-- =====================================================================

-- Error de negocio: todos usan el código -20001 (permisos: -20003)
CREATE OR REPLACE PROCEDURE pr_error(p_mensaje IN VARCHAR2) IS
BEGIN
    RAISE_APPLICATION_ERROR(-20001, SUBSTR(p_mensaje, 1, 2000));
END pr_error;
/

-- Usuario de la aplicación en la sesión (en PostgreSQL: app.id_usuario).
-- Lo fija fn_exigir_permiso o fn_usuario_sesion y lo lee la auditoría.
CREATE OR REPLACE PACKAGE pk_sesion AS
    PROCEDURE fijar_usuario(p_usuario IN NUMBER);
    FUNCTION usuario RETURN NUMBER;
END pk_sesion;
/
CREATE OR REPLACE PACKAGE BODY pk_sesion AS
    g_usuario NUMBER;
    PROCEDURE fijar_usuario(p_usuario IN NUMBER) IS
    BEGIN
        g_usuario := p_usuario;
    END fijar_usuario;
    FUNCTION usuario RETURN NUMBER IS
    BEGIN
        RETURN g_usuario;
    END usuario;
END pk_sesion;
/

-- "IS DISTINCT FROM" de PostgreSQL: distinto considerando los nulos
CREATE OR REPLACE PACKAGE pk_util AS
    FUNCTION distinto(a IN NUMBER,    b IN NUMBER)    RETURN BOOLEAN;
    FUNCTION distinto(a IN VARCHAR2,  b IN VARCHAR2)  RETURN BOOLEAN;
    FUNCTION distinto(a IN TIMESTAMP, b IN TIMESTAMP) RETURN BOOLEAN;
    FUNCTION distinto(a IN DATE,      b IN DATE)      RETURN BOOLEAN;
END pk_util;
/
CREATE OR REPLACE PACKAGE BODY pk_util AS
    FUNCTION distinto(a IN NUMBER, b IN NUMBER) RETURN BOOLEAN IS
    BEGIN
        RETURN CASE WHEN a IS NULL AND b IS NULL THEN FALSE WHEN a IS NULL OR b IS NULL THEN TRUE ELSE a <> b END;
    END;
    FUNCTION distinto(a IN VARCHAR2, b IN VARCHAR2) RETURN BOOLEAN IS
    BEGIN
        RETURN CASE WHEN a IS NULL AND b IS NULL THEN FALSE WHEN a IS NULL OR b IS NULL THEN TRUE ELSE a <> b END;
    END;
    FUNCTION distinto(a IN TIMESTAMP, b IN TIMESTAMP) RETURN BOOLEAN IS
    BEGIN
        RETURN CASE WHEN a IS NULL AND b IS NULL THEN FALSE WHEN a IS NULL OR b IS NULL THEN TRUE ELSE a <> b END;
    END;
    FUNCTION distinto(a IN DATE, b IN DATE) RETURN BOOLEAN IS
    BEGIN
        RETURN CASE WHEN a IS NULL AND b IS NULL THEN FALSE WHEN a IS NULL OR b IS NULL THEN TRUE ELSE a <> b END;
    END;
END pk_util;
/


-- =====================================================================
-- DATOS BASE (necesarios para el flujo). Se cargan antes de crear los
-- disparadores, igual que en PostgreSQL.
-- =====================================================================
INSERT INTO tipo_identificacion VALUES ('04', 'RUC');
INSERT INTO tipo_identificacion VALUES ('05', 'Cédula');
INSERT INTO tipo_identificacion VALUES ('06', 'Pasaporte');
INSERT INTO tipo_identificacion VALUES ('07', 'Consumidor final');
INSERT INTO tipo_identificacion VALUES ('08', 'Identificación del exterior');

-- Códigos de porcentaje según la ficha técnica del SRI (verificar la versión vigente)
INSERT INTO tarifa_iva VALUES ('0', 0,  'IVA 0%',              1);
INSERT INTO tarifa_iva VALUES ('2', 12, 'IVA 12% (histórica)', 0);
INSERT INTO tarifa_iva VALUES ('4', 15, 'IVA 15%',             1);

INSERT INTO unidad_medida VALUES ('u',    'Unidad');
INSERT INTO unidad_medida VALUES ('m',    'Metro');
INSERT INTO unidad_medida VALUES ('m2',   'Metro cuadrado');
INSERT INTO unidad_medida VALUES ('pie2', 'Pie cuadrado');
INSERT INTO unidad_medida VALUES ('par',  'Par');
INSERT INTO unidad_medida VALUES ('kg',   'Kilogramo');
INSERT INTO unidad_medida VALUES ('l',    'Litro');

INSERT INTO canal_venta VALUES ('WEB', 'E-commerce');
INSERT INTO canal_venta VALUES ('TDA', 'Tienda física');
INSERT INTO canal_venta VALUES ('WSP', 'WhatsApp / teléfono');

INSERT INTO estado_pedido VALUES ('PEN', 'Pendiente de pago', 1);
INSERT INTO estado_pedido VALUES ('PAG', 'Pago o crédito confirmado', 2);
INSERT INTO estado_pedido VALUES ('FAC', 'Comprobante emitido', 3);
INSERT INTO estado_pedido VALUES ('DES', 'Despachado', 4);
INSERT INTO estado_pedido VALUES ('ENT', 'Entregado', 5);
INSERT INTO estado_pedido VALUES ('CAN', 'Cancelado', 6);

-- Tipos de comprobante (código SRI). Solo la factura de venta va al SRI.
--   columnas: código, nombre, en venta, en compra, desglosa IVA, electrónico SRI
INSERT INTO tipo_comprobante VALUES ('01', 'Factura',                  1, 1, 1, 1);
INSERT INTO tipo_comprobante VALUES ('02', 'Nota de venta',            1, 1, 0, 0);
INSERT INTO tipo_comprobante VALUES ('00', 'Sin comprobante (recibo)', 0, 1, 0, 0);

INSERT INTO metodo_pago (mpa_nombre, mpa_codigo_sri) VALUES ('Efectivo',                 '01');
INSERT INTO metodo_pago (mpa_nombre, mpa_codigo_sri) VALUES ('Transferencia bancaria',   '20');
INSERT INTO metodo_pago (mpa_nombre, mpa_codigo_sri) VALUES ('Tarjeta de débito',        '16');
INSERT INTO metodo_pago (mpa_nombre, mpa_codigo_sri) VALUES ('Tarjeta de crédito',       '19');
INSERT INTO metodo_pago (mpa_nombre, mpa_codigo_sri) VALUES ('Pago en línea (pasarela)', '19');

INSERT INTO motivo_avance (mav_nombre) VALUES ('Pasaje');
INSERT INTO motivo_avance (mav_nombre) VALUES ('Compra en otro establecimiento');
INSERT INTO motivo_avance (mav_nombre) VALUES ('Otro');

INSERT INTO motivo_devolucion (mde_nombre) VALUES ('Producto defectuoso');
INSERT INTO motivo_devolucion (mde_nombre) VALUES ('Error en el despacho');
INSERT INTO motivo_devolucion (mde_nombre) VALUES ('No corresponde a la descripción');
INSERT INTO motivo_devolucion (mde_nombre) VALUES ('Cliente no satisfecho');

INSERT INTO tipo_movimiento VALUES ('INI', 'Inventario inicial',              1);
INSERT INTO tipo_movimiento VALUES ('COM', 'Compra (recepción)',              1);
INSERT INTO tipo_movimiento VALUES ('DCL', 'Devolución de cliente',           1);
INSERT INTO tipo_movimiento VALUES ('AJP', 'Ajuste positivo',                 1);
INSERT INTO tipo_movimiento VALUES ('VEN', 'Venta (despacho)',               -1);
INSERT INTO tipo_movimiento VALUES ('DPR', 'Devolución a proveedor',         -1);
INSERT INTO tipo_movimiento VALUES ('AJN', 'Ajuste negativo',                -1);
INSERT INTO tipo_movimiento VALUES ('MER', 'Merma o daño',                   -1);
INSERT INTO tipo_movimiento VALUES ('FRS', 'Fraccionamiento (sale la pieza)', -1);
INSERT INTO tipo_movimiento VALUES ('FRE', 'Fraccionamiento (entra paquete)',  1);

INSERT INTO rol (rol_codigo, rol_nombre) VALUES ('ADMIN',    'Administrador');
INSERT INTO rol (rol_codigo, rol_nombre) VALUES ('VENDEDOR', 'Vendedor de tienda');
INSERT INTO rol (rol_codigo, rol_nombre) VALUES ('BODEGA',   'Bodeguero');
INSERT INTO rol (rol_codigo, rol_nombre) VALUES ('COMPRAS',  'Responsable de compras');
INSERT INTO rol (rol_codigo, rol_nombre) VALUES ('SISTEMA',  'Procesos automáticos del e-commerce');

INSERT INTO permiso (per_codigo, per_descripcion) VALUES ('CATALOGO_GESTIONAR',  'Crear y editar productos, variantes y presentaciones');
INSERT INTO permiso (per_codigo, per_descripcion) VALUES ('PRECIO_GESTIONAR',    'Registrar cambios de precio');
INSERT INTO permiso (per_codigo, per_descripcion) VALUES ('VENTA_REGISTRAR',     'Registrar ventas en tienda o por WhatsApp');
INSERT INTO permiso (per_codigo, per_descripcion) VALUES ('PAGO_REGISTRAR',      'Registrar y confirmar pagos');
INSERT INTO permiso (per_codigo, per_descripcion) VALUES ('VENTA_FACTURAR',      'Emitir facturas');
INSERT INTO permiso (per_codigo, per_descripcion) VALUES ('PEDIDO_DESPACHAR',    'Despachar y marcar pedidos como entregados');
INSERT INTO permiso (per_codigo, per_descripcion) VALUES ('NC_EMITIR',           'Autorizar devoluciones y emitir notas de crédito');
INSERT INTO permiso (per_codigo, per_descripcion) VALUES ('INV_RECEPCIONAR',     'Recibir mercadería de órdenes de compra');
INSERT INTO permiso (per_codigo, per_descripcion) VALUES ('INV_AJUSTAR',         'Registrar inventario inicial, ajustes y mermas');
INSERT INTO permiso (per_codigo, per_descripcion) VALUES ('COMPRA_GESTIONAR',    'Gestionar órdenes, facturas y devoluciones a proveedores');
INSERT INTO permiso (per_codigo, per_descripcion) VALUES ('CREDITO_OTORGAR',     'Vender a crédito y entregar avances de dinero');
INSERT INTO permiso (per_codigo, per_descripcion) VALUES ('INV_FRACCIONAR',      'Cortar piezas (bandas) en paquetes');
INSERT INTO permiso (per_codigo, per_descripcion) VALUES ('SRI_GESTIONAR',       'Registrar las respuestas del SRI');
INSERT INTO permiso (per_codigo, per_descripcion) VALUES ('USUARIO_GESTIONAR',   'Administrar usuarios y roles');
INSERT INTO permiso (per_codigo, per_descripcion) VALUES ('PRECIO_NEGOCIAR',     'Negociar el precio de una venta en tienda o WhatsApp');
INSERT INTO permiso (per_codigo, per_descripcion) VALUES ('AUDITORIA_CONSULTAR', 'Consultar la bitácora y la auditoría');

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

COMMIT;


-- =====================================================================
-- A. VISTAS (todo dato derivado se calcula aquí)
--    Las columnas que en PostgreSQL son BOOLEAN aquí valen 1 / 0.
-- =====================================================================

-- Precio vigente de cada presentación (último cambio ya en vigor)
CREATE OR REPLACE VIEW v_precio_vigente AS
SELECT id_presentacion, precio, vigente_desde
FROM (SELECT hp.id_presentacion,
             hp.hpr_precio        AS precio,
             hp.hpr_vigente_desde AS vigente_desde,
             ROW_NUMBER() OVER (PARTITION BY hp.id_presentacion ORDER BY hp.hpr_vigente_desde DESC) AS rn
      FROM historial_precio hp
      WHERE hp.hpr_vigente_desde <= LOCALTIMESTAMP)
WHERE rn = 1;

-- Oferta vigente de cada producto (a lo sumo una: las activas no se solapan)
CREATE OR REPLACE VIEW v_oferta_vigente AS
SELECT o.id_oferta, o.id_producto, o.ofe_porcentaje, o.ofe_descripcion, o.ofe_desde, o.ofe_hasta
FROM oferta o
WHERE o.ofe_activa = 1
  AND o.ofe_desde <= LOCALTIMESTAMP
  AND (o.ofe_hasta IS NULL OR o.ofe_hasta > LOCALTIMESTAMP);

-- Estado actual del pedido (último registro del historial)
CREATE OR REPLACE VIEW v_pedido_estado_actual AS
SELECT id_pedido, id_estado_pedido, estado, desde
FROM (SELECT h.id_pedido,
             h.id_estado_pedido,
             e.esp_nombre    AS estado,
             h.hep_fechahora AS desde,
             ROW_NUMBER() OVER (PARTITION BY h.id_pedido
                                ORDER BY h.hep_fechahora DESC, h.id_historial_estado DESC) AS rn
      FROM historial_estado_pedido h
      JOIN estado_pedido e ON e.id_estado_pedido = h.id_estado_pedido)
WHERE rn = 1;

-- Valor de cada línea de pedido (base imponible e IVA) y su equivalente en unidad base.
-- Descuento total = oferta (del porcentaje de la oferta aplicada) + negociado (dpe_descuento)
CREATE OR REPLACE VIEW v_detalle_pedido_valor AS
WITH l AS (
    SELECT d.id_detalle_pedido, d.id_pedido, d.id_presentacion, d.dpe_cantidad, d.dpe_precio_unitario,
           d.dpe_descuento, d.id_tarifa_iva, d.id_oferta, d.id_usuario_descuento,
           pr.id_variante, pr.pre_factor, t.tiv_porcentaje, o.ofe_porcentaje,
           d.dpe_cantidad * d.dpe_precio_unitario                                                  AS bruto,
           ROUND(d.dpe_cantidad * d.dpe_precio_unitario * NVL(o.ofe_porcentaje, 0) / 100, 2)       AS descuento_oferta
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
       CAST(dpe_cantidad * pre_factor AS NUMBER(14,3))                  AS cantidad_base,
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

-- Totales del pedido (= totales de su comprobante), incluido el envío
CREATE OR REPLACE VIEW v_pedido_totales AS
WITH lineas AS (
    SELECT id_pedido, tiv_porcentaje, base_imponible, iva, descuento_total AS descuento, 0 AS es_envio
    FROM v_detalle_pedido_valor
    UNION ALL
    SELECT e.id_pedido, t.tiv_porcentaje, e.env_costo,
           ROUND(e.env_costo * t.tiv_porcentaje / 100, 2), 0, 1
    FROM envio e
    JOIN tarifa_iva t ON t.id_tarifa_iva = e.id_tarifa_iva
)
SELECT p.id_pedido,
       NVL(SUM(CASE WHEN l.tiv_porcentaje = 0 THEN l.base_imponible END), 0) AS subtotal_0,
       NVL(SUM(CASE WHEN l.tiv_porcentaje > 0 THEN l.base_imponible END), 0) AS subtotal_gravado,
       NVL(SUM(l.descuento), 0)                                              AS descuento,
       NVL(SUM(CASE WHEN l.es_envio = 1 THEN l.base_imponible END), 0)       AS costo_envio,
       NVL(SUM(l.iva), 0)                                                    AS iva,
       NVL(SUM(l.base_imponible + l.iva), 0)                                 AS total
FROM pedido p
LEFT JOIN lineas l ON l.id_pedido = p.id_pedido
GROUP BY p.id_pedido;

-- Pagos aprobados y crédito otorgado por pedido
CREATE OR REPLACE VIEW v_pedido_pagos AS
SELECT p.id_pedido,
       NVL(pg.pagado, 0)                       AS pagado,
       NVL(cr.credito, 0)                      AS credito,
       NVL(pg.pagado, 0) + NVL(cr.credito, 0)  AS cubierto
FROM pedido p
LEFT JOIN (SELECT id_pedido, SUM(pag_monto) AS pagado
           FROM pago WHERE pag_estado = 'APROBADO' GROUP BY id_pedido) pg ON pg.id_pedido = p.id_pedido
LEFT JOIN (SELECT id_pedido, SUM(cxc_monto) AS credito
           FROM cuenta_por_cobrar WHERE cxc_tipo = 'CREDITO' GROUP BY id_pedido) cr ON cr.id_pedido = p.id_pedido;

-- Pieza original de cada lote (un paquete cortado de una banda hereda
-- la fecha de ingreso de la banda, aunque se haya cortado después)
CREATE OR REPLACE VIEW v_lote_raiz AS
WITH r (id_lote, id_lote_raiz, id_lote_origen) AS (
    SELECT id_lote, id_lote, id_lote_origen FROM lote
    UNION ALL
    SELECT r.id_lote, l.id_lote, l.id_lote_origen
    FROM r JOIN lote l ON l.id_lote = r.id_lote_origen
)
SELECT id_lote, id_lote_raiz FROM r WHERE id_lote_origen IS NULL;

-- Saldo, fecha de ingreso y antigüedad de cada lote
CREATE OR REPLACE VIEW v_lote_saldo AS
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
       i.fecha                                                             AS fecha_ingreso,
       SUM(CASE WHEN t.tmv_signo = 1 THEN dm.dmo_cantidad END)             AS entradas,
       NVL(SUM(CASE WHEN t.tmv_signo = -1 THEN dm.dmo_cantidad END), 0)    AS salidas,
       SUM(dm.dmo_cantidad * t.tmv_signo)                                  AS saldo,
       MAX(m.mov_fechahora)                                                AS ultimo_movimiento,
       TRUNC(SYSDATE) - TRUNC(CAST(i.fecha AS DATE))                       AS dias_en_inventario
FROM lote l
JOIN v_lote_raiz           lr ON lr.id_lote       = l.id_lote
JOIN ingreso               i  ON i.id_lote        = lr.id_lote_raiz
JOIN detalle_movimiento    dm ON dm.id_lote       = l.id_lote
JOIN movimiento_inventario m  ON m.id_movimiento  = dm.id_movimiento
JOIN tipo_movimiento       t  ON t.id_tipo_movimiento = m.id_tipo_movimiento
GROUP BY l.id_lote, l.id_variante, l.id_lote_origen, l.lot_codigo_proveedor, l.lot_costo_unitario,
         l.lot_fecha_vencimiento, i.fecha;

-- Avance de recepción por línea de orden de compra
CREATE OR REPLACE VIEW v_orden_compra_detalle AS
SELECT d.id_detalle_orden_compra,
       d.id_orden_compra,
       d.id_variante,
       v.var_sku,
       d.dco_cantidad                                    AS cantidad_pedida,
       d.dco_costo_unitario                              AS costo_pactado,
       NVL(r.recibido, 0)                                AS cantidad_recibida,
       GREATEST(d.dco_cantidad - NVL(r.recibido, 0), 0)  AS cantidad_pendiente
FROM detalle_orden_compra d
JOIN variante v ON v.id_variante = d.id_variante
LEFT JOIN (
    SELECT id_detalle_orden_compra, SUM(dmo_cantidad) AS recibido
    FROM detalle_movimiento
    WHERE id_detalle_orden_compra IS NOT NULL
    GROUP BY id_detalle_orden_compra
) r ON r.id_detalle_orden_compra = d.id_detalle_orden_compra;

-- Estado de recepción de la orden de compra (calculado, no almacenado)
CREATE OR REPLACE VIEW v_orden_compra_estado AS
SELECT oc.id_orden_compra,
       pr.prv_razon_social                          AS proveedor,
       oc.oc_fecha,
       oc.oc_fecha_entrega_esperada,
       oc.oc_estado,
       ROUND(SUM(d.cantidad_pedida * d.costo_pactado), 2) AS valor_pactado,
       CASE
           WHEN oc.oc_estado IN ('BORRADOR', 'ANULADA') THEN 'NO APLICA'
           WHEN NVL(SUM(d.cantidad_recibida), 0) = 0    THEN 'PENDIENTE'
           WHEN SUM(d.cantidad_pendiente) = 0           THEN 'COMPLETA'
           ELSE 'PARCIAL'
       END                                          AS estado_recepcion,
       CASE WHEN oc.oc_estado = 'EMITIDA'
             AND oc.oc_fecha_entrega_esperada < TRUNC(SYSDATE)
             AND SUM(d.cantidad_pendiente) > 0 THEN 1 ELSE 0 END AS atrasada
FROM orden_compra oc
JOIN proveedor pr ON pr.id_proveedor = oc.id_proveedor
LEFT JOIN v_orden_compra_detalle d ON d.id_orden_compra = oc.id_orden_compra
GROUP BY oc.id_orden_compra, pr.prv_razon_social, oc.oc_fecha, oc.oc_fecha_entrega_esperada, oc.oc_estado;

-- Stock por variante: físico, reservado por pedidos sin comprobante,
-- disponible para vender, en camino (OC emitidas), valor y antigüedad
CREATE OR REPLACE VIEW v_stock_variante AS
WITH saldos AS (
    SELECT id_variante,
           SUM(saldo)                                                    AS stock_fisico,
           SUM(saldo * lot_costo_unitario)                               AS valor_inventario,
           SUM(CASE WHEN saldo > 0 THEN saldo * dias_en_inventario END)
               / NULLIF(SUM(CASE WHEN saldo > 0 THEN saldo END), 0)      AS antiguedad_promedio_dias,
           MAX(CASE WHEN saldo > 0 THEN dias_en_inventario END)          AS antiguedad_maxima_dias,
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
       p.id_unidad_medida                                    AS unidad,
       NVL(s.stock_fisico, 0)                                AS stock_fisico,
       NVL(r.reservado, 0)                                   AS reservado,
       NVL(s.stock_fisico, 0) - NVL(r.reservado, 0)          AS disponible,
       NVL(c.en_camino, 0)                                   AS en_camino,
       v.var_stock_minimo                                    AS stock_minimo,
       CASE WHEN NVL(s.stock_fisico, 0) - NVL(r.reservado, 0) + NVL(c.en_camino, 0) <= v.var_stock_minimo
            THEN 1 ELSE 0 END                                AS requiere_compra,
       ROUND(NVL(s.valor_inventario, 0), 2)                  AS valor_inventario,
       ROUND(s.antiguedad_promedio_dias, 1)                  AS antiguedad_promedio_dias,
       s.antiguedad_maxima_dias,
       s.ultimo_movimiento
FROM variante v
JOIN producto p ON p.id_producto = v.id_producto
LEFT JOIN saldos    s ON s.id_variante = v.id_variante
LEFT JOIN reservas  r ON r.id_variante = v.id_variante
LEFT JOIN en_camino c ON c.id_variante = v.id_variante;

-- Kárdex: entradas, salidas y saldo acumulado (en cantidad y valorizado) por variante
CREATE OR REPLACE VIEW v_kardex AS
SELECT m.mov_fechahora                                  AS fecha,
       l.id_variante,
       v.var_sku,
       m.id_movimiento,
       m.id_tipo_movimiento                             AS tipo,
       t.tmv_nombre                                     AS movimiento,
       CASE m.id_tipo_movimiento
           WHEN 'VEN' THEN tc.tco_nombre || ' ' || fe.pem_establecimiento || '-' || fe.pem_punto || '-' || LPAD(TO_CHAR(f.cve_secuencial), 9, '0')
           WHEN 'DCL' THEN 'N/C '     || ne.pem_establecimiento || '-' || ne.pem_punto || '-' || LPAD(TO_CHAR(nc.ncr_secuencial), 9, '0')
           WHEN 'COM' THEN 'OC ' || m.id_orden_compra || NVL2(fp.cco_numero, ' / comp. ' || fp.cco_numero, NULL)
           WHEN 'DPR' THEN 'OC ' || m.id_orden_compra || ' / ' || m.mov_motivo
           ELSE m.mov_motivo
       END                                              AS documento,
       dm.id_lote,
       l.lot_costo_unitario                             AS costo_unitario,
       CASE WHEN t.tmv_signo =  1 THEN dm.dmo_cantidad END AS entrada,
       CASE WHEN t.tmv_signo = -1 THEN dm.dmo_cantidad END AS salida,
       SUM(dm.dmo_cantidad * t.tmv_signo)
           OVER (PARTITION BY l.id_variante ORDER BY m.mov_fechahora, dm.id_detalle_movimiento) AS saldo,
       ROUND(dm.dmo_cantidad * l.lot_costo_unitario * t.tmv_signo, 2) AS valor,
       ROUND(SUM(dm.dmo_cantidad * l.lot_costo_unitario * t.tmv_signo)
           OVER (PARTITION BY l.id_variante ORDER BY m.mov_fechahora, dm.id_detalle_movimiento), 2) AS saldo_valorizado,
       u.usu_correo                                     AS usuario
FROM detalle_movimiento dm
JOIN movimiento_inventario m  ON m.id_movimiento      = dm.id_movimiento
JOIN tipo_movimiento       t  ON t.id_tipo_movimiento = m.id_tipo_movimiento
JOIN lote                  l  ON l.id_lote            = dm.id_lote
JOIN variante              v  ON v.id_variante        = l.id_variante
JOIN usuario               u  ON u.id_usuario         = m.id_usuario
LEFT JOIN comprobante_venta  f  ON f.id_comprobante_venta   = m.id_comprobante_venta
LEFT JOIN tipo_comprobante   tc ON tc.id_tipo_comprobante   = f.id_tipo_comprobante
LEFT JOIN punto_emision      fe ON fe.id_punto_emision      = f.id_punto_emision
LEFT JOIN nota_credito       nc ON nc.id_nota_credito       = m.id_nota_credito
LEFT JOIN punto_emision      ne ON ne.id_punto_emision      = nc.id_punto_emision
LEFT JOIN comprobante_compra fp ON fp.id_comprobante_compra = m.id_comprobante_compra;

-- Comprobante de venta (factura o nota de venta) con número, comprador,
-- canal, vendedor y totales. La nota de venta no discrimina IVA.
CREATE OR REPLACE VIEW v_comprobante_venta AS
SELECT f.id_comprobante_venta,
       f.id_tipo_comprobante,
       tc.tco_nombre                                       AS tipo_comprobante,
       pe.pem_establecimiento || '-' || pe.pem_punto || '-' || LPAD(TO_CHAR(f.cve_secuencial), 9, '0') AS numero,
       f.cve_fechahora                                     AS fecha,
       f.cve_estado                                        AS estado_sri,
       f.cve_clave_acceso                                  AS clave_acceso,
       f.id_pedido,
       p.id_canal_venta                                    AS canal,
       NVL2(e.id_usuario, e.epl_nombres || ' ' || e.epl_apellidos, 'E-commerce') AS vendedor,
       df.id_tipo_identificacion                           AS tipo_identificacion,
       df.dfa_identificacion                               AS identificacion,
       NVL(df.dfa_razon_social, cl.cli_nombres || NVL2(cl.cli_apellidos, ' ' || cl.cli_apellidos, NULL)) AS razon_social,
       CASE WHEN tc.tco_desglosa_iva = 1 THEN t.subtotal_0 END       AS subtotal_0,
       CASE WHEN tc.tco_desglosa_iva = 1 THEN t.subtotal_gravado END AS subtotal_gravado,
       t.descuento, t.costo_envio,
       CASE WHEN tc.tco_desglosa_iva = 1 THEN t.iva END              AS iva,
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
CREATE OR REPLACE VIEW v_nota_credito AS
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
       pe.pem_establecimiento || '-' || pe.pem_punto || '-' || LPAD(TO_CHAR(nc.ncr_secuencial), 9, '0') AS numero,
       nc.ncr_fechahora                 AS fecha,
       nc.id_comprobante_venta,
       vf.numero                        AS comprobante_venta,
       m.mde_nombre                     AS motivo,
       nc.ncr_estado                    AS estado_sri,
       NVL(v.subtotal, 0)               AS subtotal,
       NVL(v.iva, 0)                    AS iva,
       NVL(v.subtotal + v.iva, 0)       AS total,
       u.usu_correo                     AS autorizada_por
FROM nota_credito nc
JOIN punto_emision       pe ON pe.id_punto_emision     = nc.id_punto_emision
JOIN motivo_devolucion   m  ON m.id_motivo_devolucion  = nc.id_motivo_devolucion
JOIN v_comprobante_venta vf ON vf.id_comprobante_venta = nc.id_comprobante_venta
JOIN usuario             u  ON u.id_usuario            = nc.id_usuario_autoriza
LEFT JOIN valores        v  ON v.id_nota_credito       = nc.id_nota_credito;

-- Ventas por día, canal (físico / e-commerce / WhatsApp), vendedor y tipo de comprobante
CREATE OR REPLACE VIEW v_ventas_por_canal AS
SELECT TRUNC(f.fecha)       AS fecha,
       c.cav_nombre         AS canal,
       f.vendedor,
       f.tipo_comprobante,
       COUNT(*)             AS comprobantes,
       SUM(f.total)         AS total_vendido
FROM v_comprobante_venta f
JOIN canal_venta c ON c.id_canal_venta = f.canal
WHERE f.estado_sri <> 'ANULADA'
GROUP BY TRUNC(f.fecha), c.cav_nombre, f.vendedor, f.tipo_comprobante;

-- Frecuencia de clientes (recencia, frecuencia, monto) y segmento
CREATE OR REPLACE VIEW v_frecuencia_cliente AS
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
           COUNT(co.id_pedido)               AS compras,
           MIN(co.cve_fechahora)             AS primera_compra,
           MAX(co.cve_fechahora)             AS ultima_compra,
           NVL(SUM(co.total), 0)             AS monto_comprado,
           STATS_MODE(co.id_canal_venta)     AS canal_preferido
    FROM cliente c
    LEFT JOIN compras co ON co.id_cliente = c.id_cliente
    WHERE NOT EXISTS (SELECT 1 FROM datos_facturacion df            -- excluye al genérico
                      WHERE df.id_cliente = c.id_cliente AND df.id_tipo_identificacion = '07')
    GROUP BY c.id_cliente
)
SELECT r.id_cliente,
       c.cli_nombres || NVL2(c.cli_apellidos, ' ' || c.cli_apellidos, NULL)   AS cliente,
       r.compras,
       r.primera_compra,
       r.ultima_compra,
       TRUNC(SYSDATE) - TRUNC(CAST(r.ultima_compra AS DATE))                  AS dias_sin_comprar,
       ROUND((TRUNC(CAST(r.ultima_compra AS DATE)) - TRUNC(CAST(r.primera_compra AS DATE)))
             / NULLIF(r.compras - 1, 0), 1)                                    AS dias_entre_compras,
       r.monto_comprado,
       NVL(d.devuelto, 0)                                  AS monto_devuelto,
       r.monto_comprado - NVL(d.devuelto, 0)               AS monto_neto,
       r.canal_preferido,
       CASE
           WHEN r.compras = 0                                                     THEN 'SIN COMPRAS'
           WHEN TRUNC(SYSDATE) - TRUNC(CAST(r.ultima_compra AS DATE)) > 180       THEN 'INACTIVO'
           WHEN r.compras >= 5                                                    THEN 'FRECUENTE'
           WHEN r.compras >= 2                                                    THEN 'RECURRENTE'
           ELSE 'NUEVO'
       END                                                 AS segmento
FROM resumen r
JOIN cliente c ON c.id_cliente = r.id_cliente
LEFT JOIN devoluciones d ON d.id_cliente = r.id_cliente;

-- Cuentas por pagar a proveedores (por comprobante): total - notas de crédito - pagos
CREATE OR REPLACE VIEW v_cuentas_por_pagar AS
SELECT fp.id_comprobante_compra,
       fp.id_proveedor,
       pr.prv_razon_social                                            AS proveedor,
       tc.tco_nombre                                                  AS tipo_comprobante,
       fp.cco_numero                                                  AS numero,
       fp.cco_fecha_emision                                           AS emision,
       fp.cco_fecha_vencimiento                                       AS vencimiento,
       fp.cco_subtotal_0 + fp.cco_subtotal_gravado + fp.cco_iva       AS total,
       NVL(nc.monto, 0)                                               AS notas_credito,
       NVL(pg.pagado, 0)                                              AS pagado,
       fp.cco_subtotal_0 + fp.cco_subtotal_gravado + fp.cco_iva
         - NVL(nc.monto, 0) - NVL(pg.pagado, 0)                       AS saldo,
       CASE WHEN fp.cco_fecha_vencimiento < TRUNC(SYSDATE)
             AND fp.cco_subtotal_0 + fp.cco_subtotal_gravado + fp.cco_iva
                 - NVL(nc.monto, 0) - NVL(pg.pagado, 0) > 0 THEN 1 ELSE 0 END AS vencida
FROM comprobante_compra fp
JOIN proveedor pr ON pr.id_proveedor = fp.id_proveedor
JOIN tipo_comprobante tc ON tc.id_tipo_comprobante = fp.id_tipo_comprobante
LEFT JOIN (SELECT id_comprobante_compra, SUM(ppr_monto) AS pagado
           FROM pago_proveedor GROUP BY id_comprobante_compra) pg ON pg.id_comprobante_compra = fp.id_comprobante_compra
LEFT JOIN (SELECT id_comprobante_compra, SUM(ncp_subtotal_0 + ncp_subtotal_gravado + ncp_iva) AS monto
           FROM nota_credito_proveedor GROUP BY id_comprobante_compra) nc ON nc.id_comprobante_compra = fp.id_comprobante_compra;

-- Valor de cada recepción (COM) o devolución a proveedor (DPR) al costo real
-- del lote, con el IVA estimado según la tarifa de cada producto
CREATE OR REPLACE VIEW v_recepcion_valor AS
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
GROUP BY m.id_movimiento, m.id_tipo_movimiento, m.mov_fechahora, oc.id_proveedor, m.id_orden_compra,
         m.id_comprobante_compra;

-- Mercadería recibida que todavía no tiene comprobante del proveedor
CREATE OR REPLACE VIEW v_recepciones_por_facturar AS
SELECT rv.id_movimiento,
       rv.id_proveedor,
       pr.prv_razon_social                              AS proveedor,
       rv.id_orden_compra,
       rv.fecha,
       rv.valor,
       rv.iva_estimado,
       rv.valor + rv.iva_estimado                       AS total_estimado,
       TRUNC(SYSDATE) - TRUNC(CAST(rv.fecha AS DATE))   AS dias_sin_factura
FROM v_recepcion_valor rv
JOIN proveedor pr ON pr.id_proveedor = rv.id_proveedor
WHERE rv.id_tipo_movimiento = 'COM' AND rv.id_comprobante_compra IS NULL;

-- Control del valor de ingreso: lo que dice el comprobante del proveedor
-- contra lo recibido en bodega al costo real
CREATE OR REPLACE VIEW v_conciliacion_compra AS
SELECT fp.id_comprobante_compra,
       pr.prv_razon_social                                              AS proveedor,
       fp.cco_numero                                                    AS numero,
       fp.cco_fecha_emision                                             AS emision,
       fp.cco_subtotal_0 + fp.cco_subtotal_gravado                      AS subtotal_facturado,
       NVL(SUM(rv.valor), 0)                                            AS valor_recibido,
       fp.cco_subtotal_0 + fp.cco_subtotal_gravado - NVL(SUM(rv.valor), 0) AS diferencia,
       CASE WHEN COUNT(rv.id_movimiento) = 0 THEN 'SIN MERCADERÍA ASOCIADA'
            WHEN ABS(fp.cco_subtotal_0 + fp.cco_subtotal_gravado - SUM(rv.valor)) <= 0.01 THEN 'CUADRA'
            ELSE 'DIFERENCIA' END                                       AS estado
FROM comprobante_compra fp
JOIN proveedor pr ON pr.id_proveedor = fp.id_proveedor
LEFT JOIN v_recepcion_valor rv ON rv.id_comprobante_compra = fp.id_comprobante_compra AND rv.id_tipo_movimiento = 'COM'
GROUP BY fp.id_comprobante_compra, pr.prv_razon_social, fp.cco_numero, fp.cco_fecha_emision,
         fp.cco_subtotal_0, fp.cco_subtotal_gravado;

-- Estado de cuenta por proveedor: mercadería, documentos, pagos y deuda
CREATE OR REPLACE VIEW v_estado_cuenta_proveedor AS
SELECT pr.id_proveedor,
       pr.prv_razon_social                          AS proveedor,
       pr.prv_identificacion                        AS identificacion,
       NVL(r.recibido, 0)                           AS mercaderia_recibida,
       NVL(r.devuelto, 0)                           AS mercaderia_devuelta,
       NVL(c.facturado, 0)                          AS facturado,
       NVL(c.notas_credito, 0)                      AS notas_credito,
       NVL(c.pagado, 0)                             AS pagado,
       NVL(c.saldo, 0)                              AS saldo_facturas,
       NVL(c.vencido, 0)                            AS saldo_vencido,
       NVL(pf.por_facturar, 0)                      AS por_facturar_estimado,
       NVL(c.saldo, 0) + NVL(pf.por_facturar, 0)    AS deuda_estimada
FROM proveedor pr
LEFT JOIN (SELECT id_proveedor,
                  SUM(CASE WHEN id_tipo_movimiento = 'COM' THEN valor END) AS recibido,
                  SUM(CASE WHEN id_tipo_movimiento = 'DPR' THEN valor END) AS devuelto
           FROM v_recepcion_valor GROUP BY id_proveedor) r ON r.id_proveedor = pr.id_proveedor
LEFT JOIN (SELECT id_proveedor, SUM(total) AS facturado, SUM(notas_credito) AS notas_credito,
                  SUM(pagado) AS pagado, SUM(saldo) AS saldo, SUM(CASE WHEN vencida = 1 THEN saldo END) AS vencido
           FROM v_cuentas_por_pagar GROUP BY id_proveedor) c ON c.id_proveedor = pr.id_proveedor
LEFT JOIN (SELECT id_proveedor, SUM(total_estimado) AS por_facturar
           FROM v_recepciones_por_facturar GROUP BY id_proveedor) pf ON pf.id_proveedor = pr.id_proveedor;

-- Historial de costos de compra por producto (tabla y serie para gráficas):
-- costo real de cada ingreso, costo pactado en la OC y variación contra la
-- compra anterior del mismo producto
CREATE OR REPLACE VIEW v_historial_costo_compra AS
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
       LAG(l.lot_costo_unitario) OVER (PARTITION BY v.id_variante ORDER BY m.mov_fechahora, dm.id_detalle_movimiento)
                                                                AS costo_anterior,
       ROUND((l.lot_costo_unitario - LAG(l.lot_costo_unitario) OVER (PARTITION BY v.id_variante ORDER BY m.mov_fechahora, dm.id_detalle_movimiento)) * 100
             / NULLIF(LAG(l.lot_costo_unitario) OVER (PARTITION BY v.id_variante ORDER BY m.mov_fechahora, dm.id_detalle_movimiento), 0), 2)
                                                                AS variacion_pct
FROM detalle_movimiento dm
JOIN movimiento_inventario m    ON m.id_movimiento   = dm.id_movimiento AND m.id_tipo_movimiento = 'COM'
JOIN lote                  l    ON l.id_lote         = dm.id_lote
JOIN variante              v    ON v.id_variante     = l.id_variante
JOIN producto              p    ON p.id_producto     = v.id_producto
JOIN orden_compra          oc   ON oc.id_orden_compra = m.id_orden_compra
JOIN proveedor             pr   ON pr.id_proveedor   = oc.id_proveedor
JOIN detalle_orden_compra  dco  ON dco.id_detalle_orden_compra = dm.id_detalle_orden_compra
LEFT JOIN comprobante_compra fp ON fp.id_comprobante_compra = m.id_comprobante_compra;

-- Historial de precios de venta por presentación (vigente, anteriores y programados)
CREATE OR REPLACE VIEW v_historial_precio_venta AS
SELECT v.var_sku,
       p.prd_nombre,
       pr.id_presentacion,
       pr.pre_descripcion                                            AS presentacion,
       hp.hpr_precio                                                 AS precio,
       ROUND(hp.hpr_precio * (1 + t.tiv_porcentaje / 100), 2)        AS precio_con_iva,
       hp.hpr_vigente_desde                                          AS vigente_desde,
       LEAD(hp.hpr_vigente_desde) OVER (PARTITION BY hp.id_presentacion
                                        ORDER BY hp.hpr_vigente_desde) AS vigente_hasta,
       CASE WHEN hp.hpr_vigente_desde > LOCALTIMESTAMP THEN 1 ELSE 0 END AS programado,
       CASE WHEN pv.vigente_desde = hp.hpr_vigente_desde THEN 1 ELSE 0 END AS vigente,
       u.usu_correo                                                  AS registrado_por
FROM historial_precio hp
JOIN presentacion pr ON pr.id_presentacion = hp.id_presentacion
JOIN variante     v  ON v.id_variante      = pr.id_variante
JOIN producto     p  ON p.id_producto      = v.id_producto
JOIN tarifa_iva   t  ON t.id_tarifa_iva    = p.id_tarifa_iva
JOIN usuario      u  ON u.id_usuario       = hp.id_usuario
LEFT JOIN v_precio_vigente pv ON pv.id_presentacion = hp.id_presentacion;

-- Cuentas por cobrar: crédito de ventas y avances, con saldo y vencimiento
CREATE OR REPLACE VIEW v_cuentas_por_cobrar AS
SELECT c.id_cuenta_por_cobrar,
       p.id_cliente,
       cl.cli_nombres || NVL2(cl.cli_apellidos, ' ' || cl.cli_apellidos, NULL) AS cliente,
       c.id_pedido,
       f.numero                                                    AS comprobante_venta,
       c.cxc_tipo                                                  AS tipo,
       ma.mav_nombre                                               AS motivo,
       c.cxc_concepto                                              AS concepto,
       c.cxc_fechahora                                             AS fecha,
       c.cxc_fecha_vencimiento                                     AS vencimiento,
       c.cxc_monto                                                 AS monto,
       NVL(a.abonado, 0)                                           AS abonado,
       c.cxc_monto - NVL(a.abonado, 0)                             AS saldo,
       CASE WHEN c.cxc_monto - NVL(a.abonado, 0) = 0          THEN 'PAGADA'
            WHEN c.cxc_fecha_vencimiento < TRUNC(SYSDATE)     THEN 'VENCIDA'
            ELSE 'PENDIENTE' END                                   AS estado,
       CASE WHEN c.cxc_monto - NVL(a.abonado, 0) > 0
            THEN GREATEST(TRUNC(SYSDATE) - c.cxc_fecha_vencimiento, 0)
            ELSE 0 END                                             AS dias_vencida
FROM cuenta_por_cobrar c
JOIN pedido  p  ON p.id_pedido   = c.id_pedido
JOIN cliente cl ON cl.id_cliente = p.id_cliente
LEFT JOIN (SELECT id_cuenta_por_cobrar, SUM(abo_monto) AS abonado
           FROM abono_cliente GROUP BY id_cuenta_por_cobrar) a ON a.id_cuenta_por_cobrar = c.id_cuenta_por_cobrar
LEFT JOIN motivo_avance ma ON ma.id_motivo_avance = c.id_motivo_avance
LEFT JOIN v_comprobante_venta f ON f.id_pedido = c.id_pedido AND f.estado_sri <> 'ANULADA';

-- Estado de cuenta por cliente (lo que debe por compras a crédito y avances)
CREATE OR REPLACE VIEW v_estado_cuenta_cliente AS
SELECT cl.id_cliente,
       cl.cli_nombres || NVL2(cl.cli_apellidos, ' ' || cl.cli_apellidos, NULL) AS cliente,
       cl.cli_limite_credito                                             AS limite_credito,
       NVL(SUM(CASE WHEN c.tipo = 'CREDITO' THEN c.saldo END), 0)        AS saldo_credito,
       NVL(SUM(CASE WHEN c.tipo = 'AVANCE'  THEN c.saldo END), 0)        AS saldo_avances,
       NVL(SUM(c.saldo), 0)                                              AS deuda_total,
       NVL(SUM(CASE WHEN c.estado = 'VENCIDA' THEN c.saldo END), 0)      AS deuda_vencida,
       cl.cli_limite_credito - NVL(SUM(c.saldo), 0)                      AS credito_disponible
FROM cliente cl
LEFT JOIN v_cuentas_por_cobrar c ON c.id_cliente = cl.id_cliente
GROUP BY cl.id_cliente, cl.cli_nombres, cl.cli_apellidos, cl.cli_limite_credito;

-- Cola del SRI: comprobantes electrónicos que aún no tienen autorización.
-- Desde 2026 la transmisión debe ser inmediata: el servicio de facturación
-- consulta esta vista (en Oracle no hay aviso automático como pg_notify).
CREATE OR REPLACE VIEW v_cola_sri AS
SELECT CAST('FACTURA' AS VARCHAR2(12))                               AS tipo,
       f.id_comprobante_venta                                        AS id,
       vf.numero,
       f.cve_clave_acceso                                            AS clave_acceso,
       f.cve_fechahora                                               AS emitido,
       f.cve_estado                                                  AS estado,
       ROUND((CAST(LOCALTIMESTAMP AS DATE) - CAST(f.cve_fechahora AS DATE)) * 1440) AS minutos_pendiente
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
       ROUND((CAST(LOCALTIMESTAMP AS DATE) - CAST(n.ncr_fechahora AS DATE)) * 1440)
FROM nota_credito n
JOIN v_nota_credito vn ON vn.id_nota_credito = n.id_nota_credito
WHERE n.ncr_estado IN ('PENDIENTE', 'RECHAZADA');

-- Ventas por presentación y vendedor (p. ej. cuánto se vendió a precio de banda)
CREATE OR REPLACE VIEW v_ventas_por_presentacion AS
SELECT TRUNC(f.fecha)         AS fecha,
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
GROUP BY TRUNC(f.fecha), f.vendedor, v.var_sku, pr.pre_descripcion;

-- Deudores: cuánto debe cada cliente, con sus identificaciones y teléfonos
-- para poder buscarlo (ver fn_buscar_deuda_cliente)
CREATE OR REPLACE VIEW v_deuda_cliente AS
SELECT e.id_cliente,
       e.cliente,
       (SELECT LISTAGG(DISTINCT df.dfa_identificacion, ', ') WITHIN GROUP (ORDER BY df.dfa_identificacion)
        FROM datos_facturacion df
        WHERE df.id_cliente = e.id_cliente AND df.dfa_activo = 1 AND df.id_tipo_identificacion <> '07') AS identificaciones,
       (SELECT LISTAGG(t.tel_numero, ', ') WITHIN GROUP (ORDER BY t.id_telefono)
        FROM telefono t WHERE t.id_cliente = e.id_cliente)                                          AS telefonos,
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
CREATE OR REPLACE VIEW v_estado_cuenta_movimientos AS
WITH m AS (
    SELECT p.id_cliente, c.cxc_fechahora AS fecha, 1 AS orden, c.id_cuenta_por_cobrar AS id_ref,
           CASE c.cxc_tipo
               WHEN 'CREDITO' THEN 'Crédito del comprobante ' || NVL(f.numero, '(sin comprobante)')
               ELSE 'Avance (' || ma.mav_nombre || '): ' || c.cxc_concepto
           END                                                   AS detalle,
           c.cxc_monto                                           AS cargo,
           0                                                     AS abono,
           c.cxc_fecha_vencimiento                               AS vencimiento
    FROM cuenta_por_cobrar c
    JOIN pedido p ON p.id_pedido = c.id_pedido
    LEFT JOIN motivo_avance ma ON ma.id_motivo_avance = c.id_motivo_avance
    LEFT JOIN v_comprobante_venta f ON f.id_pedido = c.id_pedido AND f.estado_sri <> 'ANULADA'
    UNION ALL
    SELECT p.id_cliente, a.abo_fechahora, 2, a.id_abono_cliente,
           CASE WHEN a.id_nota_credito IS NOT NULL
                THEN 'Compensación con la nota de crédito ' || n.numero
                ELSE 'Abono (' || mp.mpa_nombre || ')' || NVL2(a.abo_referencia, ' ref. ' || a.abo_referencia, NULL)
           END,
           0, a.abo_monto, NULL
    FROM abono_cliente a
    JOIN cuenta_por_cobrar c ON c.id_cuenta_por_cobrar = a.id_cuenta_por_cobrar
    JOIN pedido p ON p.id_pedido = c.id_pedido
    LEFT JOIN metodo_pago mp ON mp.id_metodo_pago = a.id_metodo_pago
    LEFT JOIN v_nota_credito n ON n.id_nota_credito = a.id_nota_credito
)
SELECT m.id_cliente,
       cl.cli_nombres || NVL2(cl.cli_apellidos, ' ' || cl.cli_apellidos, NULL) AS cliente,
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
CREATE OR REPLACE VIEW v_negociaciones AS
SELECT p.id_pedido,
       p.ped_fechahora                                                    AS fecha,
       p.id_canal_venta                                                   AS canal,
       cl.cli_nombres || NVL2(cl.cli_apellidos, ' ' || cl.cli_apellidos, NULL) AS cliente,
       NVL2(ev.id_usuario, ev.epl_nombres || ' ' || ev.epl_apellidos, '-')    AS vendedor,
       NVL2(ea.id_usuario, ea.epl_nombres || ' ' || ea.epl_apellidos, ua.usu_correo) AS autorizado_por,
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
CREATE OR REPLACE VIEW v_oferta AS
SELECT o.id_oferta,
       p.prd_codigo,
       p.prd_nombre,
       o.ofe_porcentaje                 AS porcentaje,
       o.ofe_descripcion                AS descripcion,
       o.ofe_desde                      AS desde,
       o.ofe_hasta                      AS hasta,
       CASE WHEN o.ofe_activa = 0                   THEN 'PAUSADA'
            WHEN o.ofe_desde > LOCALTIMESTAMP       THEN 'PROGRAMADA'
            WHEN o.ofe_hasta <= LOCALTIMESTAMP      THEN 'FINALIZADA'
            ELSE 'VIGENTE' END          AS estado,
       NVL(u.lineas, 0)                 AS lineas_vendidas,
       NVL(u.descuento, 0)              AS descuento_otorgado,
       us.usu_correo                    AS registrada_por
FROM oferta o
JOIN producto p  ON p.id_producto = o.id_producto
JOIN usuario  us ON us.id_usuario = o.id_usuario_registra
LEFT JOIN (SELECT id_oferta, COUNT(*) AS lineas, SUM(descuento_oferta) AS descuento
           FROM v_detalle_pedido_valor WHERE id_oferta IS NOT NULL
           GROUP BY id_oferta) u ON u.id_oferta = o.id_oferta;

-- Catálogo (tienda y e-commerce): precio vigente, oferta y disponibilidad por presentación
CREATE OR REPLACE VIEW v_catalogo AS
SELECT p.id_producto,
       p.prd_codigo,
       p.prd_nombre,
       c.cat_nombre                                            AS categoria,
       v.id_variante,
       v.var_sku,
       (SELECT LISTAGG(a.atr_nombre || ': ' || va.val_valor, ', ') WITHIN GROUP (ORDER BY a.atr_nombre)
        FROM variante_valor vv
        JOIN valor_atributo va ON va.id_valor_atributo = vv.id_valor_atributo
        JOIN atributo       a  ON a.id_atributo        = vv.id_atributo
        WHERE vv.id_variante = v.id_variante)                  AS caracteristicas,
       pr.id_presentacion,
       pr.pre_descripcion                                      AS presentacion,
       pr.pre_cantidad_minima                                  AS cantidad_minima,
       pv.precio,
       t.tiv_porcentaje                                        AS iva_porcentaje,
       ROUND(pv.precio * (1 + t.tiv_porcentaje / 100), 2)      AS precio_con_iva,
       ov.id_oferta,
       ov.ofe_porcentaje                                       AS pct_oferta,
       ov.ofe_hasta                                            AS oferta_hasta,
       ROUND(pv.precio * (1 - NVL(ov.ofe_porcentaje, 0) / 100), 2) AS precio_final,
       ROUND(ROUND(pv.precio * (1 - NVL(ov.ofe_porcentaje, 0) / 100), 2)
             * (1 + t.tiv_porcentaje / 100), 2)                AS precio_final_con_iva,
       -- en productos por pieza, lo máximo que se puede pedir en una línea
       -- es lo que tiene la pieza más grande
       FLOOR(GREATEST(CASE WHEN p.prd_venta_por_pieza = 1
                           THEN LEAST(s.disponible, NVL((SELECT MAX(ls.saldo) FROM v_lote_saldo ls
                                                         WHERE ls.id_variante = v.id_variante), 0))
                           ELSE s.disponible END, 0) / pr.pre_factor) AS disponible,
       CASE WHEN p.prd_fecha_creacion >= TRUNC(SYSDATE) - 30 THEN 1 ELSE 0 END AS es_novedad,
       -- datos de vitrina para el e-commerce
       p.prd_imagen_url                                        AS imagen_url,
       p.prd_uso                                               AS uso,
       c.cat_codigo                                            AS categoria_codigo,
       NVL(cp.cat_codigo, c.cat_codigo)                        AS linea_codigo,
       NVL(cp.cat_nombre, c.cat_nombre)                        AS linea,
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
WHERE p.prd_publicado = 1 AND v.var_activa = 1 AND pr.pre_activa = 1 AND c.cat_activa = 1;

-- Categorías principales (raíz: sin categoría padre, es decir, que no son
-- subcategoría de otra), con sus subcategorías directas, los productos
-- publicados de TODO su árbol (recorrido recursivo, sirve a cualquier
-- profundidad) y la imagen del primer producto como portada.
CREATE OR REPLACE VIEW v_categoria_principal AS
WITH arbol (id_raiz, id_categoria) AS (
    SELECT c.id_categoria, c.id_categoria
    FROM categoria c
    WHERE c.id_categoria_padre IS NULL AND c.cat_activa = 1
    UNION ALL
    SELECT a.id_raiz, h.id_categoria
    FROM arbol a
    JOIN categoria h ON h.id_categoria_padre = a.id_categoria
    WHERE h.cat_activa = 1
), publicados AS (
    SELECT DISTINCT a.id_raiz, v.id_producto, v.prd_codigo, v.imagen_url
    FROM arbol a
    JOIN categoria  c ON c.id_categoria = a.id_categoria
    JOIN v_catalogo v ON v.categoria_codigo = c.cat_codigo
)
SELECT r.id_categoria,
       r.cat_codigo                                            AS codigo,
       r.cat_nombre                                            AS nombre,
       (SELECT LISTAGG(s.cat_nombre, ' · ') WITHIN GROUP (ORDER BY s.cat_nombre)
        FROM categoria s
        WHERE s.id_categoria_padre = r.id_categoria AND s.cat_activa = 1) AS subcategorias,
       (SELECT COUNT(*) FROM publicados p WHERE p.id_raiz = r.id_categoria) AS productos,
       (SELECT MIN(p.imagen_url) KEEP (DENSE_RANK FIRST ORDER BY p.prd_codigo)
        FROM publicados p
        WHERE p.id_raiz = r.id_categoria AND p.imagen_url IS NOT NULL) AS imagen_url
FROM categoria r
WHERE r.id_categoria_padre IS NULL AND r.cat_activa = 1;


-- =====================================================================
-- C1. Control de permisos, bitácora y sesión
--     (van antes de los disparadores porque estos los usan)
--     En Oracle las funciones de PostgreSQL que devuelven VOID son
--     procedimientos con el mismo nombre: se llaman con EXEC o dentro de
--     un bloque BEGIN ... END. Las que hacen cambios y devuelven un valor
--     se llaman desde PL/SQL (v := fn_x(...)), no desde un SELECT.
-- =====================================================================

-- Permiso por rol. Error -20003 = sin permiso (insufficient_privilege en PostgreSQL)
CREATE OR REPLACE PROCEDURE fn_exigir_permiso(p_usuario IN NUMBER, p_permiso IN VARCHAR2) IS
    v_n      NUMBER;
    v_correo usuario.usu_correo%TYPE;
BEGIN
    SELECT COUNT(*) INTO v_n
    FROM usuario u
    JOIN usuario_rol ur ON ur.id_usuario = u.id_usuario
    JOIN rol_permiso rp ON rp.id_rol     = ur.id_rol
    JOIN permiso     pe ON pe.id_permiso = rp.id_permiso
    WHERE u.id_usuario = p_usuario AND u.usu_activo = 1 AND pe.per_codigo = p_permiso;
    IF v_n = 0 THEN
        SELECT MAX(usu_correo) INTO v_correo FROM usuario WHERE id_usuario = p_usuario;
        RAISE_APPLICATION_ERROR(-20003, 'El usuario ' || NVL(v_correo, TO_CHAR(p_usuario))
                                        || ' no tiene el permiso ' || p_permiso);
    END IF;
    -- Quien actúa queda en la sesión: la auditoría lo toma de aquí
    pk_sesion.fijar_usuario(p_usuario);
END fn_exigir_permiso;
/

-- Bitácora del sistema interno. Se registra dentro de la transacción del
-- proceso: si el proceso falla, su evento tampoco queda (los intentos
-- fallidos, como un acceso con clave errada, los registra la aplicación
-- con fn_registrar_acceso en su propia transacción).
-- p_detalle: texto JSON (por ejemplo '{"id_pedido": 5}')
CREATE OR REPLACE FUNCTION fn_log(p_nivel IN VARCHAR2, p_origen IN VARCHAR2, p_evento IN VARCHAR2,
                                  p_mensaje IN VARCHAR2, p_usuario IN NUMBER DEFAULT NULL,
                                  p_detalle IN CLOB DEFAULT NULL, p_ip IN VARCHAR2 DEFAULT NULL)
RETURN NUMBER IS
    v_id NUMBER;
BEGIN
    INSERT INTO log_evento (lev_nivel, lev_origen, lev_evento, lev_mensaje, id_usuario, lev_ip, lev_detalle)
    VALUES (p_nivel, p_origen, p_evento, SUBSTR(p_mensaje, 1, 500), p_usuario, p_ip, p_detalle)
    RETURNING id_log_evento INTO v_id;
    RETURN v_id;
END fn_log;
/

-- Atajo para registrar sin recoger el número del evento
CREATE OR REPLACE PROCEDURE pr_log(p_nivel IN VARCHAR2, p_origen IN VARCHAR2, p_evento IN VARCHAR2,
                                   p_mensaje IN VARCHAR2, p_usuario IN NUMBER DEFAULT NULL,
                                   p_detalle IN CLOB DEFAULT NULL, p_ip IN VARCHAR2 DEFAULT NULL) IS
    v_id NUMBER;
BEGIN
    v_id := fn_log(p_nivel, p_origen, p_evento, p_mensaje, p_usuario, p_detalle, p_ip);
END pr_log;
/

-- Usuario de la aplicación en la sesión, para cambios hechos directo en
-- las tablas (las funciones del flujo lo fijan solas)
CREATE OR REPLACE PROCEDURE fn_usuario_sesion(p_usuario IN NUMBER) IS
    v_n NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_n FROM usuario WHERE id_usuario = p_usuario AND usu_activo = 1;
    IF v_n = 0 THEN
        pr_error('El usuario ' || p_usuario || ' no existe o está inactivo');
    END IF;
    pk_sesion.fijar_usuario(p_usuario);
END fn_usuario_sesion;
/

-- Inicio de sesión del personal (la aplicación valida la clave y registra
-- aquí el resultado). Devuelve el usuario si el acceso vale.
-- p_exito: 1 clave correcta, 0 incorrecta
CREATE OR REPLACE FUNCTION fn_registrar_acceso(p_correo IN VARCHAR2, p_exito IN NUMBER, p_ip IN VARCHAR2 DEFAULT NULL)
RETURN NUMBER IS
    v_correo  usuario.usu_correo%TYPE := LOWER(TRIM(p_correo));
    v_usuario NUMBER;
    v_activo  NUMBER;
BEGIN
    SELECT MAX(id_usuario), MAX(usu_activo) INTO v_usuario, v_activo FROM usuario WHERE usu_correo = v_correo;
    IF p_exito = 1 AND v_activo = 1 THEN
        UPDATE usuario SET usu_ultimo_acceso = LOCALTIMESTAMP WHERE id_usuario = v_usuario;
        pr_log('INFO', 'SEGURIDAD', 'LOGIN_OK', 'Inicio de sesión de ' || v_correo, v_usuario, NULL, p_ip);
        RETURN v_usuario;
    END IF;
    pr_log('AVISO', 'SEGURIDAD',
           CASE WHEN v_activo = 0 THEN 'LOGIN_BLOQUEADO' ELSE 'LOGIN_FALLIDO' END,
           'Acceso rechazado para ' || v_correo, v_usuario, NULL, p_ip);
    RETURN NULL;
END fn_registrar_acceso;
/


-- =====================================================================
-- B. DISPARADORES
--    Reglas que se cumplen aunque se escriba directo en las tablas.
--    Diferencias con PostgreSQL:
--    · Un disparador de fila no puede leer la tabla que se está
--      modificando con UPDATE/DELETE (ORA-04091): las reglas que lo
--      necesitan (categorías sin ciclos, ofertas sin solapes) usan
--      disparadores compuestos que revisan al final de la sentencia.
--    · No hay aviso al servicio del SRI (pg_notify): el servicio
--      consulta la vista v_cola_sri.
-- =====================================================================

-- B1. Registros que nunca se editan ni se borran (bitácoras y kárdex)
-- (los genera el script: ver tr_*_inmutable al final de esta sección)

-- Cabecera del kárdex: inmutable, salvo asociar UNA vez el comprobante del
-- proveedor a una recepción que llegó sin él (el documento llega después)
CREATE OR REPLACE TRIGGER tr_movimiento_inmutable
BEFORE UPDATE OR DELETE ON movimiento_inventario
FOR EACH ROW
DECLARE
    v_n NUMBER;
BEGIN
    IF DELETING
       OR pk_util.distinto(:NEW.id_movimiento, :OLD.id_movimiento)
       OR pk_util.distinto(:NEW.id_tipo_movimiento, :OLD.id_tipo_movimiento)
       OR pk_util.distinto(:NEW.mov_fechahora, :OLD.mov_fechahora)
       OR pk_util.distinto(:NEW.id_usuario, :OLD.id_usuario)
       OR pk_util.distinto(:NEW.mov_motivo, :OLD.mov_motivo)
       OR pk_util.distinto(:NEW.id_orden_compra, :OLD.id_orden_compra)
       OR pk_util.distinto(:NEW.id_comprobante_venta, :OLD.id_comprobante_venta)
       OR pk_util.distinto(:NEW.id_nota_credito, :OLD.id_nota_credito)
       OR :NEW.id_comprobante_compra IS NULL THEN
        pr_error('Los registros de movimiento_inventario no se modifican ni se eliminan. Registre un ajuste de inventario.');
    END IF;
    IF :OLD.id_comprobante_compra IS NOT NULL THEN
        pr_error('La recepción ' || :OLD.id_movimiento || ' ya tiene asociado un comprobante del proveedor');
    END IF;
    IF :OLD.id_tipo_movimiento <> 'COM' THEN
        pr_error('Solo una recepción de compra lleva comprobante de proveedor');
    END IF;
    SELECT COUNT(*) INTO v_n
    FROM comprobante_compra fp JOIN orden_compra oc ON oc.id_proveedor = fp.id_proveedor
    WHERE fp.id_comprobante_compra = :NEW.id_comprobante_compra AND oc.id_orden_compra = :OLD.id_orden_compra;
    IF v_n = 0 THEN
        pr_error('La factura de proveedor no corresponde al proveedor de la OC ' || :OLD.id_orden_compra);
    END IF;
END;
/

-- B2. Un pedido solo se edita mientras está pendiente de pago
CREATE OR REPLACE PROCEDURE pr_exigir_pedido_editable(p_pedido IN NUMBER) IS
    v_estado VARCHAR2(3);
BEGIN
    SELECT MAX(id_estado_pedido) INTO v_estado FROM v_pedido_estado_actual WHERE id_pedido = p_pedido;
    IF v_estado IS NOT NULL AND v_estado <> 'PEN' THEN
        pr_error('El pedido ' || p_pedido || ' está en estado ' || v_estado || ' y ya no se puede modificar');
    END IF;
END pr_exigir_pedido_editable;
/

CREATE OR REPLACE TRIGGER tr_pedido_editable
BEFORE UPDATE OR DELETE ON pedido
FOR EACH ROW
BEGIN
    pr_exigir_pedido_editable(:OLD.id_pedido);
END;
/

CREATE OR REPLACE TRIGGER tr_detalle_pedido_editable
BEFORE INSERT OR UPDATE OR DELETE ON detalle_pedido
FOR EACH ROW
BEGIN
    pr_exigir_pedido_editable(CASE WHEN DELETING THEN :OLD.id_pedido ELSE :NEW.id_pedido END);
    IF UPDATING AND :NEW.id_pedido <> :OLD.id_pedido THEN
        pr_error('No se puede mover una línea a otro pedido');
    END IF;
END;
/

-- Descuentos de una línea:
--  · Oferta: la pone la base, la vigente del producto al crear el pedido
--    (en cualquier canal). No se elige ni se cambia: así, en el e-commerce
--    nadie puede inventar un descuento durante la compra.
--  · Negociado: solo en tienda o WhatsApp, lo autoriza alguien con el
--    permiso PRECIO_NEGOCIAR y parte del precio que ya tiene la oferta.
CREATE OR REPLACE TRIGGER tr_detalle_pedido_descuento
BEFORE INSERT OR UPDATE ON detalle_pedido
FOR EACH ROW
DECLARE
    v_vigente NUMBER;
    v_canal   VARCHAR2(3);
    v_pct     NUMBER;
    v_neto    NUMBER;
BEGIN
    IF INSERTING OR :NEW.id_presentacion <> :OLD.id_presentacion THEN
        SELECT MAX(ov.id_oferta) INTO v_vigente
        FROM presentacion pr
        JOIN variante v ON v.id_variante = pr.id_variante
        JOIN v_oferta_vigente ov ON ov.id_producto = v.id_producto
        WHERE pr.id_presentacion = :NEW.id_presentacion;
        IF INSERTING AND :NEW.id_oferta IS NOT NULL AND pk_util.distinto(:NEW.id_oferta, v_vigente) THEN
            pr_error('La oferta ' || :NEW.id_oferta || ' no está vigente para este producto: las ofertas las aplica el catálogo, no se eligen al comprar');
        END IF;
        :NEW.id_oferta := v_vigente;
    ELSIF pk_util.distinto(:NEW.id_oferta, :OLD.id_oferta) THEN
        pr_error('La oferta de una línea se fija al crear el pedido y no se cambia');
    END IF;

    IF :NEW.dpe_descuento > 0 THEN
        SELECT id_canal_venta INTO v_canal FROM pedido WHERE id_pedido = :NEW.id_pedido;
        IF v_canal = 'WEB' THEN
            pr_error('Los descuentos negociados solo se permiten en tienda o WhatsApp, no en el e-commerce');
        END IF;
        IF :NEW.id_usuario_descuento IS NULL THEN
            pr_error('Indique quién autorizó el descuento');
        END IF;
        fn_exigir_permiso(:NEW.id_usuario_descuento, 'PRECIO_NEGOCIAR');
        SELECT NVL(MAX(ofe_porcentaje), 0) INTO v_pct FROM oferta WHERE id_oferta = :NEW.id_oferta;
        v_neto := ROUND(:NEW.dpe_cantidad * :NEW.dpe_precio_unitario, 2)
                - ROUND(:NEW.dpe_cantidad * :NEW.dpe_precio_unitario * v_pct / 100, 2);
        IF :NEW.dpe_descuento > v_neto THEN
            pr_error('El descuento negociado (' || :NEW.dpe_descuento || ') supera el precio con oferta de la línea (' || v_neto || ')');
        END IF;
    END IF;
END;
/

-- El costo y la dirección del envío se fijan antes de pagar;
-- transportista y guía se pueden completar al despachar.
CREATE OR REPLACE TRIGGER tr_envio_editable
BEFORE INSERT OR UPDATE OR DELETE ON envio
FOR EACH ROW
DECLARE
    v_pedido NUMBER;
    v_estado VARCHAR2(3);
BEGIN
    IF UPDATING
       AND NOT pk_util.distinto(:NEW.id_pedido, :OLD.id_pedido)
       AND NOT pk_util.distinto(:NEW.id_direccion, :OLD.id_direccion)
       AND NOT pk_util.distinto(:NEW.env_costo, :OLD.env_costo)
       AND NOT pk_util.distinto(:NEW.id_tarifa_iva, :OLD.id_tarifa_iva) THEN
        RETURN;
    END IF;
    v_pedido := CASE WHEN DELETING THEN :OLD.id_pedido ELSE :NEW.id_pedido END;
    SELECT MAX(id_estado_pedido) INTO v_estado FROM v_pedido_estado_actual WHERE id_pedido = v_pedido;
    IF v_estado IS NOT NULL AND v_estado <> 'PEN' THEN
        pr_error('El costo y la dirección del envío del pedido ' || v_pedido || ' ya no se pueden cambiar (estado ' || v_estado || ')');
    END IF;
END;
/

-- B3. Transiciones válidas del pedido:
--     (nuevo) → PEN → PAG → FAC → DES → ENT     (FAC → ENT si se retira en tienda)
--     PEN/PAG → CAN
CREATE OR REPLACE TRIGGER tr_historial_estado_validar
BEFORE INSERT ON historial_estado_pedido
FOR EACH ROW
DECLARE
    v_bloqueo  NUMBER;
    v_actual   VARCHAR2(3);
    v_envio    NUMBER;
    v_cubierto NUMBER;
    v_total    NUMBER;
    v_n        NUMBER;
BEGIN
    SELECT id_pedido INTO v_bloqueo FROM pedido WHERE id_pedido = :NEW.id_pedido FOR UPDATE;
    SELECT MAX(id_estado_pedido) INTO v_actual FROM v_pedido_estado_actual WHERE id_pedido = :NEW.id_pedido;
    SELECT COUNT(*) INTO v_envio FROM envio WHERE id_pedido = :NEW.id_pedido;

    IF NOT (   (v_actual IS NULL AND :NEW.id_estado_pedido = 'PEN')
            OR (v_actual = 'PEN' AND :NEW.id_estado_pedido IN ('PAG', 'CAN'))
            OR (v_actual = 'PAG' AND :NEW.id_estado_pedido IN ('FAC', 'CAN'))
            OR (v_actual = 'FAC' AND :NEW.id_estado_pedido = 'DES' AND v_envio > 0)
            OR (v_actual = 'FAC' AND :NEW.id_estado_pedido = 'ENT' AND v_envio = 0)
            OR (v_actual = 'DES' AND :NEW.id_estado_pedido = 'ENT')) THEN
        pr_error('Transición no permitida en el pedido ' || :NEW.id_pedido || ': ' || NVL(v_actual, '(nuevo)')
                 || ' → ' || :NEW.id_estado_pedido || ' '
                 || CASE WHEN v_actual = 'FAC' AND v_envio > 0 THEN '(tiene envío: debe despacharse primero)'
                         WHEN v_actual = 'FAC' AND v_envio = 0 THEN '(sin envío: se entrega en tienda)' END);
    END IF;

    IF :NEW.id_estado_pedido = 'PAG' THEN
        SELECT cubierto INTO v_cubierto FROM v_pedido_pagos   WHERE id_pedido = :NEW.id_pedido;
        SELECT total    INTO v_total    FROM v_pedido_totales WHERE id_pedido = :NEW.id_pedido;
        IF v_cubierto < v_total THEN
            pr_error('Los pagos aprobados y el crédito no cubren el total del pedido ' || :NEW.id_pedido);
        END IF;
    END IF;

    IF :NEW.id_estado_pedido = 'CAN' THEN
        SELECT COUNT(*) INTO v_n FROM cuenta_por_cobrar WHERE id_pedido = :NEW.id_pedido AND cxc_tipo = 'CREDITO';
        IF v_n > 0 THEN
            pr_error('El pedido ' || :NEW.id_pedido || ' tiene crédito otorgado y no se puede cancelar');
        END IF;
    END IF;

    IF :NEW.id_estado_pedido = 'FAC' THEN
        SELECT COUNT(*) INTO v_n FROM comprobante_venta WHERE id_pedido = :NEW.id_pedido AND cve_estado <> 'ANULADA';
        IF v_n = 0 THEN
            pr_error('El pedido ' || :NEW.id_pedido || ' no tiene un comprobante emitido');
        END IF;
    END IF;
END;
/

-- B4. Cabecera del kárdex: origen coherente y sin fechas futuras
CREATE OR REPLACE TRIGGER tr_movimiento_validar
BEFORE INSERT ON movimiento_inventario
FOR EACH ROW
DECLARE
    v_estado    VARCHAR2(8);
    v_proveedor NUMBER;
    v_n         NUMBER;
BEGIN
    IF :NEW.mov_fechahora > LOCALTIMESTAMP + INTERVAL '1' MINUTE THEN
        pr_error('No se registran movimientos con fecha futura');
    END IF;
    IF :NEW.id_tipo_movimiento = 'COM' THEN
        SELECT MAX(oc_estado), MAX(id_proveedor) INTO v_estado, v_proveedor
        FROM orden_compra WHERE id_orden_compra = :NEW.id_orden_compra;
        IF NVL(v_estado, '-') <> 'EMITIDA' THEN
            pr_error('Solo se recibe mercadería de una OC emitida (OC ' || :NEW.id_orden_compra || ' en estado ' || v_estado || ')');
        END IF;
        IF :NEW.id_comprobante_compra IS NOT NULL THEN
            SELECT COUNT(*) INTO v_n FROM comprobante_compra
            WHERE id_comprobante_compra = :NEW.id_comprobante_compra AND id_proveedor = v_proveedor;
            IF v_n = 0 THEN
                pr_error('La factura de proveedor no corresponde al proveedor de la OC ' || :NEW.id_orden_compra);
            END IF;
        END IF;
    END IF;
END;
/

-- B5. Línea del kárdex: documento correcto, misma variante, lote nuevo en
--     cada ingreso y nunca saldo negativo
CREATE OR REPLACE TRIGGER tr_detalle_movimiento_validar
BEFORE INSERT ON detalle_movimiento
FOR EACH ROW
DECLARE
    v_tipo      VARCHAR2(3);
    v_oc        NUMBER;
    v_comp      NUMBER;
    v_nc        NUMBER;
    v_signo     NUMBER;
    v_var_lote  NUMBER;
    v_origen    NUMBER;
    v_var_doc   NUMBER;
    v_con_movs  NUMBER;
    v_saldo     NUMBER;
    v_n         NUMBER;
BEGIN
    SELECT mi.id_tipo_movimiento, mi.id_orden_compra, mi.id_comprobante_venta, mi.id_nota_credito, t.tmv_signo
      INTO v_tipo, v_oc, v_comp, v_nc, v_signo
    FROM movimiento_inventario mi
    JOIN tipo_movimiento t ON t.id_tipo_movimiento = mi.id_tipo_movimiento
    WHERE mi.id_movimiento = :NEW.id_movimiento;

    SELECT id_variante, id_lote_origen INTO v_var_lote, v_origen FROM lote WHERE id_lote = :NEW.id_lote FOR UPDATE;
    SELECT COUNT(*) INTO v_con_movs FROM detalle_movimiento WHERE id_lote = :NEW.id_lote AND ROWNUM = 1;

    -- 1) Cada tipo referencia la línea de su documento
    IF v_tipo = 'COM' THEN
        SELECT MAX(id_variante) INTO v_var_doc FROM detalle_orden_compra
        WHERE id_detalle_orden_compra = :NEW.id_detalle_orden_compra AND id_orden_compra = v_oc;
        IF v_var_doc IS NULL THEN
            pr_error('La recepción debe referenciar una línea de la OC ' || v_oc);
        END IF;
    ELSIF v_tipo = 'VEN' THEN
        SELECT MAX(pr.id_variante) INTO v_var_doc
        FROM detalle_pedido d
        JOIN presentacion pr ON pr.id_presentacion = d.id_presentacion
        JOIN comprobante_venta f ON f.id_pedido = d.id_pedido
        WHERE d.id_detalle_pedido = :NEW.id_detalle_pedido AND f.id_comprobante_venta = v_comp;
        IF v_var_doc IS NULL THEN
            pr_error('El despacho debe referenciar una línea del pedido con comprobante');
        END IF;
    ELSIF v_tipo = 'DCL' THEN
        SELECT MAX(pr.id_variante) INTO v_var_doc
        FROM detalle_nota_credito dn
        JOIN detalle_pedido d ON d.id_detalle_pedido = dn.id_detalle_pedido
        JOIN presentacion  pr ON pr.id_presentacion  = d.id_presentacion
        WHERE dn.id_detalle_nota_credito = :NEW.id_detalle_nota_credito AND dn.id_nota_credito = v_nc;
        IF v_var_doc IS NULL THEN
            pr_error('La devolución debe referenciar una línea de la nota de crédito');
        END IF;
    ELSE
        IF :NEW.id_detalle_orden_compra IS NOT NULL OR :NEW.id_detalle_pedido IS NOT NULL
           OR :NEW.id_detalle_nota_credito IS NOT NULL THEN
            pr_error('Los movimientos ' || v_tipo || ' no referencian líneas de documentos');
        END IF;
        v_var_doc := v_var_lote;
    END IF;

    IF v_var_doc <> v_var_lote THEN
        pr_error('El lote ' || :NEW.id_lote || ' no pertenece a la variante del documento');
    END IF;

    -- 2) Todo ingreso nuevo (compra, inicial, ajuste +, paquete) abre su
    --    propio lote; solo un fraccionamiento crea lotes con pieza de
    --    origen; la devolución de cliente vuelve a un lote existente
    IF v_tipo IN ('COM', 'INI', 'AJP', 'FRE') AND v_con_movs > 0 THEN
        pr_error('Cada ingreso (' || v_tipo || ') debe crear su propio lote');
    END IF;
    IF v_con_movs = 0 AND ((v_tipo = 'FRE' AND v_origen IS NULL) OR (v_tipo <> 'FRE' AND v_origen IS NOT NULL)) THEN
        pr_error('Solo un fraccionamiento (FRE) crea lotes con pieza de origen');
    END IF;
    IF v_tipo = 'DCL' AND v_con_movs = 0 THEN
        pr_error('La devolución de cliente debe regresar a un lote existente');
    END IF;

    -- 3) La devolución a proveedor sale de un lote de esa misma OC
    IF v_tipo = 'DPR' THEN
        SELECT COUNT(*) INTO v_n
        FROM detalle_movimiento dm
        JOIN movimiento_inventario mi ON mi.id_movimiento = dm.id_movimiento
        WHERE dm.id_lote = :NEW.id_lote AND mi.id_tipo_movimiento = 'COM' AND mi.id_orden_compra = v_oc;
        IF v_n = 0 THEN
            pr_error('El lote ' || :NEW.id_lote || ' no fue recibido en la OC ' || v_oc);
        END IF;
    END IF;

    -- 4) Ninguna salida deja el lote en negativo
    IF v_signo = -1 THEN
        SELECT NVL(SUM(dm.dmo_cantidad * t.tmv_signo), 0) INTO v_saldo
        FROM detalle_movimiento dm
        JOIN movimiento_inventario mi ON mi.id_movimiento = dm.id_movimiento
        JOIN tipo_movimiento t        ON t.id_tipo_movimiento = mi.id_tipo_movimiento
        WHERE dm.id_lote = :NEW.id_lote;
        IF v_saldo < :NEW.dmo_cantidad THEN
            pr_error('Stock insuficiente en el lote ' || :NEW.id_lote || ' (saldo ' || TO_CHAR(v_saldo, 'FM999999990.000')
                     || ', se requieren ' || TO_CHAR(:NEW.dmo_cantidad, 'FM999999990.000') || ')');
        END IF;
    END IF;
END;
/

-- B6. Comprobante de venta y nota de crédito: solo cambian su estado y los
--     datos de autorización del SRI
CREATE OR REPLACE TRIGGER tr_comprobante_venta_protegido
BEFORE UPDATE OR DELETE ON comprobante_venta
FOR EACH ROW
DECLARE
    v_tipo_id VARCHAR2(2);
BEGIN
    IF DELETING THEN
        pr_error('Los comprobantes de venta no se eliminan; se anulan o se corrigen con nota de crédito');
    END IF;
    IF pk_util.distinto(:NEW.id_tipo_comprobante, :OLD.id_tipo_comprobante)
       OR pk_util.distinto(:NEW.id_pedido, :OLD.id_pedido)
       OR pk_util.distinto(:NEW.id_datos_facturacion, :OLD.id_datos_facturacion)
       OR pk_util.distinto(:NEW.id_punto_emision, :OLD.id_punto_emision)
       OR pk_util.distinto(:NEW.cve_secuencial, :OLD.cve_secuencial)
       OR pk_util.distinto(:NEW.cve_fechahora, :OLD.cve_fechahora)
       OR pk_util.distinto(:NEW.id_usuario_emite, :OLD.id_usuario_emite) THEN
        pr_error('De un comprobante emitido solo se actualizan su estado y los datos de autorización del SRI');
    END IF;
    IF :NEW.cve_estado = 'ANULADA' AND :OLD.cve_estado <> 'ANULADA' AND :NEW.id_tipo_comprobante = '01' THEN
        SELECT MAX(id_tipo_identificacion) INTO v_tipo_id FROM datos_facturacion
        WHERE id_datos_facturacion = :NEW.id_datos_facturacion;
        IF v_tipo_id = '07' THEN
            pr_error('Una factura a consumidor final no se anula una vez transmitida al SRI (regla vigente desde 2026)');
        END IF;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER tr_nota_credito_protegida
BEFORE UPDATE OR DELETE ON nota_credito
FOR EACH ROW
BEGIN
    IF DELETING THEN
        pr_error('Las notas de crédito no se eliminan');
    END IF;
    IF pk_util.distinto(:NEW.id_comprobante_venta, :OLD.id_comprobante_venta)
       OR pk_util.distinto(:NEW.id_punto_emision, :OLD.id_punto_emision)
       OR pk_util.distinto(:NEW.ncr_secuencial, :OLD.ncr_secuencial)
       OR pk_util.distinto(:NEW.ncr_fechahora, :OLD.ncr_fechahora)
       OR pk_util.distinto(:NEW.id_motivo_devolucion, :OLD.id_motivo_devolucion)
       OR pk_util.distinto(:NEW.id_usuario_autoriza, :OLD.id_usuario_autoriza)
       OR pk_util.distinto(:NEW.ncr_observacion, :OLD.ncr_observacion) THEN
        pr_error('De una nota de crédito emitida solo se actualizan los datos de autorización del SRI');
    END IF;
END;
/

-- B7. Datos usados en documentos no se editan: se desactivan y se crea otro registro
CREATE OR REPLACE TRIGGER tr_datos_facturacion_inmutable
BEFORE UPDATE ON datos_facturacion
FOR EACH ROW
DECLARE
    v_n NUMBER;
BEGIN
    IF pk_util.distinto(:NEW.id_cliente, :OLD.id_cliente)
       OR pk_util.distinto(:NEW.id_tipo_identificacion, :OLD.id_tipo_identificacion)
       OR pk_util.distinto(:NEW.dfa_identificacion, :OLD.dfa_identificacion)
       OR pk_util.distinto(:NEW.dfa_razon_social, :OLD.dfa_razon_social)
       OR pk_util.distinto(:NEW.dfa_correo, :OLD.dfa_correo)
       OR pk_util.distinto(:NEW.id_direccion, :OLD.id_direccion) THEN
        SELECT COUNT(*) INTO v_n FROM comprobante_venta WHERE id_datos_facturacion = :OLD.id_datos_facturacion;
        IF v_n > 0 THEN
            pr_error('Estos datos ya constan en una factura: desactívelos y registre unos nuevos');
        END IF;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER tr_direccion_inmutable
BEFORE UPDATE ON direccion
FOR EACH ROW
DECLARE
    v_n NUMBER;
BEGIN
    IF pk_util.distinto(:NEW.id_cliente, :OLD.id_cliente)
       OR pk_util.distinto(:NEW.id_ciudad, :OLD.id_ciudad)
       OR pk_util.distinto(:NEW.dir_calle_principal, :OLD.dir_calle_principal)
       OR pk_util.distinto(:NEW.dir_numero, :OLD.dir_numero)
       OR pk_util.distinto(:NEW.dir_calle_secundaria, :OLD.dir_calle_secundaria)
       OR pk_util.distinto(:NEW.dir_referencia, :OLD.dir_referencia) THEN
        SELECT COUNT(*) INTO v_n FROM dual
        WHERE EXISTS (SELECT 1 FROM envio WHERE id_direccion = :OLD.id_direccion)
           OR EXISTS (SELECT 1 FROM datos_facturacion df
                      JOIN comprobante_venta f ON f.id_datos_facturacion = df.id_datos_facturacion
                      WHERE df.id_direccion = :OLD.id_direccion);
        IF v_n > 0 THEN
            pr_error('La dirección ya se usó en un envío o factura: desactívela y registre una nueva');
        END IF;
    END IF;
END;
/

-- B8. Catálogo: categorías sin ciclos (se revisa al final de la sentencia,
--     cuando la tabla ya se puede leer) y atributos acordes a la categoría
CREATE OR REPLACE TRIGGER tr_categoria_sin_ciclos
FOR UPDATE OF id_categoria_padre ON categoria
COMPOUND TRIGGER
    TYPE t_ids IS TABLE OF NUMBER;
    g_ids t_ids := t_ids();

    AFTER EACH ROW IS
    BEGIN
        IF :NEW.id_categoria_padre IS NOT NULL THEN
            g_ids.EXTEND;
            g_ids(g_ids.COUNT) := :NEW.id_categoria;
        END IF;
    END AFTER EACH ROW;

    AFTER STATEMENT IS
        v_n      NUMBER;
        v_codigo VARCHAR2(20);
    BEGIN
        FOR i IN 1 .. g_ids.COUNT LOOP
            SELECT COUNT(*) INTO v_n
            FROM (SELECT id_categoria FROM categoria
                  START WITH id_categoria = (SELECT id_categoria_padre FROM categoria WHERE id_categoria = g_ids(i))
                  CONNECT BY NOCYCLE id_categoria = PRIOR id_categoria_padre)
            WHERE id_categoria = g_ids(i);
            IF v_n > 0 THEN
                SELECT cat_codigo INTO v_codigo FROM categoria WHERE id_categoria = g_ids(i);
                pr_error('La categoría ' || v_codigo || ' no puede depender de una de sus subcategorías');
            END IF;
        END LOOP;
    END AFTER STATEMENT;
END tr_categoria_sin_ciclos;
/

CREATE OR REPLACE TRIGGER tr_variante_valor_validar
BEFORE INSERT OR UPDATE ON variante_valor
FOR EACH ROW
DECLARE
    v_n NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_n
    FROM categoria_atributo ca
    WHERE ca.id_atributo = :NEW.id_atributo
      AND ca.id_categoria IN (
          SELECT c.id_categoria FROM categoria c
          START WITH c.id_categoria = (SELECT p.id_categoria FROM producto p
                                       JOIN variante v ON v.id_producto = p.id_producto
                                       WHERE v.id_variante = :NEW.id_variante)
          CONNECT BY NOCYCLE c.id_categoria = PRIOR c.id_categoria_padre);
    IF v_n = 0 THEN
        pr_error('El atributo ' || :NEW.id_atributo || ' no está definido para la categoría del producto (ni para sus categorías padre)');
    END IF;
END;
/

-- B9. Compras: OC editable solo en borrador y transiciones de estado válidas
CREATE OR REPLACE TRIGGER tr_orden_compra_validar
BEFORE UPDATE OR DELETE ON orden_compra
FOR EACH ROW
DECLARE
    v_n NUMBER;
BEGIN
    IF DELETING THEN
        IF :OLD.oc_estado <> 'BORRADOR' THEN
            pr_error('Solo se elimina una OC en borrador; anúlela');
        END IF;
        RETURN;
    END IF;

    IF :OLD.oc_estado <> 'BORRADOR'
       AND (pk_util.distinto(:NEW.id_proveedor, :OLD.id_proveedor)
            OR pk_util.distinto(:NEW.oc_fecha, :OLD.oc_fecha)
            OR pk_util.distinto(:NEW.oc_fecha_entrega_esperada, :OLD.oc_fecha_entrega_esperada)
            OR pk_util.distinto(:NEW.id_usuario_crea, :OLD.id_usuario_crea)) THEN
        pr_error('La OC ' || :OLD.id_orden_compra || ' ya fue emitida y no se puede modificar');
    END IF;

    IF :NEW.oc_estado <> :OLD.oc_estado THEN
        IF NOT (   (:OLD.oc_estado = 'BORRADOR' AND :NEW.oc_estado IN ('EMITIDA', 'ANULADA'))
                OR (:OLD.oc_estado = 'EMITIDA'  AND :NEW.oc_estado IN ('CERRADA', 'ANULADA'))) THEN
            pr_error('Transición no permitida en la OC ' || :OLD.id_orden_compra || ': ' || :OLD.oc_estado || ' → ' || :NEW.oc_estado);
        END IF;
        IF :NEW.oc_estado = 'EMITIDA' THEN
            SELECT COUNT(*) INTO v_n FROM detalle_orden_compra WHERE id_orden_compra = :NEW.id_orden_compra;
            IF v_n = 0 THEN
                pr_error('La OC ' || :NEW.id_orden_compra || ' no tiene líneas');
            END IF;
        END IF;
        IF :NEW.oc_estado = 'ANULADA' THEN
            SELECT COUNT(*) INTO v_n FROM movimiento_inventario WHERE id_orden_compra = :NEW.id_orden_compra;
            IF v_n > 0 THEN
                pr_error('La OC ' || :NEW.id_orden_compra || ' ya tiene recepciones: ciérrela en lugar de anularla');
            END IF;
        END IF;
    END IF;
END;
/

CREATE OR REPLACE TRIGGER tr_detalle_oc_editable
BEFORE INSERT OR UPDATE OR DELETE ON detalle_orden_compra
FOR EACH ROW
DECLARE
    v_estado VARCHAR2(8);
    v_id_oc  NUMBER;
BEGIN
    -- DELETING/INSERTING/UPDATING son de PL/SQL: no se pueden usar dentro
    -- del WHERE de un SELECT embebido (eso lo evalúa el motor SQL, que no
    -- las conoce). Se resuelve antes, en PL/SQL puro.
    IF DELETING THEN
        v_id_oc := :OLD.id_orden_compra;
    ELSE
        v_id_oc := :NEW.id_orden_compra;
    END IF;
    SELECT oc_estado INTO v_estado FROM orden_compra
    WHERE id_orden_compra = v_id_oc;
    IF v_estado <> 'BORRADOR' THEN
        pr_error('Las líneas de una OC solo se editan en borrador (estado actual: ' || v_estado || ')');
    END IF;
END;
/

-- B10. Topes: no pagar más de lo que dice el comprobante del proveedor ni
--      reembolsar más que la nota de crédito
CREATE OR REPLACE TRIGGER tr_pago_proveedor_tope
BEFORE INSERT ON pago_proveedor
FOR EACH ROW
DECLARE
    v_bloqueo NUMBER;
    v_saldo   NUMBER;
BEGIN
    SELECT id_comprobante_compra INTO v_bloqueo FROM comprobante_compra
    WHERE id_comprobante_compra = :NEW.id_comprobante_compra FOR UPDATE;
    SELECT saldo INTO v_saldo FROM v_cuentas_por_pagar WHERE id_comprobante_compra = :NEW.id_comprobante_compra;
    IF :NEW.ppr_monto > v_saldo THEN
        pr_error('El pago (' || :NEW.ppr_monto || ') supera el saldo pendiente de la factura (' || v_saldo || ')');
    END IF;
END;
/

CREATE OR REPLACE TRIGGER tr_reembolso_tope
BEFORE INSERT ON reembolso
FOR EACH ROW
DECLARE
    v_bloqueo     NUMBER;
    v_total       NUMBER;
    v_reembolsado NUMBER;
    v_aplicado    NUMBER;
BEGIN
    SELECT id_nota_credito INTO v_bloqueo FROM nota_credito WHERE id_nota_credito = :NEW.id_nota_credito FOR UPDATE;
    SELECT total INTO v_total FROM v_nota_credito WHERE id_nota_credito = :NEW.id_nota_credito;
    SELECT NVL(SUM(ree_monto), 0) INTO v_reembolsado FROM reembolso WHERE id_nota_credito = :NEW.id_nota_credito;
    SELECT NVL(SUM(abo_monto), 0) INTO v_aplicado FROM abono_cliente WHERE id_nota_credito = :NEW.id_nota_credito;
    IF v_reembolsado + v_aplicado + :NEW.ree_monto > v_total THEN
        pr_error('El reembolso supera lo disponible de la nota de crédito (total ' || v_total || ', reembolsado '
                 || v_reembolsado || ', compensado con deudas ' || v_aplicado || ')');
    END IF;
END;
/

-- Nota de crédito del proveedor: no sobre un recibo, número único por
-- proveedor, fecha no anterior al comprobante y sin acreditar de más
CREATE OR REPLACE TRIGGER tr_nota_credito_proveedor_validar
BEFORE INSERT ON nota_credito_proveedor
FOR EACH ROW
DECLARE
    v_tipo      CHAR(2);
    v_proveedor NUMBER;
    v_fecha     DATE;
    v_total     NUMBER;
    v_previo    NUMBER;
    v_n         NUMBER;
    v_nueva     NUMBER := :NEW.ncp_subtotal_0 + :NEW.ncp_subtotal_gravado + :NEW.ncp_iva;
BEGIN
    SELECT id_tipo_comprobante, id_proveedor, cco_fecha_emision, cco_subtotal_0 + cco_subtotal_gravado + cco_iva
      INTO v_tipo, v_proveedor, v_fecha, v_total
    FROM comprobante_compra WHERE id_comprobante_compra = :NEW.id_comprobante_compra FOR UPDATE;
    IF v_tipo = '00' THEN
        pr_error('Una compra sin comprobante (recibo) no admite nota de crédito del proveedor: registre la devolución y ajuste con el proveedor');
    END IF;
    SELECT COUNT(*) INTO v_n
    FROM nota_credito_proveedor n
    JOIN comprobante_compra f ON f.id_comprobante_compra = n.id_comprobante_compra
    WHERE f.id_proveedor = v_proveedor AND n.ncp_numero = :NEW.ncp_numero;
    IF v_n > 0 THEN
        pr_error('El proveedor ya tiene registrada la nota de crédito ' || :NEW.ncp_numero);
    END IF;
    IF :NEW.ncp_fecha_emision < v_fecha THEN
        pr_error('La nota de crédito no puede ser anterior al comprobante que modifica');
    END IF;
    SELECT NVL(SUM(ncp_subtotal_0 + ncp_subtotal_gravado + ncp_iva), 0) INTO v_previo
    FROM nota_credito_proveedor WHERE id_comprobante_compra = :NEW.id_comprobante_compra;
    IF v_previo + v_nueva > v_total THEN
        pr_error('La nota de crédito (' || v_nueva || ') supera lo facturado que queda por acreditar (' || (v_total - v_previo) || ')');
    END IF;
END;
/

-- Comprobante de compra: el tipo debe servir para compras. Factura y nota
-- de venta llevan el número SRI (001-001-000000123); la clave de acceso
-- (49 dígitos) solo existe en una factura electrónica.
CREATE OR REPLACE TRIGGER tr_comprobante_compra_validar
BEFORE INSERT OR UPDATE ON comprobante_compra
FOR EACH ROW
DECLARE
    v_n NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_n FROM tipo_comprobante
    WHERE id_tipo_comprobante = :NEW.id_tipo_comprobante AND tco_en_compra = 1;
    IF v_n = 0 THEN
        pr_error('El tipo de comprobante ' || :NEW.id_tipo_comprobante || ' no se usa en compras');
    END IF;
    IF :NEW.id_tipo_comprobante IN ('01', '02') AND NOT REGEXP_LIKE(:NEW.cco_numero, '^[0-9]{3}-[0-9]{3}-[0-9]{9}$') THEN
        pr_error('El número ' || :NEW.cco_numero || ' no tiene el formato del SRI (001-001-000000123)');
    END IF;
    IF :NEW.cco_clave_acceso IS NOT NULL AND NOT REGEXP_LIKE(:NEW.cco_clave_acceso, '^[0-9]{49}$') THEN
        pr_error('La clave de acceso debe tener 49 dígitos');
    END IF;
END;
/

-- Cuenta por cobrar: cliente identificado, momento correcto del pedido y
-- límite de crédito. CREDITO solo sobre un pedido pendiente (se emite el
-- comprobante en la misma operación); AVANCE solo sobre una compra con comprobante.
CREATE OR REPLACE TRIGGER tr_cuenta_por_cobrar_validar
BEFORE INSERT ON cuenta_por_cobrar
FOR EACH ROW
DECLARE
    v_cliente  NUMBER;
    v_estado   VARCHAR2(3);
    v_limite   NUMBER;
    v_deuda    NUMBER;
    v_total    NUMBER;
    v_cubierto NUMBER;
    v_n        NUMBER;
BEGIN
    SELECT id_cliente INTO v_cliente FROM pedido WHERE id_pedido = :NEW.id_pedido FOR UPDATE;
    SELECT MAX(id_estado_pedido) INTO v_estado FROM v_pedido_estado_actual WHERE id_pedido = :NEW.id_pedido;

    SELECT COUNT(*) INTO v_n FROM datos_facturacion
    WHERE id_cliente = v_cliente AND dfa_activo = 1 AND id_tipo_identificacion <> '07';
    IF v_n = 0 THEN
        pr_error('Crédito y avances solo para clientes identificados (cédula, RUC o pasaporte), no para consumidor final');
    END IF;
    IF :NEW.cxc_fecha_vencimiento < TRUNC(SYSDATE) THEN
        pr_error('El vencimiento no puede ser anterior a hoy');
    END IF;

    IF :NEW.cxc_tipo = 'CREDITO' THEN
        IF NVL(v_estado, '-') <> 'PEN' THEN
            pr_error('El crédito se otorga sobre un pedido pendiente, al facturarlo (pedido ' || :NEW.id_pedido
                     || ' en estado ' || NVL(v_estado, '-') || ')');
        END IF;
        SELECT total    INTO v_total    FROM v_pedido_totales WHERE id_pedido = :NEW.id_pedido;
        SELECT cubierto INTO v_cubierto FROM v_pedido_pagos   WHERE id_pedido = :NEW.id_pedido;
        IF :NEW.cxc_monto > v_total - v_cubierto THEN
            pr_error('El crédito (' || :NEW.cxc_monto || ') supera el saldo por pagar del pedido (' || (v_total - v_cubierto) || ')');
        END IF;
    ELSIF v_estado IS NULL OR v_estado NOT IN ('FAC', 'DES', 'ENT') THEN
        pr_error('El avance se entrega sobre una compra ya facturada (pedido ' || :NEW.id_pedido
                 || ' en estado ' || NVL(v_estado, '-') || ')');
    END IF;

    SELECT cli_limite_credito INTO v_limite FROM cliente WHERE id_cliente = v_cliente FOR UPDATE;
    SELECT deuda_total INTO v_deuda FROM v_estado_cuenta_cliente WHERE id_cliente = v_cliente;
    IF v_deuda + :NEW.cxc_monto > v_limite THEN
        pr_error('Supera el límite de crédito del cliente (límite ' || v_limite || ', deuda actual ' || v_deuda
                 || ', solicitado ' || :NEW.cxc_monto || ')');
    END IF;
END;
/

-- Abono: no supera el saldo de la cuenta; si compensa una nota de crédito,
-- esta debe ser del mismo cliente y tener valor disponible
CREATE OR REPLACE TRIGGER tr_abono_validar
BEFORE INSERT ON abono_cliente
FOR EACH ROW
DECLARE
    v_bloqueo    NUMBER;
    v_saldo      NUMBER;
    v_cliente    NUMBER;
    v_cliente_nc NUMBER;
    v_disponible NUMBER;
BEGIN
    SELECT id_cuenta_por_cobrar INTO v_bloqueo FROM cuenta_por_cobrar
    WHERE id_cuenta_por_cobrar = :NEW.id_cuenta_por_cobrar FOR UPDATE;
    SELECT saldo, id_cliente INTO v_saldo, v_cliente
    FROM v_cuentas_por_cobrar WHERE id_cuenta_por_cobrar = :NEW.id_cuenta_por_cobrar;
    IF :NEW.abo_monto > v_saldo THEN
        pr_error('El abono (' || :NEW.abo_monto || ') supera el saldo de la cuenta (' || v_saldo || ')');
    END IF;

    IF :NEW.id_nota_credito IS NOT NULL THEN
        SELECT id_nota_credito INTO v_bloqueo FROM nota_credito WHERE id_nota_credito = :NEW.id_nota_credito FOR UPDATE;
        SELECT p.id_cliente INTO v_cliente_nc
        FROM nota_credito n
        JOIN comprobante_venta f ON f.id_comprobante_venta = n.id_comprobante_venta
        JOIN pedido p ON p.id_pedido = f.id_pedido
        WHERE n.id_nota_credito = :NEW.id_nota_credito;
        IF v_cliente_nc <> v_cliente THEN
            pr_error('La nota de crédito es de otro cliente');
        END IF;
        SELECT n.total
             - NVL((SELECT SUM(ree_monto) FROM reembolso     WHERE id_nota_credito = n.id_nota_credito), 0)
             - NVL((SELECT SUM(abo_monto) FROM abono_cliente WHERE id_nota_credito = n.id_nota_credito), 0)
          INTO v_disponible
        FROM v_nota_credito n WHERE n.id_nota_credito = :NEW.id_nota_credito;
        IF :NEW.abo_monto > v_disponible THEN
            pr_error('La nota de crédito solo tiene ' || v_disponible || ' disponibles');
        END IF;
    END IF;
END;
/

-- Un paquete solo se corta de una pieza de la misma variante
CREATE OR REPLACE TRIGGER tr_lote_validar
BEFORE INSERT ON lote
FOR EACH ROW
DECLARE
    v_n NUMBER;
BEGIN
    IF :NEW.id_lote_origen IS NOT NULL THEN
        SELECT COUNT(*) INTO v_n FROM lote WHERE id_lote = :NEW.id_lote_origen AND id_variante = :NEW.id_variante;
        IF v_n = 0 THEN
            pr_error('La pieza de origen debe ser de la misma variante');
        END IF;
    END IF;
END;
/

-- B11. Ofertas: una oferta ya aplicada en ventas no cambia su producto,
--      porcentaje ni inicio (solo se pausa, se reactiva o se le pone fin) y
--      no se elimina. Sin solapes por producto: se revisa al final de la
--      sentencia porque hay que leer la propia tabla.
CREATE OR REPLACE TRIGGER tr_oferta_validar
FOR INSERT OR UPDATE OR DELETE ON oferta
COMPOUND TRIGGER
    TYPE t_ids IS TABLE OF NUMBER;
    g_ids t_ids := t_ids();

    BEFORE EACH ROW IS
        v_n NUMBER;
    BEGIN
        IF UPDATING OR DELETING THEN
            SELECT COUNT(*) INTO v_n FROM detalle_pedido WHERE id_oferta = :OLD.id_oferta AND ROWNUM = 1;
            IF v_n > 0 THEN
                IF DELETING THEN
                    pr_error('La oferta ' || :OLD.id_oferta || ' ya se aplicó en ventas: no se elimina, se desactiva');
                END IF;
                IF pk_util.distinto(:NEW.id_producto, :OLD.id_producto)
                   OR pk_util.distinto(:NEW.ofe_porcentaje, :OLD.ofe_porcentaje)
                   OR pk_util.distinto(:NEW.ofe_desde, :OLD.ofe_desde) THEN
                    pr_error('La oferta ' || :OLD.id_oferta || ' ya se aplicó en ventas: solo se puede pausar, reactivar o cambiar su fecha de fin. Para otro porcentaje registre una oferta nueva');
                END IF;
            END IF;
        END IF;
    END BEFORE EACH ROW;

    AFTER EACH ROW IS
    BEGIN
        IF NOT DELETING AND :NEW.ofe_activa = 1 THEN
            g_ids.EXTEND;
            g_ids(g_ids.COUNT) := :NEW.id_oferta;
        END IF;
    END AFTER EACH ROW;

    AFTER STATEMENT IS
        v_otra NUMBER;
    BEGIN
        FOR i IN 1 .. g_ids.COUNT LOOP
            SELECT MIN(o.id_oferta) INTO v_otra
            FROM oferta n
            JOIN oferta o ON o.id_producto = n.id_producto AND o.id_oferta <> n.id_oferta AND o.ofe_activa = 1
            WHERE n.id_oferta = g_ids(i) AND n.ofe_activa = 1
              AND o.ofe_desde < NVL(n.ofe_hasta, TIMESTAMP '9999-12-31 00:00:00')
              AND n.ofe_desde < NVL(o.ofe_hasta, TIMESTAMP '9999-12-31 00:00:00');
            IF v_otra IS NOT NULL THEN
                pr_error('El producto ya tiene una oferta activa en ese período (oferta ' || v_otra || ')');
            END IF;
        END LOOP;
    END AFTER STATEMENT;
END tr_oferta_validar;
/

-- B1. Registros que nunca se editan ni se borran (bitácoras y kárdex)

CREATE OR REPLACE TRIGGER tr_lote_inmutable
BEFORE UPDATE OR DELETE ON lote
FOR EACH ROW
BEGIN
    pr_error('Los registros de lote no se modifican ni se eliminan. Registre un ajuste de inventario.');
END;
/

CREATE OR REPLACE TRIGGER tr_nota_credito_proveedor_inmutable
BEFORE UPDATE OR DELETE ON nota_credito_proveedor
FOR EACH ROW
BEGIN
    pr_error('Los registros de nota_credito_proveedor no se modifican ni se eliminan.');
END;
/

CREATE OR REPLACE TRIGGER tr_detalle_movimiento_inmutable
BEFORE UPDATE OR DELETE ON detalle_movimiento
FOR EACH ROW
BEGIN
    pr_error('Los registros de detalle_movimiento no se modifican ni se eliminan. Registre un ajuste de inventario.');
END;
/

CREATE OR REPLACE TRIGGER tr_historial_estado_inmutable
BEFORE UPDATE OR DELETE ON historial_estado_pedido
FOR EACH ROW
BEGIN
    pr_error('Los registros de historial_estado_pedido no se modifican ni se eliminan. Registre un nuevo estado.');
END;
/

CREATE OR REPLACE TRIGGER tr_historial_precio_inmutable
BEFORE UPDATE OR DELETE ON historial_precio
FOR EACH ROW
BEGIN
    pr_error('Los registros de historial_precio no se modifican ni se eliminan. Registre un nuevo precio.');
END;
/

CREATE OR REPLACE TRIGGER tr_detalle_nc_inmutable
BEFORE UPDATE OR DELETE ON detalle_nota_credito
FOR EACH ROW
BEGIN
    pr_error('Los registros de detalle_nota_credito no se modifican ni se eliminan. Emita otra nota de crédito.');
END;
/

CREATE OR REPLACE TRIGGER tr_reembolso_inmutable
BEFORE UPDATE OR DELETE ON reembolso
FOR EACH ROW
BEGIN
    pr_error('Los registros de reembolso no se modifican ni se eliminan.');
END;
/

CREATE OR REPLACE TRIGGER tr_pago_proveedor_inmutable
BEFORE UPDATE OR DELETE ON pago_proveedor
FOR EACH ROW
BEGIN
    pr_error('Los registros de pago_proveedor no se modifican ni se eliminan.');
END;
/

CREATE OR REPLACE TRIGGER tr_cuenta_por_cobrar_inmutable
BEFORE UPDATE OR DELETE ON cuenta_por_cobrar
FOR EACH ROW
BEGIN
    pr_error('Los registros de cuenta_por_cobrar no se modifican ni se eliminan. Registre un abono.');
END;
/

CREATE OR REPLACE TRIGGER tr_abono_cliente_inmutable
BEFORE UPDATE OR DELETE ON abono_cliente
FOR EACH ROW
BEGIN
    pr_error('Los registros de abono_cliente no se modifican ni se eliminan.');
END;
/

CREATE OR REPLACE TRIGGER tr_log_evento_inmutable
BEFORE UPDATE OR DELETE ON log_evento
FOR EACH ROW
BEGIN
    pr_error('Los registros de log_evento no se modifican ni se eliminan. La bitácora solo se inserta.');
END;
/

CREATE OR REPLACE TRIGGER tr_auditoria_inmutable
BEFORE UPDATE OR DELETE ON auditoria
FOR EACH ROW
BEGIN
    pr_error('Los registros de auditoria no se modifican ni se eliminan. La auditoría solo se inserta.');
END;
/


-- B12. Auditoría de tablas sensibles: guarda la fila antes y después del
--      cambio (en JSON), quién lo hizo (usuario de la aplicación que fijó
--      fn_exigir_permiso en pk_sesion) y desde qué conexión. Nunca guarda
--      hashes de clave; el último acceso no se audita. Una actualización
--      que no cambia nada no deja registro.
CREATE OR REPLACE PROCEDURE pr_auditar(p_tabla IN VARCHAR2, p_operacion IN VARCHAR2, p_id IN VARCHAR2,
                                       p_anteriores IN CLOB, p_nuevos IN CLOB) IS
BEGIN
    IF p_operacion = 'U' AND DBMS_LOB.COMPARE(p_anteriores, p_nuevos) = 0 THEN
        RETURN;
    END IF;
    INSERT INTO auditoria (aud_tabla, aud_operacion, aud_id_registro, aud_valores_anteriores, aud_valores_nuevos, id_usuario)
    VALUES (p_tabla, p_operacion, p_id, p_anteriores, p_nuevos, pk_sesion.usuario);
END pr_auditar;
/

CREATE OR REPLACE TRIGGER tr_usuario_auditar
AFTER INSERT OR UPDATE OR DELETE ON usuario
FOR EACH ROW
DECLARE
    v_ant CLOB;
    v_nue CLOB;
    v_hash VARCHAR2(10) := '(oculta)';
BEGIN
    IF UPDATING AND :NEW.usu_hash_clave <> :OLD.usu_hash_clave THEN
        v_hash := '(cambiada)';
    END IF;
    IF NOT INSERTING THEN
        SELECT JSON_OBJECT('id_usuario' VALUE :OLD.id_usuario,
                           'usu_correo' VALUE :OLD.usu_correo,
                           'usu_hash_clave' VALUE '(oculta)',
                           'usu_activo' VALUE :OLD.usu_activo,
                           'usu_creado' VALUE :OLD.usu_creado
                           RETURNING CLOB)
          INTO v_ant FROM dual;
    END IF;
    IF NOT DELETING THEN
        SELECT JSON_OBJECT('id_usuario' VALUE :NEW.id_usuario,
                           'usu_correo' VALUE :NEW.usu_correo,
                           'usu_hash_clave' VALUE v_hash,
                           'usu_activo' VALUE :NEW.usu_activo,
                           'usu_creado' VALUE :NEW.usu_creado
                           RETURNING CLOB)
          INTO v_nue FROM dual;
    END IF;
    pr_auditar('usuario', CASE WHEN INSERTING THEN 'I' WHEN UPDATING THEN 'U' ELSE 'D' END,
               CASE WHEN DELETING THEN :OLD.id_usuario ELSE :NEW.id_usuario END, v_ant, v_nue);
END;
/

CREATE OR REPLACE TRIGGER tr_usuario_rol_auditar
AFTER INSERT OR UPDATE OR DELETE ON usuario_rol
FOR EACH ROW
DECLARE
    v_ant CLOB;
    v_nue CLOB;
BEGIN
    IF NOT INSERTING THEN
        SELECT JSON_OBJECT('id_usuario' VALUE :OLD.id_usuario,
                           'id_rol' VALUE :OLD.id_rol
                           RETURNING CLOB)
          INTO v_ant FROM dual;
    END IF;
    IF NOT DELETING THEN
        SELECT JSON_OBJECT('id_usuario' VALUE :NEW.id_usuario,
                           'id_rol' VALUE :NEW.id_rol
                           RETURNING CLOB)
          INTO v_nue FROM dual;
    END IF;
    pr_auditar('usuario_rol', CASE WHEN INSERTING THEN 'I' WHEN UPDATING THEN 'U' ELSE 'D' END,
               CASE WHEN DELETING THEN :OLD.id_usuario || ',' || :OLD.id_rol ELSE :NEW.id_usuario || ',' || :NEW.id_rol END, v_ant, v_nue);
END;
/

CREATE OR REPLACE TRIGGER tr_rol_permiso_auditar
AFTER INSERT OR UPDATE OR DELETE ON rol_permiso
FOR EACH ROW
DECLARE
    v_ant CLOB;
    v_nue CLOB;
BEGIN
    IF NOT INSERTING THEN
        SELECT JSON_OBJECT('id_rol' VALUE :OLD.id_rol,
                           'id_permiso' VALUE :OLD.id_permiso
                           RETURNING CLOB)
          INTO v_ant FROM dual;
    END IF;
    IF NOT DELETING THEN
        SELECT JSON_OBJECT('id_rol' VALUE :NEW.id_rol,
                           'id_permiso' VALUE :NEW.id_permiso
                           RETURNING CLOB)
          INTO v_nue FROM dual;
    END IF;
    pr_auditar('rol_permiso', CASE WHEN INSERTING THEN 'I' WHEN UPDATING THEN 'U' ELSE 'D' END,
               CASE WHEN DELETING THEN :OLD.id_rol || ',' || :OLD.id_permiso ELSE :NEW.id_rol || ',' || :NEW.id_permiso END, v_ant, v_nue);
END;
/

CREATE OR REPLACE TRIGGER tr_empleado_auditar
AFTER INSERT OR UPDATE OR DELETE ON empleado
FOR EACH ROW
DECLARE
    v_ant CLOB;
    v_nue CLOB;
BEGIN
    IF NOT INSERTING THEN
        SELECT JSON_OBJECT('id_usuario' VALUE :OLD.id_usuario,
                           'id_tipo_identificacion' VALUE :OLD.id_tipo_identificacion,
                           'epl_identificacion' VALUE :OLD.epl_identificacion,
                           'epl_nombres' VALUE :OLD.epl_nombres,
                           'epl_apellidos' VALUE :OLD.epl_apellidos,
                           'epl_fecha_ingreso' VALUE :OLD.epl_fecha_ingreso
                           RETURNING CLOB)
          INTO v_ant FROM dual;
    END IF;
    IF NOT DELETING THEN
        SELECT JSON_OBJECT('id_usuario' VALUE :NEW.id_usuario,
                           'id_tipo_identificacion' VALUE :NEW.id_tipo_identificacion,
                           'epl_identificacion' VALUE :NEW.epl_identificacion,
                           'epl_nombres' VALUE :NEW.epl_nombres,
                           'epl_apellidos' VALUE :NEW.epl_apellidos,
                           'epl_fecha_ingreso' VALUE :NEW.epl_fecha_ingreso
                           RETURNING CLOB)
          INTO v_nue FROM dual;
    END IF;
    pr_auditar('empleado', CASE WHEN INSERTING THEN 'I' WHEN UPDATING THEN 'U' ELSE 'D' END,
               CASE WHEN DELETING THEN :OLD.id_usuario ELSE :NEW.id_usuario END, v_ant, v_nue);
END;
/

CREATE OR REPLACE TRIGGER tr_cliente_auditar
AFTER INSERT OR UPDATE OR DELETE ON cliente
FOR EACH ROW
DECLARE
    v_ant CLOB;
    v_nue CLOB;
BEGIN
    IF NOT INSERTING THEN
        SELECT JSON_OBJECT('id_cliente' VALUE :OLD.id_cliente,
                           'cli_nombres' VALUE :OLD.cli_nombres,
                           'cli_apellidos' VALUE :OLD.cli_apellidos,
                           'cli_correo' VALUE :OLD.cli_correo,
                           'cli_fecha_registro' VALUE :OLD.cli_fecha_registro,
                           'cli_limite_credito' VALUE :OLD.cli_limite_credito
                           RETURNING CLOB)
          INTO v_ant FROM dual;
    END IF;
    IF NOT DELETING THEN
        SELECT JSON_OBJECT('id_cliente' VALUE :NEW.id_cliente,
                           'cli_nombres' VALUE :NEW.cli_nombres,
                           'cli_apellidos' VALUE :NEW.cli_apellidos,
                           'cli_correo' VALUE :NEW.cli_correo,
                           'cli_fecha_registro' VALUE :NEW.cli_fecha_registro,
                           'cli_limite_credito' VALUE :NEW.cli_limite_credito
                           RETURNING CLOB)
          INTO v_nue FROM dual;
    END IF;
    pr_auditar('cliente', CASE WHEN INSERTING THEN 'I' WHEN UPDATING THEN 'U' ELSE 'D' END,
               CASE WHEN DELETING THEN :OLD.id_cliente ELSE :NEW.id_cliente END, v_ant, v_nue);
END;
/

CREATE OR REPLACE TRIGGER tr_datos_facturacion_auditar
AFTER INSERT OR UPDATE OR DELETE ON datos_facturacion
FOR EACH ROW
DECLARE
    v_ant CLOB;
    v_nue CLOB;
BEGIN
    IF NOT INSERTING THEN
        SELECT JSON_OBJECT('id_datos_facturacion' VALUE :OLD.id_datos_facturacion,
                           'id_cliente' VALUE :OLD.id_cliente,
                           'id_tipo_identificacion' VALUE :OLD.id_tipo_identificacion,
                           'dfa_identificacion' VALUE :OLD.dfa_identificacion,
                           'dfa_razon_social' VALUE :OLD.dfa_razon_social,
                           'dfa_correo' VALUE :OLD.dfa_correo,
                           'id_direccion' VALUE :OLD.id_direccion,
                           'dfa_activo' VALUE :OLD.dfa_activo
                           RETURNING CLOB)
          INTO v_ant FROM dual;
    END IF;
    IF NOT DELETING THEN
        SELECT JSON_OBJECT('id_datos_facturacion' VALUE :NEW.id_datos_facturacion,
                           'id_cliente' VALUE :NEW.id_cliente,
                           'id_tipo_identificacion' VALUE :NEW.id_tipo_identificacion,
                           'dfa_identificacion' VALUE :NEW.dfa_identificacion,
                           'dfa_razon_social' VALUE :NEW.dfa_razon_social,
                           'dfa_correo' VALUE :NEW.dfa_correo,
                           'id_direccion' VALUE :NEW.id_direccion,
                           'dfa_activo' VALUE :NEW.dfa_activo
                           RETURNING CLOB)
          INTO v_nue FROM dual;
    END IF;
    pr_auditar('datos_facturacion', CASE WHEN INSERTING THEN 'I' WHEN UPDATING THEN 'U' ELSE 'D' END,
               CASE WHEN DELETING THEN :OLD.id_datos_facturacion ELSE :NEW.id_datos_facturacion END, v_ant, v_nue);
END;
/

CREATE OR REPLACE TRIGGER tr_empresa_auditar
AFTER INSERT OR UPDATE OR DELETE ON empresa
FOR EACH ROW
DECLARE
    v_ant CLOB;
    v_nue CLOB;
BEGIN
    IF NOT INSERTING THEN
        SELECT JSON_OBJECT('id_empresa' VALUE :OLD.id_empresa,
                           'emp_ruc' VALUE :OLD.emp_ruc,
                           'emp_razon_social' VALUE :OLD.emp_razon_social,
                           'emp_nombre_comercial' VALUE :OLD.emp_nombre_comercial,
                           'emp_eslogan' VALUE :OLD.emp_eslogan,
                           'emp_correo' VALUE :OLD.emp_correo,
                           'emp_telefono' VALUE :OLD.emp_telefono,
                           'id_direccion_matriz' VALUE :OLD.id_direccion_matriz,
                           'emp_dias_devolucion' VALUE :OLD.emp_dias_devolucion,
                           'emp_ambiente_sri' VALUE :OLD.emp_ambiente_sri,
                           'emp_max_consumidor_final' VALUE :OLD.emp_max_consumidor_final
                           RETURNING CLOB)
          INTO v_ant FROM dual;
    END IF;
    IF NOT DELETING THEN
        SELECT JSON_OBJECT('id_empresa' VALUE :NEW.id_empresa,
                           'emp_ruc' VALUE :NEW.emp_ruc,
                           'emp_razon_social' VALUE :NEW.emp_razon_social,
                           'emp_nombre_comercial' VALUE :NEW.emp_nombre_comercial,
                           'emp_eslogan' VALUE :NEW.emp_eslogan,
                           'emp_correo' VALUE :NEW.emp_correo,
                           'emp_telefono' VALUE :NEW.emp_telefono,
                           'id_direccion_matriz' VALUE :NEW.id_direccion_matriz,
                           'emp_dias_devolucion' VALUE :NEW.emp_dias_devolucion,
                           'emp_ambiente_sri' VALUE :NEW.emp_ambiente_sri,
                           'emp_max_consumidor_final' VALUE :NEW.emp_max_consumidor_final
                           RETURNING CLOB)
          INTO v_nue FROM dual;
    END IF;
    pr_auditar('empresa', CASE WHEN INSERTING THEN 'I' WHEN UPDATING THEN 'U' ELSE 'D' END,
               CASE WHEN DELETING THEN :OLD.id_empresa ELSE :NEW.id_empresa END, v_ant, v_nue);
END;
/

CREATE OR REPLACE TRIGGER tr_punto_emision_auditar
AFTER INSERT OR UPDATE OR DELETE ON punto_emision
FOR EACH ROW
DECLARE
    v_ant CLOB;
    v_nue CLOB;
BEGIN
    IF NOT INSERTING THEN
        SELECT JSON_OBJECT('id_punto_emision' VALUE :OLD.id_punto_emision,
                           'pem_establecimiento' VALUE :OLD.pem_establecimiento,
                           'pem_punto' VALUE :OLD.pem_punto,
                           'pem_descripcion' VALUE :OLD.pem_descripcion,
                           'pem_activo' VALUE :OLD.pem_activo
                           RETURNING CLOB)
          INTO v_ant FROM dual;
    END IF;
    IF NOT DELETING THEN
        SELECT JSON_OBJECT('id_punto_emision' VALUE :NEW.id_punto_emision,
                           'pem_establecimiento' VALUE :NEW.pem_establecimiento,
                           'pem_punto' VALUE :NEW.pem_punto,
                           'pem_descripcion' VALUE :NEW.pem_descripcion,
                           'pem_activo' VALUE :NEW.pem_activo
                           RETURNING CLOB)
          INTO v_nue FROM dual;
    END IF;
    pr_auditar('punto_emision', CASE WHEN INSERTING THEN 'I' WHEN UPDATING THEN 'U' ELSE 'D' END,
               CASE WHEN DELETING THEN :OLD.id_punto_emision ELSE :NEW.id_punto_emision END, v_ant, v_nue);
END;
/

CREATE OR REPLACE TRIGGER tr_categoria_auditar
AFTER INSERT OR UPDATE OR DELETE ON categoria
FOR EACH ROW
DECLARE
    v_ant CLOB;
    v_nue CLOB;
BEGIN
    IF NOT INSERTING THEN
        SELECT JSON_OBJECT('id_categoria' VALUE :OLD.id_categoria,
                           'id_categoria_padre' VALUE :OLD.id_categoria_padre,
                           'cat_codigo' VALUE :OLD.cat_codigo,
                           'cat_nombre' VALUE :OLD.cat_nombre,
                           'cat_activa' VALUE :OLD.cat_activa
                           RETURNING CLOB)
          INTO v_ant FROM dual;
    END IF;
    IF NOT DELETING THEN
        SELECT JSON_OBJECT('id_categoria' VALUE :NEW.id_categoria,
                           'id_categoria_padre' VALUE :NEW.id_categoria_padre,
                           'cat_codigo' VALUE :NEW.cat_codigo,
                           'cat_nombre' VALUE :NEW.cat_nombre,
                           'cat_activa' VALUE :NEW.cat_activa
                           RETURNING CLOB)
          INTO v_nue FROM dual;
    END IF;
    pr_auditar('categoria', CASE WHEN INSERTING THEN 'I' WHEN UPDATING THEN 'U' ELSE 'D' END,
               CASE WHEN DELETING THEN :OLD.id_categoria ELSE :NEW.id_categoria END, v_ant, v_nue);
END;
/

CREATE OR REPLACE TRIGGER tr_producto_auditar
AFTER INSERT OR UPDATE OR DELETE ON producto
FOR EACH ROW
DECLARE
    v_ant CLOB;
    v_nue CLOB;
BEGIN
    IF NOT INSERTING THEN
        SELECT JSON_OBJECT('id_producto' VALUE :OLD.id_producto,
                           'id_categoria' VALUE :OLD.id_categoria,
                           'id_unidad_medida' VALUE :OLD.id_unidad_medida,
                           'id_tarifa_iva' VALUE :OLD.id_tarifa_iva,
                           'prd_codigo' VALUE :OLD.prd_codigo,
                           'prd_nombre' VALUE :OLD.prd_nombre,
                           'prd_descripcion' VALUE :OLD.prd_descripcion,
                           'prd_uso' VALUE :OLD.prd_uso,
                           'prd_imagen_url' VALUE :OLD.prd_imagen_url,
                           'prd_publicado' VALUE :OLD.prd_publicado,
                           'prd_venta_por_pieza' VALUE :OLD.prd_venta_por_pieza,
                           'prd_fecha_creacion' VALUE :OLD.prd_fecha_creacion
                           RETURNING CLOB)
          INTO v_ant FROM dual;
    END IF;
    IF NOT DELETING THEN
        SELECT JSON_OBJECT('id_producto' VALUE :NEW.id_producto,
                           'id_categoria' VALUE :NEW.id_categoria,
                           'id_unidad_medida' VALUE :NEW.id_unidad_medida,
                           'id_tarifa_iva' VALUE :NEW.id_tarifa_iva,
                           'prd_codigo' VALUE :NEW.prd_codigo,
                           'prd_nombre' VALUE :NEW.prd_nombre,
                           'prd_descripcion' VALUE :NEW.prd_descripcion,
                           'prd_uso' VALUE :NEW.prd_uso,
                           'prd_imagen_url' VALUE :NEW.prd_imagen_url,
                           'prd_publicado' VALUE :NEW.prd_publicado,
                           'prd_venta_por_pieza' VALUE :NEW.prd_venta_por_pieza,
                           'prd_fecha_creacion' VALUE :NEW.prd_fecha_creacion
                           RETURNING CLOB)
          INTO v_nue FROM dual;
    END IF;
    pr_auditar('producto', CASE WHEN INSERTING THEN 'I' WHEN UPDATING THEN 'U' ELSE 'D' END,
               CASE WHEN DELETING THEN :OLD.id_producto ELSE :NEW.id_producto END, v_ant, v_nue);
END;
/

CREATE OR REPLACE TRIGGER tr_variante_auditar
AFTER INSERT OR UPDATE OR DELETE ON variante
FOR EACH ROW
DECLARE
    v_ant CLOB;
    v_nue CLOB;
BEGIN
    IF NOT INSERTING THEN
        SELECT JSON_OBJECT('id_variante' VALUE :OLD.id_variante,
                           'id_producto' VALUE :OLD.id_producto,
                           'var_sku' VALUE :OLD.var_sku,
                           'var_stock_minimo' VALUE :OLD.var_stock_minimo,
                           'var_activa' VALUE :OLD.var_activa
                           RETURNING CLOB)
          INTO v_ant FROM dual;
    END IF;
    IF NOT DELETING THEN
        SELECT JSON_OBJECT('id_variante' VALUE :NEW.id_variante,
                           'id_producto' VALUE :NEW.id_producto,
                           'var_sku' VALUE :NEW.var_sku,
                           'var_stock_minimo' VALUE :NEW.var_stock_minimo,
                           'var_activa' VALUE :NEW.var_activa
                           RETURNING CLOB)
          INTO v_nue FROM dual;
    END IF;
    pr_auditar('variante', CASE WHEN INSERTING THEN 'I' WHEN UPDATING THEN 'U' ELSE 'D' END,
               CASE WHEN DELETING THEN :OLD.id_variante ELSE :NEW.id_variante END, v_ant, v_nue);
END;
/

CREATE OR REPLACE TRIGGER tr_presentacion_auditar
AFTER INSERT OR UPDATE OR DELETE ON presentacion
FOR EACH ROW
DECLARE
    v_ant CLOB;
    v_nue CLOB;
BEGIN
    IF NOT INSERTING THEN
        SELECT JSON_OBJECT('id_presentacion' VALUE :OLD.id_presentacion,
                           'id_variante' VALUE :OLD.id_variante,
                           'pre_descripcion' VALUE :OLD.pre_descripcion,
                           'pre_factor' VALUE :OLD.pre_factor,
                           'pre_cantidad_minima' VALUE :OLD.pre_cantidad_minima,
                           'pre_activa' VALUE :OLD.pre_activa
                           RETURNING CLOB)
          INTO v_ant FROM dual;
    END IF;
    IF NOT DELETING THEN
        SELECT JSON_OBJECT('id_presentacion' VALUE :NEW.id_presentacion,
                           'id_variante' VALUE :NEW.id_variante,
                           'pre_descripcion' VALUE :NEW.pre_descripcion,
                           'pre_factor' VALUE :NEW.pre_factor,
                           'pre_cantidad_minima' VALUE :NEW.pre_cantidad_minima,
                           'pre_activa' VALUE :NEW.pre_activa
                           RETURNING CLOB)
          INTO v_nue FROM dual;
    END IF;
    pr_auditar('presentacion', CASE WHEN INSERTING THEN 'I' WHEN UPDATING THEN 'U' ELSE 'D' END,
               CASE WHEN DELETING THEN :OLD.id_presentacion ELSE :NEW.id_presentacion END, v_ant, v_nue);
END;
/

CREATE OR REPLACE TRIGGER tr_oferta_auditar
AFTER INSERT OR UPDATE OR DELETE ON oferta
FOR EACH ROW
DECLARE
    v_ant CLOB;
    v_nue CLOB;
BEGIN
    IF NOT INSERTING THEN
        SELECT JSON_OBJECT('id_oferta' VALUE :OLD.id_oferta,
                           'id_producto' VALUE :OLD.id_producto,
                           'ofe_porcentaje' VALUE :OLD.ofe_porcentaje,
                           'ofe_descripcion' VALUE :OLD.ofe_descripcion,
                           'ofe_desde' VALUE :OLD.ofe_desde,
                           'ofe_hasta' VALUE :OLD.ofe_hasta,
                           'ofe_activa' VALUE :OLD.ofe_activa,
                           'id_usuario_registra' VALUE :OLD.id_usuario_registra,
                           'ofe_fecha_registro' VALUE :OLD.ofe_fecha_registro
                           RETURNING CLOB)
          INTO v_ant FROM dual;
    END IF;
    IF NOT DELETING THEN
        SELECT JSON_OBJECT('id_oferta' VALUE :NEW.id_oferta,
                           'id_producto' VALUE :NEW.id_producto,
                           'ofe_porcentaje' VALUE :NEW.ofe_porcentaje,
                           'ofe_descripcion' VALUE :NEW.ofe_descripcion,
                           'ofe_desde' VALUE :NEW.ofe_desde,
                           'ofe_hasta' VALUE :NEW.ofe_hasta,
                           'ofe_activa' VALUE :NEW.ofe_activa,
                           'id_usuario_registra' VALUE :NEW.id_usuario_registra,
                           'ofe_fecha_registro' VALUE :NEW.ofe_fecha_registro
                           RETURNING CLOB)
          INTO v_nue FROM dual;
    END IF;
    pr_auditar('oferta', CASE WHEN INSERTING THEN 'I' WHEN UPDATING THEN 'U' ELSE 'D' END,
               CASE WHEN DELETING THEN :OLD.id_oferta ELSE :NEW.id_oferta END, v_ant, v_nue);
END;
/

CREATE OR REPLACE TRIGGER tr_proveedor_auditar
AFTER INSERT OR UPDATE OR DELETE ON proveedor
FOR EACH ROW
DECLARE
    v_ant CLOB;
    v_nue CLOB;
BEGIN
    IF NOT INSERTING THEN
        SELECT JSON_OBJECT('id_proveedor' VALUE :OLD.id_proveedor,
                           'id_tipo_identificacion' VALUE :OLD.id_tipo_identificacion,
                           'prv_identificacion' VALUE :OLD.prv_identificacion,
                           'prv_razon_social' VALUE :OLD.prv_razon_social,
                           'prv_nombre_comercial' VALUE :OLD.prv_nombre_comercial,
                           'prv_correo' VALUE :OLD.prv_correo,
                           'prv_telefono' VALUE :OLD.prv_telefono,
                           'prv_activo' VALUE :OLD.prv_activo
                           RETURNING CLOB)
          INTO v_ant FROM dual;
    END IF;
    IF NOT DELETING THEN
        SELECT JSON_OBJECT('id_proveedor' VALUE :NEW.id_proveedor,
                           'id_tipo_identificacion' VALUE :NEW.id_tipo_identificacion,
                           'prv_identificacion' VALUE :NEW.prv_identificacion,
                           'prv_razon_social' VALUE :NEW.prv_razon_social,
                           'prv_nombre_comercial' VALUE :NEW.prv_nombre_comercial,
                           'prv_correo' VALUE :NEW.prv_correo,
                           'prv_telefono' VALUE :NEW.prv_telefono,
                           'prv_activo' VALUE :NEW.prv_activo
                           RETURNING CLOB)
          INTO v_nue FROM dual;
    END IF;
    pr_auditar('proveedor', CASE WHEN INSERTING THEN 'I' WHEN UPDATING THEN 'U' ELSE 'D' END,
               CASE WHEN DELETING THEN :OLD.id_proveedor ELSE :NEW.id_proveedor END, v_ant, v_nue);
END;
/

CREATE OR REPLACE TRIGGER tr_orden_compra_auditar
AFTER INSERT OR UPDATE OR DELETE ON orden_compra
FOR EACH ROW
DECLARE
    v_ant CLOB;
    v_nue CLOB;
BEGIN
    IF NOT INSERTING THEN
        SELECT JSON_OBJECT('id_orden_compra' VALUE :OLD.id_orden_compra,
                           'id_proveedor' VALUE :OLD.id_proveedor,
                           'id_usuario_crea' VALUE :OLD.id_usuario_crea,
                           'oc_fecha' VALUE :OLD.oc_fecha,
                           'oc_fecha_entrega_esperada' VALUE :OLD.oc_fecha_entrega_esperada,
                           'oc_estado' VALUE :OLD.oc_estado,
                           'oc_observacion' VALUE :OLD.oc_observacion
                           RETURNING CLOB)
          INTO v_ant FROM dual;
    END IF;
    IF NOT DELETING THEN
        SELECT JSON_OBJECT('id_orden_compra' VALUE :NEW.id_orden_compra,
                           'id_proveedor' VALUE :NEW.id_proveedor,
                           'id_usuario_crea' VALUE :NEW.id_usuario_crea,
                           'oc_fecha' VALUE :NEW.oc_fecha,
                           'oc_fecha_entrega_esperada' VALUE :NEW.oc_fecha_entrega_esperada,
                           'oc_estado' VALUE :NEW.oc_estado,
                           'oc_observacion' VALUE :NEW.oc_observacion
                           RETURNING CLOB)
          INTO v_nue FROM dual;
    END IF;
    pr_auditar('orden_compra', CASE WHEN INSERTING THEN 'I' WHEN UPDATING THEN 'U' ELSE 'D' END,
               CASE WHEN DELETING THEN :OLD.id_orden_compra ELSE :NEW.id_orden_compra END, v_ant, v_nue);
END;
/

CREATE OR REPLACE TRIGGER tr_detalle_oc_auditar
AFTER INSERT OR UPDATE OR DELETE ON detalle_orden_compra
FOR EACH ROW
DECLARE
    v_ant CLOB;
    v_nue CLOB;
BEGIN
    IF NOT INSERTING THEN
        SELECT JSON_OBJECT('id_detalle_orden_compra' VALUE :OLD.id_detalle_orden_compra,
                           'id_orden_compra' VALUE :OLD.id_orden_compra,
                           'id_variante' VALUE :OLD.id_variante,
                           'dco_cantidad' VALUE :OLD.dco_cantidad,
                           'dco_costo_unitario' VALUE :OLD.dco_costo_unitario
                           RETURNING CLOB)
          INTO v_ant FROM dual;
    END IF;
    IF NOT DELETING THEN
        SELECT JSON_OBJECT('id_detalle_orden_compra' VALUE :NEW.id_detalle_orden_compra,
                           'id_orden_compra' VALUE :NEW.id_orden_compra,
                           'id_variante' VALUE :NEW.id_variante,
                           'dco_cantidad' VALUE :NEW.dco_cantidad,
                           'dco_costo_unitario' VALUE :NEW.dco_costo_unitario
                           RETURNING CLOB)
          INTO v_nue FROM dual;
    END IF;
    pr_auditar('detalle_orden_compra', CASE WHEN INSERTING THEN 'I' WHEN UPDATING THEN 'U' ELSE 'D' END,
               CASE WHEN DELETING THEN :OLD.id_detalle_orden_compra ELSE :NEW.id_detalle_orden_compra END, v_ant, v_nue);
END;
/

CREATE OR REPLACE TRIGGER tr_comprobante_venta_auditar
AFTER UPDATE OR DELETE ON comprobante_venta
FOR EACH ROW
DECLARE
    v_ant CLOB;
    v_nue CLOB;
BEGIN
    IF NOT INSERTING THEN
        SELECT JSON_OBJECT('id_comprobante_venta' VALUE :OLD.id_comprobante_venta,
                           'id_tipo_comprobante' VALUE :OLD.id_tipo_comprobante,
                           'id_pedido' VALUE :OLD.id_pedido,
                           'id_datos_facturacion' VALUE :OLD.id_datos_facturacion,
                           'id_punto_emision' VALUE :OLD.id_punto_emision,
                           'cve_secuencial' VALUE :OLD.cve_secuencial,
                           'cve_fechahora' VALUE :OLD.cve_fechahora,
                           'id_usuario_emite' VALUE :OLD.id_usuario_emite,
                           'cve_clave_acceso' VALUE :OLD.cve_clave_acceso,
                           'cve_fecha_autorizacion' VALUE :OLD.cve_fecha_autorizacion,
                           'cve_estado' VALUE :OLD.cve_estado
                           RETURNING CLOB)
          INTO v_ant FROM dual;
    END IF;
    IF NOT DELETING THEN
        SELECT JSON_OBJECT('id_comprobante_venta' VALUE :NEW.id_comprobante_venta,
                           'id_tipo_comprobante' VALUE :NEW.id_tipo_comprobante,
                           'id_pedido' VALUE :NEW.id_pedido,
                           'id_datos_facturacion' VALUE :NEW.id_datos_facturacion,
                           'id_punto_emision' VALUE :NEW.id_punto_emision,
                           'cve_secuencial' VALUE :NEW.cve_secuencial,
                           'cve_fechahora' VALUE :NEW.cve_fechahora,
                           'id_usuario_emite' VALUE :NEW.id_usuario_emite,
                           'cve_clave_acceso' VALUE :NEW.cve_clave_acceso,
                           'cve_fecha_autorizacion' VALUE :NEW.cve_fecha_autorizacion,
                           'cve_estado' VALUE :NEW.cve_estado
                           RETURNING CLOB)
          INTO v_nue FROM dual;
    END IF;
    pr_auditar('comprobante_venta', CASE WHEN INSERTING THEN 'I' WHEN UPDATING THEN 'U' ELSE 'D' END,
               CASE WHEN DELETING THEN :OLD.id_comprobante_venta ELSE :NEW.id_comprobante_venta END, v_ant, v_nue);
END;
/

CREATE OR REPLACE TRIGGER tr_nota_credito_auditar
AFTER UPDATE OR DELETE ON nota_credito
FOR EACH ROW
DECLARE
    v_ant CLOB;
    v_nue CLOB;
BEGIN
    IF NOT INSERTING THEN
        SELECT JSON_OBJECT('id_nota_credito' VALUE :OLD.id_nota_credito,
                           'id_comprobante_venta' VALUE :OLD.id_comprobante_venta,
                           'id_punto_emision' VALUE :OLD.id_punto_emision,
                           'ncr_secuencial' VALUE :OLD.ncr_secuencial,
                           'ncr_fechahora' VALUE :OLD.ncr_fechahora,
                           'id_motivo_devolucion' VALUE :OLD.id_motivo_devolucion,
                           'id_usuario_autoriza' VALUE :OLD.id_usuario_autoriza,
                           'ncr_observacion' VALUE :OLD.ncr_observacion,
                           'ncr_clave_acceso' VALUE :OLD.ncr_clave_acceso,
                           'ncr_fecha_autorizacion' VALUE :OLD.ncr_fecha_autorizacion,
                           'ncr_estado' VALUE :OLD.ncr_estado
                           RETURNING CLOB)
          INTO v_ant FROM dual;
    END IF;
    IF NOT DELETING THEN
        SELECT JSON_OBJECT('id_nota_credito' VALUE :NEW.id_nota_credito,
                           'id_comprobante_venta' VALUE :NEW.id_comprobante_venta,
                           'id_punto_emision' VALUE :NEW.id_punto_emision,
                           'ncr_secuencial' VALUE :NEW.ncr_secuencial,
                           'ncr_fechahora' VALUE :NEW.ncr_fechahora,
                           'id_motivo_devolucion' VALUE :NEW.id_motivo_devolucion,
                           'id_usuario_autoriza' VALUE :NEW.id_usuario_autoriza,
                           'ncr_observacion' VALUE :NEW.ncr_observacion,
                           'ncr_clave_acceso' VALUE :NEW.ncr_clave_acceso,
                           'ncr_fecha_autorizacion' VALUE :NEW.ncr_fecha_autorizacion,
                           'ncr_estado' VALUE :NEW.ncr_estado
                           RETURNING CLOB)
          INTO v_nue FROM dual;
    END IF;
    pr_auditar('nota_credito', CASE WHEN INSERTING THEN 'I' WHEN UPDATING THEN 'U' ELSE 'D' END,
               CASE WHEN DELETING THEN :OLD.id_nota_credito ELSE :NEW.id_nota_credito END, v_ant, v_nue);
END;
/


-- =====================================================================
-- C. FUNCIONES DEL FLUJO
--    Los parámetros JSON (líneas, lotes) son texto JSON en un CLOB, por
--    ejemplo '[{"id_presentacion": 5, "cantidad": 2}]'.
--    Los parámetros sí/no son NUMBER: 1 = sí, 0 = no.
--    Importante: las líneas se insertan de una en una (INSERT ... VALUES);
--    los disparadores que leen su propia tabla dependen de ello.
-- =====================================================================

-- C2. Clave de acceso SRI (49 dígitos, dígito verificador módulo 11)
--     p_tipo: '01' factura, '04' nota de crédito
CREATE OR REPLACE FUNCTION fn_clave_acceso(p_fecha IN DATE, p_tipo IN VARCHAR2, p_punto IN NUMBER, p_secuencial IN NUMBER)
RETURN VARCHAR2 IS
    v_base VARCHAR2(48);
    v_suma NUMBER := 0;
    v_peso NUMBER := 2;
    v_dv   NUMBER;
BEGIN
    SELECT TO_CHAR(p_fecha, 'DDMMYYYY') || p_tipo || e.emp_ruc || e.emp_ambiente_sri
           || pe.pem_establecimiento || pe.pem_punto || LPAD(TO_CHAR(p_secuencial), 9, '0')
           || LPAD(TO_CHAR(TRUNC(DBMS_RANDOM.VALUE(0, 100000000))), 8, '0')   -- código numérico
           || '1'                                                           -- emisión normal
      INTO v_base
    FROM empresa e, punto_emision pe
    WHERE pe.id_punto_emision = p_punto;

    FOR i IN REVERSE 1 .. LENGTH(v_base) LOOP
        v_suma := v_suma + TO_NUMBER(SUBSTR(v_base, i, 1)) * v_peso;
        v_peso := CASE WHEN v_peso = 7 THEN 2 ELSE v_peso + 1 END;
    END LOOP;
    v_dv := 11 - MOD(v_suma, 11);
    v_dv := CASE v_dv WHEN 11 THEN 0 WHEN 10 THEN 1 ELSE v_dv END;
    RETURN v_base || v_dv;
END fn_clave_acceso;
/


-- C3. Cambio de estado del pedido (las transiciones se validan en B3)
CREATE OR REPLACE PROCEDURE fn_cambiar_estado_pedido(p_pedido IN NUMBER, p_estado IN VARCHAR2,
                                                     p_usuario IN NUMBER DEFAULT NULL,
                                                     p_observacion IN VARCHAR2 DEFAULT NULL) IS
BEGIN
    IF p_estado IN ('DES', 'ENT') THEN
        IF p_usuario IS NULL THEN
            pr_error('Indique el usuario que despacha o entrega el pedido');
        END IF;
        fn_exigir_permiso(p_usuario, 'PEDIDO_DESPACHAR');
    END IF;
    INSERT INTO historial_estado_pedido (id_pedido, id_estado_pedido, id_usuario, hep_observacion)
    VALUES (p_pedido, p_estado, p_usuario, p_observacion);
END fn_cambiar_estado_pedido;
/


-- C4b. Negociación de precios (tienda y WhatsApp).
--      El vendedor escribe el VALOR FINAL que pactó con el cliente y la base
--      calcula el descuento. fn_base_desde_final convierte ese valor (con
--      IVA) a base imponible, de forma que base + IVA redondeado quede igual
--      al valor pactado; si por el redondeo no es posible exacto, queda al
--      centavo inmediatamente inferior (el cliente nunca paga de más).
CREATE OR REPLACE FUNCTION fn_base_desde_final(p_valor_final IN NUMBER, p_porcentaje_iva IN NUMBER,
                                               p_con_iva IN NUMBER DEFAULT 1)
RETURN NUMBER DETERMINISTIC IS
    v_base        NUMBER;
    v_candidata   NUMBER;
    v_total       NUMBER;
    v_mejor       NUMBER;
    v_mejor_total NUMBER;
BEGIN
    IF p_valor_final IS NULL OR p_valor_final <= 0 THEN
        pr_error('El valor pactado debe ser mayor que cero');
    END IF;
    IF p_con_iva = 0 OR p_porcentaje_iva = 0 THEN
        RETURN ROUND(p_valor_final, 2);
    END IF;
    v_base := ROUND(p_valor_final / (1 + p_porcentaje_iva / 100), 2);
    FOR i IN -2 .. 2 LOOP
        v_candidata := v_base + i * 0.01;
        v_total := v_candidata + ROUND(v_candidata * p_porcentaje_iva / 100, 2);
        IF v_candidata > 0 AND v_total <= p_valor_final AND (v_mejor_total IS NULL OR v_total > v_mejor_total) THEN
            v_mejor := v_candidata;
            v_mejor_total := v_total;
        END IF;
    END LOOP;
    RETURN v_mejor;
END fn_base_desde_final;
/


-- C4. Crear un pedido (venta web, en tienda o por WhatsApp)
--     p_lineas: '[{"id_presentacion": 5, "cantidad": 2, "valor_final": 20.00}, ...]'
--     Toma el precio vigente, la oferta vigente y la tarifa de IVA del
--     producto en ese momento y reserva el stock (falla si no hay disponible).
--     Los pedidos web los pide el nodo e-commerce (fn_crear_pedido_desde_carrito).
CREATE OR REPLACE FUNCTION fn_crear_pedido(p_cliente IN NUMBER, p_canal IN VARCHAR2, p_lineas IN CLOB,
                                           p_vendedor IN NUMBER DEFAULT NULL,
                                           p_observacion IN VARCHAR2 DEFAULT NULL)
RETURN NUMBER IS
    v_pedido    NUMBER;
    v_usuario   NUMBER;
    v_n         NUMBER;
    v_desc      NUMBER;
    v_lista     NUMBER;
    v_base      NUMBER;
    v_desc_pre  presentacion.pre_descripcion%TYPE;
    v_minima    NUMBER;
    v_sku       variante.var_sku%TYPE;
    v_tarifa    producto.id_tarifa_iva%TYPE;
    v_precio    NUMBER;
    v_pct_iva   NUMBER;
    v_pct_ofe   NUMBER;
    v_variantes SYS.ODCINUMBERLIST;
    v_dummy     NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_n
    FROM JSON_TABLE(p_lineas, '$[*]' COLUMNS (id_presentacion NUMBER PATH '$.id_presentacion'));
    IF p_lineas IS NULL OR v_n = 0 THEN
        pr_error('El pedido no tiene líneas');
    END IF;

    -- Quién registra: el vendedor en tienda/WhatsApp. En la web no hay usuario
    -- interno: el pedido lo pide el nodo e-commerce, que ya validó la cuenta
    -- del cliente (en el historial queda sin usuario)
    IF p_canal = 'WEB' THEN
        SELECT COUNT(*) INTO v_n FROM cliente WHERE id_cliente = p_cliente;
        IF v_n = 0 THEN
            pr_error('El cliente ' || p_cliente || ' no existe');
        END IF;
    ELSE
        IF p_vendedor IS NULL THEN
            pr_error('Las ventas del canal ' || p_canal || ' requieren vendedor');
        END IF;
        fn_exigir_permiso(p_vendedor, 'VENTA_REGISTRAR');
        v_usuario := p_vendedor;
    END IF;

    -- Serializa las reservas por variante (evita vender dos veces el mismo
    -- stock): bloquea las variantes del pedido en orden.
    -- Oracle no permite FOR UPDATE cuando el filtro usa JSON_TABLE (ORA-01786),
    -- asi que primero se resuelven los ids en PL/SQL puro (sin FOR UPDATE) y
    -- luego se bloquean uno por uno, ya en orden, con un SELECT simple.
    SELECT DISTINCT v.id_variante BULK COLLECT INTO v_variantes
    FROM variante v
    WHERE v.id_variante IN (SELECT pr.id_variante
                            FROM JSON_TABLE(p_lineas, '$[*]' COLUMNS (id_presentacion NUMBER PATH '$.id_presentacion')) j
                            JOIN presentacion pr ON pr.id_presentacion = j.id_presentacion)
    ORDER BY v.id_variante;

    FOR i IN 1 .. v_variantes.COUNT LOOP
        SELECT id_variante INTO v_dummy FROM variante WHERE id_variante = v_variantes(i) FOR UPDATE;
    END LOOP;

    INSERT INTO pedido (id_cliente, id_canal_venta, id_empleado_vendedor, ped_observacion)
    VALUES (p_cliente, p_canal, CASE WHEN p_canal = 'WEB' THEN NULL ELSE p_vendedor END, p_observacion)
    RETURNING id_pedido INTO v_pedido;

    -- Cada línea puede traer un descuento en monto o, mejor, el valor final
    -- pactado con el cliente (con IVA): la base calcula el descuento
    FOR r IN (SELECT j.id_presentacion, j.cantidad, NVL(j.descuento, 0) AS descuento, j.valor_final
              FROM JSON_TABLE(p_lineas, '$[*]' COLUMNS (
                       id_presentacion NUMBER PATH '$.id_presentacion',
                       cantidad        NUMBER PATH '$.cantidad',
                       descuento       NUMBER PATH '$.descuento',
                       valor_final     NUMBER PATH '$.valor_final')) j) LOOP
        BEGIN
            SELECT pre.pre_descripcion, pre.pre_cantidad_minima, v.var_sku, p.id_tarifa_iva, pv.precio, t.tiv_porcentaje,
                   NVL(ov.ofe_porcentaje, 0)
              INTO v_desc_pre, v_minima, v_sku, v_tarifa, v_precio, v_pct_iva, v_pct_ofe
            FROM presentacion pre
            JOIN variante v   ON v.id_variante = pre.id_variante
            JOIN producto p   ON p.id_producto = v.id_producto
            JOIN tarifa_iva t ON t.id_tarifa_iva = p.id_tarifa_iva
            JOIN v_precio_vigente pv ON pv.id_presentacion = pre.id_presentacion
            LEFT JOIN v_oferta_vigente ov ON ov.id_producto = p.id_producto
            WHERE pre.id_presentacion = r.id_presentacion
              AND pre.pre_activa = 1 AND v.var_activa = 1;
        EXCEPTION WHEN NO_DATA_FOUND THEN
            pr_error('La presentación ' || r.id_presentacion || ' no está disponible para la venta');
        END;
        IF r.cantidad < v_minima THEN
            pr_error('La compra mínima de ' || v_sku || ' (' || v_desc_pre || ') es ' || v_minima);
        END IF;
        v_desc := r.descuento;
        IF r.valor_final IS NOT NULL THEN
            -- se negocia desde el precio que ya tiene la oferta
            v_lista := ROUND(r.cantidad * v_precio, 2) - ROUND(r.cantidad * v_precio * v_pct_ofe / 100, 2);
            v_base  := fn_base_desde_final(r.valor_final, v_pct_iva, 1);
            IF v_base > v_lista THEN
                pr_error('El valor pactado (' || r.valor_final || ') supera el precio de lista de ' || v_sku || ' ('
                         || (v_lista + ROUND(v_lista * v_pct_iva / 100, 2)) || '); la negociación solo baja el precio');
            END IF;
            v_desc := v_lista - v_base;
        END IF;
        IF v_desc > 0 AND p_canal = 'WEB' THEN
            pr_error('Los descuentos negociados solo se permiten en tienda o WhatsApp, no en el e-commerce');
        END IF;
        INSERT INTO detalle_pedido (id_pedido, id_presentacion, dpe_cantidad, dpe_precio_unitario, dpe_descuento,
                                    id_tarifa_iva, id_usuario_descuento)
        VALUES (v_pedido, r.id_presentacion, r.cantidad, v_precio, v_desc, v_tarifa,
                CASE WHEN v_desc > 0 THEN p_vendedor END);
    END LOOP;

    INSERT INTO historial_estado_pedido (id_pedido, id_estado_pedido, id_usuario, hep_observacion)
    VALUES (v_pedido, 'PEN', v_usuario, 'Pedido creado');

    -- Productos que se venden por pieza (cuero): cada línea debe caber en
    -- una sola pieza, porque los retazos de varias piezas no se juntan
    FOR r IN (SELECT v.var_sku, dv.cantidad_base, p.id_unidad_medida AS unidad,
                     (SELECT MAX(s.saldo) FROM v_lote_saldo s WHERE s.id_variante = dv.id_variante) AS mayor
              FROM v_detalle_pedido_valor dv
              JOIN variante v ON v.id_variante = dv.id_variante
              JOIN producto p ON p.id_producto = v.id_producto
              WHERE dv.id_pedido = v_pedido AND p.prd_venta_por_pieza = 1) LOOP
        IF NVL(r.mayor, 0) < r.cantidad_base THEN
            pr_error('Ninguna pieza de ' || r.var_sku || ' alcanza para ' || r.cantidad_base || ' ' || r.unidad
                     || ' (la mayor tiene ' || NVL(r.mayor, 0) || ' ' || r.unidad || ')');
        END IF;
    END LOOP;

    -- Con este pedido ya reservado, ninguna variante puede quedar con disponible negativo
    FOR r IN (SELECT s.var_sku, s.disponible, s.unidad
              FROM v_stock_variante s
              WHERE s.disponible < 0
                AND s.id_variante IN (SELECT id_variante FROM v_detalle_pedido_valor WHERE id_pedido = v_pedido)) LOOP
        pr_error('Stock insuficiente para ' || r.var_sku || ': faltan ' || (-r.disponible) || ' ' || r.unidad);
    END LOOP;

    RETURN v_pedido;
END fn_crear_pedido;
/


-- Negociar una línea: devuelve el nuevo valor de la línea con IVA
CREATE OR REPLACE FUNCTION fn_negociar_linea(p_detalle_pedido IN NUMBER, p_valor_final IN NUMBER, p_usuario IN NUMBER,
                                             p_con_iva IN NUMBER DEFAULT 1)
RETURN NUMBER IS
    v_pedido  NUMBER;
    v_pct_iva NUMBER;
    v_canal   VARCHAR2(3);
    v_estado  VARCHAR2(3);
    v_lista   NUMBER;
    v_base    NUMBER;
    v_valor   NUMBER;
BEGIN
    fn_exigir_permiso(p_usuario, 'PRECIO_NEGOCIAR');
    BEGIN
        SELECT d.id_pedido, t.tiv_porcentaje INTO v_pedido, v_pct_iva
        FROM detalle_pedido d
        JOIN tarifa_iva t ON t.id_tarifa_iva = d.id_tarifa_iva
        WHERE d.id_detalle_pedido = p_detalle_pedido;
    EXCEPTION WHEN NO_DATA_FOUND THEN
        pr_error('La línea de pedido ' || p_detalle_pedido || ' no existe');
    END;
    SELECT id_canal_venta INTO v_canal FROM pedido WHERE id_pedido = v_pedido FOR UPDATE;
    IF v_canal = 'WEB' THEN
        pr_error('Los descuentos negociados solo se permiten en tienda o WhatsApp, no en el e-commerce');
    END IF;
    SELECT MAX(id_estado_pedido) INTO v_estado FROM v_pedido_estado_actual WHERE id_pedido = v_pedido;
    IF v_estado <> 'PEN' THEN
        pr_error('El pedido ' || v_pedido || ' está en estado ' || v_estado || ' y ya no se puede modificar');
    END IF;

    -- se negocia desde el precio que ya tiene la oferta
    SELECT valor_lista - descuento_oferta INTO v_lista
    FROM v_detalle_pedido_valor WHERE id_detalle_pedido = p_detalle_pedido;
    v_base := fn_base_desde_final(p_valor_final, v_pct_iva, p_con_iva);
    IF v_base > v_lista THEN
        pr_error('El valor pactado supera el precio de lista (' || (v_lista + ROUND(v_lista * v_pct_iva / 100, 2))
                 || ' con IVA); la negociación solo baja el precio');
    END IF;
    UPDATE detalle_pedido
    SET dpe_descuento = v_lista - v_base,
        id_usuario_descuento = CASE WHEN v_lista - v_base > 0 THEN p_usuario END
    WHERE id_detalle_pedido = p_detalle_pedido;
    SELECT base_imponible + iva INTO v_valor FROM v_detalle_pedido_valor WHERE id_detalle_pedido = p_detalle_pedido;
    RETURN v_valor;
END fn_negociar_linea;
/

-- Negociar el total del pedido ("le dejo todo en 100"): el valor final
-- incluye el envío, que no se rebaja; el descuento de los productos se
-- reparte en proporción al valor de cada línea. Devuelve el nuevo total.
CREATE OR REPLACE FUNCTION fn_negociar_pedido(p_pedido IN NUMBER, p_total_final IN NUMBER, p_usuario IN NUMBER,
                                              p_con_iva IN NUMBER DEFAULT 1)
RETURN NUMBER IS
    v_canal    VARCHAR2(3);
    v_estado   VARCHAR2(3);
    v_envio    NUMBER;
    v_objetivo NUMBER;
    v_suma     NUMBER;
    v_acum     NUMBER := 0;
    v_meta     NUMBER;
    v_base     NUMBER;
    v_n        NUMBER;
    v_i        NUMBER := 0;
    v_total    NUMBER;
BEGIN
    fn_exigir_permiso(p_usuario, 'PRECIO_NEGOCIAR');
    BEGIN
        SELECT id_canal_venta INTO v_canal FROM pedido WHERE id_pedido = p_pedido FOR UPDATE;
    EXCEPTION WHEN NO_DATA_FOUND THEN
        pr_error('El pedido ' || p_pedido || ' no existe');
    END;
    IF v_canal = 'WEB' THEN
        pr_error('Los descuentos negociados solo se permiten en tienda o WhatsApp, no en el e-commerce');
    END IF;
    SELECT MAX(id_estado_pedido) INTO v_estado FROM v_pedido_estado_actual WHERE id_pedido = p_pedido;
    IF v_estado <> 'PEN' THEN
        pr_error('El pedido ' || p_pedido || ' está en estado ' || v_estado || ' y ya no se puede modificar');
    END IF;

    SELECT NVL(SUM(e.env_costo + CASE WHEN p_con_iva = 1 THEN ROUND(e.env_costo * t.tiv_porcentaje / 100, 2) ELSE 0 END), 0)
      INTO v_envio
    FROM envio e JOIN tarifa_iva t ON t.id_tarifa_iva = e.id_tarifa_iva
    WHERE e.id_pedido = p_pedido;
    v_objetivo := p_total_final - v_envio;

    -- valor_lista aquí es el precio con oferta: la negociación parte de él
    SELECT SUM(valor_lista + CASE WHEN p_con_iva = 1 THEN ROUND(valor_lista * tiv_porcentaje / 100, 2) ELSE 0 END), COUNT(*)
      INTO v_suma, v_n
    FROM (SELECT valor_lista - descuento_oferta AS valor_lista, tiv_porcentaje
          FROM v_detalle_pedido_valor WHERE id_pedido = p_pedido);
    IF v_objetivo <= 0 THEN
        pr_error('El valor pactado no cubre ni el envío (' || v_envio || ')');
    END IF;
    IF v_objetivo > v_suma THEN
        pr_error('El valor pactado supera el precio de lista (' || (v_suma + v_envio) || '); la negociación solo baja el precio');
    END IF;

    -- La línea de mayor valor va al final y absorbe el redondeo
    FOR r IN (SELECT id_detalle_pedido, valor_lista, tiv_porcentaje,
                     valor_lista + CASE WHEN p_con_iva = 1 THEN ROUND(valor_lista * tiv_porcentaje / 100, 2) ELSE 0 END AS referencia
              FROM (SELECT id_detalle_pedido, valor_lista - descuento_oferta AS valor_lista, tiv_porcentaje
                    FROM v_detalle_pedido_valor WHERE id_pedido = p_pedido)
              ORDER BY 4, id_detalle_pedido) LOOP
        v_i := v_i + 1;
        v_meta := CASE WHEN v_i < v_n THEN ROUND(v_objetivo * r.referencia / v_suma, 2) ELSE v_objetivo - v_acum END;
        v_base := LEAST(fn_base_desde_final(v_meta, r.tiv_porcentaje, p_con_iva), r.valor_lista);
        v_acum := v_acum + v_base + CASE WHEN p_con_iva = 1 THEN ROUND(v_base * r.tiv_porcentaje / 100, 2) ELSE 0 END;
        UPDATE detalle_pedido
        SET dpe_descuento = r.valor_lista - v_base,
            id_usuario_descuento = CASE WHEN r.valor_lista - v_base > 0 THEN p_usuario END
        WHERE id_detalle_pedido = r.id_detalle_pedido;
    END LOOP;
    SELECT total INTO v_total FROM v_pedido_totales WHERE id_pedido = p_pedido;
    RETURN v_total;
END fn_negociar_pedido;
/


-- C5. Registrar un cliente (lo usa la tienda y el registro del e-commerce).
--     Si ya existe un cliente con ese correo, devuelve el mismo: un cliente
--     que compraba en tienda conserva su historial y su crédito al abrir
--     una cuenta en la web.
CREATE OR REPLACE FUNCTION fn_registrar_cliente(p_nombres IN VARCHAR2, p_apellidos IN VARCHAR2, p_correo IN VARCHAR2,
                                                p_telefono IN VARCHAR2 DEFAULT NULL)
RETURN NUMBER IS
    v_cliente NUMBER;
    v_correo  cliente.cli_correo%TYPE := LOWER(TRIM(p_correo));   -- '' es NULL en Oracle
    v_n       NUMBER;
BEGIN
    IF TRIM(p_nombres) IS NULL THEN
        pr_error('Indique el nombre del cliente');
    END IF;
    IF v_correo IS NOT NULL THEN
        SELECT MAX(id_cliente) INTO v_cliente FROM cliente WHERE cli_correo = v_correo;
    END IF;
    IF v_cliente IS NULL THEN
        INSERT INTO cliente (cli_nombres, cli_apellidos, cli_correo)
        VALUES (TRIM(p_nombres), TRIM(p_apellidos), v_correo)
        RETURNING id_cliente INTO v_cliente;
    END IF;
    IF p_telefono IS NOT NULL THEN
        SELECT COUNT(*) INTO v_n FROM telefono WHERE id_cliente = v_cliente AND tel_numero = p_telefono;
        IF v_n = 0 THEN
            INSERT INTO telefono (id_cliente, tel_numero) VALUES (v_cliente, p_telefono);
        END IF;
    END IF;
    RETURN v_cliente;
END fn_registrar_cliente;
/


-- C6. Pagos: cuando los aprobados cubren el total, el pedido pasa a PAG
CREATE OR REPLACE PROCEDURE fn_verificar_pago_completo(p_pedido IN NUMBER, p_usuario IN NUMBER) IS
    v_estado   VARCHAR2(3);
    v_cubierto NUMBER;
    v_credito  NUMBER;
    v_total    NUMBER;
BEGIN
    SELECT MAX(id_estado_pedido) INTO v_estado FROM v_pedido_estado_actual WHERE id_pedido = p_pedido;
    SELECT cubierto, credito INTO v_cubierto, v_credito FROM v_pedido_pagos WHERE id_pedido = p_pedido;
    SELECT total INTO v_total FROM v_pedido_totales WHERE id_pedido = p_pedido;
    IF v_estado = 'PEN' AND v_cubierto >= v_total THEN
        fn_cambiar_estado_pedido(p_pedido, 'PAG', p_usuario,
            CASE WHEN v_credito > 0 THEN 'Pago inicial y crédito aprobado' ELSE 'Pago completo' END);
    END IF;
END fn_verificar_pago_completo;
/

-- p_aprobado: 1 aprobado (efectivo, tarjeta aprobada), 0 pendiente de confirmar
CREATE OR REPLACE FUNCTION fn_registrar_pago(p_pedido IN NUMBER, p_metodo IN NUMBER, p_monto IN NUMBER, p_usuario IN NUMBER,
                                             p_referencia IN VARCHAR2 DEFAULT NULL, p_aprobado IN NUMBER DEFAULT 1)
RETURN NUMBER IS
    v_pago    NUMBER;
    v_estado  VARCHAR2(3);
    v_bloqueo NUMBER;
BEGIN
    fn_exigir_permiso(p_usuario, 'PAGO_REGISTRAR');
    SELECT MAX(id_pedido) INTO v_bloqueo FROM pedido WHERE id_pedido = p_pedido;
    IF v_bloqueo IS NOT NULL THEN
        SELECT id_pedido INTO v_bloqueo FROM pedido WHERE id_pedido = p_pedido FOR UPDATE;
    END IF;
    SELECT MAX(id_estado_pedido) INTO v_estado FROM v_pedido_estado_actual WHERE id_pedido = p_pedido;
    IF NVL(v_estado, '-') <> 'PEN' THEN
        pr_error('Solo se registran pagos de pedidos pendientes (pedido ' || p_pedido || ' en estado ' || NVL(v_estado, '-') || ')');
    END IF;
    INSERT INTO pago (id_pedido, id_metodo_pago, pag_monto, pag_referencia, pag_estado, id_usuario_registra)
    VALUES (p_pedido, p_metodo, p_monto, p_referencia,
            CASE WHEN p_aprobado = 1 THEN 'APROBADO' ELSE 'PENDIENTE' END, p_usuario)
    RETURNING id_pago INTO v_pago;
    fn_verificar_pago_completo(p_pedido, p_usuario);
    RETURN v_pago;
END fn_registrar_pago;
/

-- Respuesta de la pasarela o validación de una transferencia
CREATE OR REPLACE PROCEDURE fn_confirmar_pago(p_pago IN NUMBER, p_aprobado IN NUMBER, p_usuario IN NUMBER) IS
    v_pedido NUMBER;
BEGIN
    fn_exigir_permiso(p_usuario, 'PAGO_REGISTRAR');
    UPDATE pago SET pag_estado = CASE WHEN p_aprobado = 1 THEN 'APROBADO' ELSE 'RECHAZADO' END
    WHERE id_pago = p_pago AND pag_estado = 'PENDIENTE'
    RETURNING id_pedido INTO v_pedido;
    IF SQL%ROWCOUNT = 0 THEN
        pr_error('El pago ' || p_pago || ' no existe o ya fue confirmado');
    END IF;
    fn_verificar_pago_completo(v_pedido, p_usuario);
END fn_confirmar_pago;
/


-- C7. Consumo de lotes por FEFO/PEPS: primero lo que vence antes,
--     luego lo que ingresó primero. Puede repartir una salida en varios lotes.
CREATE OR REPLACE PROCEDURE fn_consumir_lotes(p_movimiento IN NUMBER, p_variante IN NUMBER, p_cantidad IN NUMBER,
                                              p_detalle_pedido IN NUMBER DEFAULT NULL) IS
    v_pendiente NUMBER := p_cantidad;
    v_tomar     NUMBER;
    v_sku       variante.var_sku%TYPE;
    v_unidad    producto.id_unidad_medida%TYPE;
BEGIN
    SELECT v.var_sku, p.id_unidad_medida INTO v_sku, v_unidad
    FROM variante v JOIN producto p ON p.id_producto = v.id_producto
    WHERE v.id_variante = p_variante
    FOR UPDATE OF v.id_variante;

    FOR r IN (SELECT id_lote, saldo
              FROM v_lote_saldo
              WHERE id_variante = p_variante AND saldo > 0
              ORDER BY lot_fecha_vencimiento NULLS LAST, fecha_ingreso, id_lote) LOOP
        EXIT WHEN v_pendiente <= 0;
        v_tomar := LEAST(r.saldo, v_pendiente);
        INSERT INTO detalle_movimiento (id_movimiento, id_lote, dmo_cantidad, id_detalle_pedido)
        VALUES (p_movimiento, r.id_lote, v_tomar, p_detalle_pedido);
        v_pendiente := v_pendiente - v_tomar;
    END LOOP;

    IF v_pendiente > 0 THEN
        pr_error('Stock insuficiente para ' || v_sku || ': faltan ' || v_pendiente || ' ' || v_unidad);
    END IF;
END fn_consumir_lotes;
/


-- C8. Emitir el comprobante del pedido pagado: factura (por defecto) o
--     nota de venta (p_tipo_comprobante = '02'). Descarga el inventario
--     (movimiento VEN por lotes) y pasa el pedido a FAC.
--     · Factura: exige comprador, respeta el tope de consumidor final,
--       genera la clave de acceso y entra a la cola del SRI (v_cola_sri).
--     · Nota de venta: comprador opcional, sin clave ni SRI; el número
--       puede ser el del talonario (p_secuencial) o el siguiente.
--     p_lotes (opcional): '[{"id_detalle_pedido": 9, "id_lote": 14}, ...]'
--       la pieza o lote que el vendedor escoge para cada línea; la línea
--       sale entera de ese lote. Sin elección: productos por pieza toman la
--       pieza más pequeña que alcance (aprovecha retazos); el resto, FEFO/PEPS.
CREATE OR REPLACE FUNCTION fn_facturar_pedido(p_pedido IN NUMBER, p_datos_facturacion IN NUMBER,
                                              p_punto_emision IN NUMBER, p_usuario IN NUMBER,
                                              p_lotes IN CLOB DEFAULT NULL,
                                              p_tipo_comprobante IN VARCHAR2 DEFAULT '01',
                                              p_secuencial IN NUMBER DEFAULT NULL)
RETURN NUMBER IS
    v_tipo        tipo_comprobante%ROWTYPE;
    v_df          datos_facturacion%ROWTYPE;
    v_lotes       CLOB := NVL(p_lotes, TO_CLOB('[]'));
    v_cliente     NUMBER;
    v_estado      VARCHAR2(3);
    v_max_cf      NUMBER;
    v_total       NUMBER;
    v_secuencial  NUMBER;
    v_comprobante NUMBER;
    v_movimiento  NUMBER;
    v_lote        NUMBER;
    v_bloqueo     NUMBER;
    v_n           NUMBER;
BEGIN
    fn_exigir_permiso(p_usuario, 'VENTA_FACTURAR');
    BEGIN
        SELECT * INTO v_tipo FROM tipo_comprobante WHERE id_tipo_comprobante = p_tipo_comprobante AND tco_en_venta = 1;
    EXCEPTION WHEN NO_DATA_FOUND THEN
        pr_error('El tipo de comprobante ' || p_tipo_comprobante || ' no se usa en ventas');
    END;

    BEGIN
        SELECT id_cliente INTO v_cliente FROM pedido WHERE id_pedido = p_pedido FOR UPDATE;
    EXCEPTION WHEN NO_DATA_FOUND THEN
        pr_error('El pedido ' || p_pedido || ' no existe');
    END;
    SELECT MAX(id_estado_pedido) INTO v_estado FROM v_pedido_estado_actual WHERE id_pedido = p_pedido;
    IF NVL(v_estado, '-') <> 'PAG' THEN
        pr_error('Solo se factura un pedido pagado (pedido ' || p_pedido || ' en estado ' || NVL(v_estado, '-') || ')');
    END IF;

    IF p_datos_facturacion IS NULL AND v_tipo.tco_electronico_sri = 1 THEN
        pr_error('La factura exige los datos del comprador (cédula, RUC o consumidor final)');
    END IF;
    IF p_datos_facturacion IS NOT NULL THEN
        BEGIN
            SELECT * INTO v_df FROM datos_facturacion WHERE id_datos_facturacion = p_datos_facturacion AND dfa_activo = 1;
        EXCEPTION WHEN NO_DATA_FOUND THEN
            pr_error('Los datos de facturación ' || p_datos_facturacion || ' no existen o están inactivos');
        END;
        IF v_df.id_cliente <> v_cliente AND v_df.id_tipo_identificacion <> '07' THEN
            pr_error('Los datos de facturación no pertenecen al cliente del pedido');
        END IF;
    END IF;
    IF p_secuencial IS NOT NULL AND v_tipo.tco_electronico_sri = 1 THEN
        pr_error('El número de una factura electrónica lo asigna el sistema');
    END IF;
    SELECT total INTO v_total FROM v_pedido_totales WHERE id_pedido = p_pedido;
    SELECT emp_max_consumidor_final INTO v_max_cf FROM empresa;
    IF v_tipo.tco_electronico_sri = 1 AND v_df.id_tipo_identificacion = '07' AND v_total > v_max_cf THEN
        pr_error('Las facturas de más de USD ' || v_max_cf || ' deben identificar al comprador (SRI); total del pedido: ' || v_total);
    END IF;
    SELECT COUNT(*) INTO v_n
    FROM JSON_TABLE(v_lotes, '$[*]' COLUMNS (id_detalle_pedido NUMBER PATH '$.id_detalle_pedido')) x
    WHERE NOT EXISTS (SELECT 1 FROM detalle_pedido d
                      WHERE d.id_detalle_pedido = x.id_detalle_pedido AND d.id_pedido = p_pedido);
    IF v_n > 0 THEN
        pr_error('Se indicaron lotes para líneas que no son del pedido ' || p_pedido);
    END IF;

    -- Secuencial por tipo y punto de emisión (bloqueo para que no se repita).
    -- La nota de venta puede traer el número impreso del talonario.
    BEGIN
        SELECT id_punto_emision INTO v_bloqueo FROM punto_emision
        WHERE id_punto_emision = p_punto_emision AND pem_activo = 1 FOR UPDATE;
    EXCEPTION WHEN NO_DATA_FOUND THEN
        pr_error('Punto de emisión ' || p_punto_emision || ' inexistente o inactivo');
    END;
    IF p_secuencial IS NOT NULL THEN
        SELECT COUNT(*) INTO v_n FROM comprobante_venta
        WHERE id_tipo_comprobante = p_tipo_comprobante AND id_punto_emision = p_punto_emision AND cve_secuencial = p_secuencial;
        IF v_n > 0 THEN
            pr_error('La ' || LOWER(v_tipo.tco_nombre) || ' número ' || p_secuencial || ' ya fue registrada');
        END IF;
        v_secuencial := p_secuencial;
    ELSE
        SELECT NVL(MAX(cve_secuencial), 0) + 1 INTO v_secuencial
        FROM comprobante_venta WHERE id_tipo_comprobante = p_tipo_comprobante AND id_punto_emision = p_punto_emision;
    END IF;

    INSERT INTO comprobante_venta (id_tipo_comprobante, id_pedido, id_datos_facturacion, id_punto_emision,
                                   cve_secuencial, id_usuario_emite, cve_clave_acceso, cve_estado)
    VALUES (p_tipo_comprobante, p_pedido, p_datos_facturacion, p_punto_emision, v_secuencial, p_usuario,
            CASE WHEN v_tipo.tco_electronico_sri = 1
                 THEN fn_clave_acceso(TRUNC(SYSDATE), p_tipo_comprobante, p_punto_emision, v_secuencial) END,
            CASE WHEN v_tipo.tco_electronico_sri = 1 THEN 'PENDIENTE' ELSE 'EMITIDA' END)
    RETURNING id_comprobante_venta INTO v_comprobante;

    -- Salida de inventario en unidad base
    INSERT INTO movimiento_inventario (id_tipo_movimiento, id_usuario, id_comprobante_venta)
    VALUES ('VEN', p_usuario, v_comprobante)
    RETURNING id_movimiento INTO v_movimiento;

    FOR r IN (SELECT dv.id_detalle_pedido, dv.id_variante, dv.cantidad_base, v.var_sku,
                     p.prd_venta_por_pieza AS por_pieza, p.id_unidad_medida AS unidad,
                     (SELECT MIN(x.id_lote)
                      FROM JSON_TABLE(v_lotes, '$[*]' COLUMNS (id_detalle_pedido NUMBER PATH '$.id_detalle_pedido',
                                                               id_lote           NUMBER PATH '$.id_lote')) x
                      WHERE x.id_detalle_pedido = dv.id_detalle_pedido) AS id_lote_elegido
              FROM v_detalle_pedido_valor dv
              JOIN variante v ON v.id_variante = dv.id_variante
              JOIN producto p ON p.id_producto = v.id_producto
              WHERE dv.id_pedido = p_pedido
              ORDER BY dv.id_variante, dv.id_detalle_pedido) LOOP
        IF r.id_lote_elegido IS NOT NULL THEN
            SELECT COUNT(*) INTO v_n FROM lote WHERE id_lote = r.id_lote_elegido AND id_variante = r.id_variante;
            IF v_n = 0 THEN
                pr_error('El lote ' || r.id_lote_elegido || ' no es de la variante ' || r.var_sku);
            END IF;
            INSERT INTO detalle_movimiento (id_movimiento, id_lote, dmo_cantidad, id_detalle_pedido)
            VALUES (v_movimiento, r.id_lote_elegido, r.cantidad_base, r.id_detalle_pedido);
        ELSIF r.por_pieza = 1 THEN
            SELECT id_variante INTO v_bloqueo FROM variante WHERE id_variante = r.id_variante FOR UPDATE;
            SELECT MIN(id_lote) KEEP (DENSE_RANK FIRST ORDER BY saldo, fecha_ingreso, id_lote) INTO v_lote
            FROM v_lote_saldo
            WHERE id_variante = r.id_variante AND saldo >= r.cantidad_base;
            IF v_lote IS NULL THEN
                pr_error('Ninguna pieza de ' || r.var_sku || ' alcanza para ' || r.cantidad_base || ' ' || r.unidad
                         || ' (los retazos no se juntan)');
            END IF;
            INSERT INTO detalle_movimiento (id_movimiento, id_lote, dmo_cantidad, id_detalle_pedido)
            VALUES (v_movimiento, v_lote, r.cantidad_base, r.id_detalle_pedido);
        ELSE
            fn_consumir_lotes(v_movimiento, r.id_variante, r.cantidad_base, r.id_detalle_pedido);
        END IF;
    END LOOP;

    fn_cambiar_estado_pedido(p_pedido, 'FAC', p_usuario, v_tipo.tco_nombre || ' emitida');
    pr_log('INFO', 'FACTURACION',
           CASE WHEN v_tipo.tco_electronico_sri = 1 THEN 'FACTURA_EMITIDA' ELSE 'NOTA_VENTA_EMITIDA' END,
           v_tipo.tco_nombre || ' ' || v_comprobante || ' del pedido ' || p_pedido,
           p_usuario, '{"id_comprobante_venta": ' || v_comprobante || ', "id_pedido": ' || p_pedido || '}');
    RETURN v_comprobante;
END fn_facturar_pedido;
/


-- C8b. Venta a crédito: el saldo no pagado del pedido queda como cuenta
--      por cobrar y el comprobante se emite en el mismo momento (la entrega
--      del bien es la que obliga a facturar, no el cobro).
CREATE OR REPLACE FUNCTION fn_facturar_a_credito(p_pedido IN NUMBER, p_plazo_dias IN NUMBER, p_datos_facturacion IN NUMBER,
                                                 p_punto_emision IN NUMBER, p_usuario IN NUMBER,
                                                 p_lotes IN CLOB DEFAULT NULL,
                                                 p_tipo_comprobante IN VARCHAR2 DEFAULT '01',
                                                 p_secuencial IN NUMBER DEFAULT NULL)
RETURN NUMBER IS
    v_saldo   NUMBER;
    v_tipo_id VARCHAR2(2);
    v_bloqueo NUMBER;
BEGIN
    fn_exigir_permiso(p_usuario, 'CREDITO_OTORGAR');
    IF p_plazo_dias IS NULL OR p_plazo_dias <= 0 THEN
        pr_error('Indique el plazo del crédito en días');
    END IF;
    SELECT MAX(id_pedido) INTO v_bloqueo FROM pedido WHERE id_pedido = p_pedido;
    IF v_bloqueo IS NOT NULL THEN
        SELECT id_pedido INTO v_bloqueo FROM pedido WHERE id_pedido = p_pedido FOR UPDATE;
    END IF;
    SELECT MAX(id_tipo_identificacion) INTO v_tipo_id FROM datos_facturacion WHERE id_datos_facturacion = p_datos_facturacion;
    IF p_datos_facturacion IS NULL OR v_tipo_id = '07' THEN
        pr_error('Una venta a crédito debe emitirse con la identificación del cliente, no a consumidor final');
    END IF;
    SELECT MAX(t.total - pp.cubierto) INTO v_saldo
    FROM v_pedido_totales t JOIN v_pedido_pagos pp ON pp.id_pedido = t.id_pedido
    WHERE t.id_pedido = p_pedido;
    IF v_saldo IS NULL OR v_saldo <= 0 THEN
        pr_error('El pedido ' || p_pedido || ' no tiene saldo por financiar');
    END IF;

    INSERT INTO cuenta_por_cobrar (id_pedido, cxc_tipo, cxc_monto, cxc_concepto, cxc_fecha_vencimiento, id_usuario_autoriza)
    VALUES (p_pedido, 'CREDITO', v_saldo, 'Saldo de la compra a crédito (' || p_plazo_dias || ' días)',
            TRUNC(SYSDATE) + p_plazo_dias, p_usuario);

    fn_verificar_pago_completo(p_pedido, p_usuario);
    RETURN fn_facturar_pedido(p_pedido, p_datos_facturacion, p_punto_emision, p_usuario, p_lotes,
                              p_tipo_comprobante, p_secuencial);
END fn_facturar_a_credito;
/

-- C8a. Nota de venta: atajo de fn_facturar_pedido con tipo 02. El número
--      del talonario es opcional (si no se indica, el siguiente).
CREATE OR REPLACE FUNCTION fn_emitir_nota_venta(p_pedido IN NUMBER, p_punto_emision IN NUMBER, p_usuario IN NUMBER,
                                                p_secuencial IN NUMBER DEFAULT NULL,
                                                p_datos_facturacion IN NUMBER DEFAULT NULL,
                                                p_lotes IN CLOB DEFAULT NULL)
RETURN NUMBER IS
BEGIN
    RETURN fn_facturar_pedido(p_pedido, p_datos_facturacion, p_punto_emision, p_usuario, p_lotes, '02', p_secuencial);
END fn_emitir_nota_venta;
/


-- C8c. Avance de dinero sobre una compra ya facturada (pasaje, material en
--      otro local). No es una venta: no va en el comprobante; queda como
--      deuda del cliente, dentro de su límite de crédito.
--      p_motivo: motivo_avance; si no se indica, 'Otro'.
CREATE OR REPLACE FUNCTION fn_registrar_avance(p_pedido IN NUMBER, p_monto IN NUMBER, p_concepto IN VARCHAR2,
                                               p_metodo_entrega IN NUMBER, p_plazo_dias IN NUMBER, p_usuario IN NUMBER,
                                               p_motivo IN NUMBER DEFAULT NULL)
RETURN NUMBER IS
    v_id     NUMBER;
    v_motivo NUMBER := p_motivo;
BEGIN
    fn_exigir_permiso(p_usuario, 'CREDITO_OTORGAR');
    IF p_plazo_dias IS NULL OR p_plazo_dias <= 0 THEN
        pr_error('Indique el plazo para devolver el avance');
    END IF;
    IF v_motivo IS NULL THEN
        SELECT MAX(id_motivo_avance) INTO v_motivo FROM motivo_avance WHERE mav_nombre = 'Otro';
    END IF;
    INSERT INTO cuenta_por_cobrar (id_pedido, cxc_tipo, cxc_monto, cxc_concepto, cxc_fecha_vencimiento,
                                   id_metodo_entrega, id_motivo_avance, id_usuario_autoriza)
    VALUES (p_pedido, 'AVANCE', p_monto, p_concepto, TRUNC(SYSDATE) + p_plazo_dias, p_metodo_entrega,
            v_motivo, p_usuario)
    RETURNING id_cuenta_por_cobrar INTO v_id;
    RETURN v_id;
END fn_registrar_avance;
/


-- C8d. Abonos del cliente: a una cuenta concreta, o repartido desde lo que
--      vence primero
CREATE OR REPLACE FUNCTION fn_registrar_abono(p_cuenta IN NUMBER, p_monto IN NUMBER, p_metodo IN NUMBER, p_usuario IN NUMBER,
                                              p_referencia IN VARCHAR2 DEFAULT NULL)
RETURN NUMBER IS
    v_id NUMBER;
BEGIN
    fn_exigir_permiso(p_usuario, 'PAGO_REGISTRAR');
    INSERT INTO abono_cliente (id_cuenta_por_cobrar, id_metodo_pago, abo_monto, abo_referencia, id_usuario_registra)
    VALUES (p_cuenta, p_metodo, p_monto, p_referencia, p_usuario)
    RETURNING id_abono_cliente INTO v_id;
    RETURN v_id;
END fn_registrar_abono;
/

CREATE OR REPLACE FUNCTION fn_abonar_cliente(p_cliente IN NUMBER, p_monto IN NUMBER, p_metodo IN NUMBER, p_usuario IN NUMBER,
                                             p_referencia IN VARCHAR2 DEFAULT NULL)
RETURN NUMBER IS
    v_deuda     NUMBER;
    v_pendiente NUMBER := p_monto;
    v_tomar     NUMBER;
    v_cuentas   NUMBER := 0;
    v_bloqueo   NUMBER;
BEGIN
    fn_exigir_permiso(p_usuario, 'PAGO_REGISTRAR');
    IF p_monto IS NULL OR p_monto <= 0 THEN
        pr_error('El abono debe ser mayor que cero');
    END IF;
    SELECT MAX(id_cliente) INTO v_bloqueo FROM cliente WHERE id_cliente = p_cliente;
    IF v_bloqueo IS NOT NULL THEN
        SELECT id_cliente INTO v_bloqueo FROM cliente WHERE id_cliente = p_cliente FOR UPDATE;
    END IF;
    SELECT NVL(MAX(deuda_total), 0) INTO v_deuda FROM v_estado_cuenta_cliente WHERE id_cliente = p_cliente;
    IF p_monto > v_deuda THEN
        pr_error('El abono (' || p_monto || ') supera la deuda del cliente (' || v_deuda || ')');
    END IF;

    FOR c IN (SELECT id_cuenta_por_cobrar, saldo
              FROM v_cuentas_por_cobrar
              WHERE id_cliente = p_cliente AND saldo > 0
              ORDER BY vencimiento, fecha, id_cuenta_por_cobrar) LOOP
        EXIT WHEN v_pendiente <= 0;
        v_tomar := LEAST(c.saldo, v_pendiente);
        INSERT INTO abono_cliente (id_cuenta_por_cobrar, id_metodo_pago, abo_monto, abo_referencia, id_usuario_registra)
        VALUES (c.id_cuenta_por_cobrar, p_metodo, v_tomar, p_referencia, p_usuario);
        v_pendiente := v_pendiente - v_tomar;
        v_cuentas := v_cuentas + 1;
    END LOOP;
    RETURN v_cuentas;
END fn_abonar_cliente;
/


-- C9. Nota de crédito por devolución (política de devoluciones)
--     p_lineas: '[{"id_detalle_pedido": 7, "cantidad": 1, "reingresa": true}, ...]'
--     · Valida el plazo (empresa.emp_dias_devolucion) y que no se devuelva
--       más de lo vendido (sumando notas anteriores).
--     · Sobre una factura la nota es electrónica (clave de acceso, va al
--       SRI); sobre una nota de venta se registra (EMITIDA, sin clave).
--     · Lo que reingresa vuelve a los MISMOS lotes de los que salió
--       (conserva costo y antigüedad); lo dañado no reingresa.
--     · Si el cliente debe algo de esa compra, se compensa primero.
CREATE OR REPLACE FUNCTION fn_emitir_nota_credito(p_comprobante IN NUMBER, p_motivo IN NUMBER, p_usuario IN NUMBER,
                                                  p_punto_emision IN NUMBER, p_lineas IN CLOB,
                                                  p_observacion IN VARCHAR2 DEFAULT NULL)
RETURN NUMBER IS
    v_fac        comprobante_venta%ROWTYPE;
    v_tipo_id    VARCHAR2(2);
    v_dias       NUMBER;
    v_secuencial NUMBER;
    v_nc         NUMBER;
    v_dnc        NUMBER;
    v_movimiento NUMBER;
    v_facturado  NUMBER;
    v_factor     NUMBER;
    v_acreditado NUMBER;
    v_pendiente  NUMBER;
    v_tomar      NUMBER;
    v_disponible NUMBER;
    v_bloqueo    NUMBER;
    v_n          NUMBER;
BEGIN
    fn_exigir_permiso(p_usuario, 'NC_EMITIR');

    BEGIN
        SELECT * INTO v_fac FROM comprobante_venta WHERE id_comprobante_venta = p_comprobante FOR UPDATE;
    EXCEPTION WHEN NO_DATA_FOUND THEN
        v_fac.cve_estado := 'ANULADA';
    END;
    IF v_fac.cve_estado = 'ANULADA' THEN
        pr_error('El comprobante ' || p_comprobante || ' no existe o está anulado');
    END IF;
    SELECT MAX(id_tipo_identificacion) INTO v_tipo_id FROM datos_facturacion
    WHERE id_datos_facturacion = v_fac.id_datos_facturacion;
    IF v_fac.id_tipo_comprobante = '01' AND v_tipo_id = '07' THEN
        pr_error('Una factura a consumidor final no admite nota de crédito (regla del SRI vigente desde 2026)');
    END IF;
    SELECT emp_dias_devolucion INTO v_dias FROM empresa;
    IF v_fac.cve_fechahora + NUMTODSINTERVAL(v_dias, 'DAY') < LOCALTIMESTAMP THEN
        pr_error('El comprobante ' || p_comprobante || ' superó el plazo de devolución de ' || v_dias || ' días');
    END IF;
    SELECT COUNT(*) INTO v_n FROM JSON_TABLE(p_lineas, '$[*]' COLUMNS (id_detalle_pedido NUMBER PATH '$.id_detalle_pedido'));
    IF p_lineas IS NULL OR v_n = 0 THEN
        pr_error('La nota de crédito no tiene líneas');
    END IF;

    BEGIN
        SELECT id_punto_emision INTO v_bloqueo FROM punto_emision
        WHERE id_punto_emision = p_punto_emision AND pem_activo = 1 FOR UPDATE;
    EXCEPTION WHEN NO_DATA_FOUND THEN
        pr_error('Punto de emisión ' || p_punto_emision || ' inexistente o inactivo');
    END;
    SELECT NVL(MAX(ncr_secuencial), 0) + 1 INTO v_secuencial
    FROM nota_credito WHERE id_punto_emision = p_punto_emision;

    INSERT INTO nota_credito (id_comprobante_venta, id_punto_emision, ncr_secuencial, id_motivo_devolucion,
                              id_usuario_autoriza, ncr_observacion, ncr_clave_acceso, ncr_estado)
    VALUES (p_comprobante, p_punto_emision, v_secuencial, p_motivo, p_usuario, p_observacion,
            CASE WHEN v_fac.id_tipo_comprobante = '01' THEN fn_clave_acceso(TRUNC(SYSDATE), '04', p_punto_emision, v_secuencial) END,
            CASE WHEN v_fac.id_tipo_comprobante = '01' THEN 'PENDIENTE' ELSE 'EMITIDA' END)
    RETURNING id_nota_credito INTO v_nc;

    FOR r IN (SELECT j.id_detalle_pedido, j.cantidad,
                     CASE WHEN LOWER(j.reingresa) IN ('false', '0') THEN 0 ELSE 1 END AS reingresa
              FROM JSON_TABLE(p_lineas, '$[*]' COLUMNS (
                       id_detalle_pedido NUMBER       PATH '$.id_detalle_pedido',
                       cantidad          NUMBER       PATH '$.cantidad',
                       reingresa         VARCHAR2(5)  PATH '$.reingresa')) j) LOOP
        BEGIN
            SELECT d.dpe_cantidad, pr.pre_factor INTO v_facturado, v_factor
            FROM detalle_pedido d
            JOIN presentacion pr ON pr.id_presentacion = d.id_presentacion
            WHERE d.id_detalle_pedido = r.id_detalle_pedido AND d.id_pedido = v_fac.id_pedido;
        EXCEPTION WHEN NO_DATA_FOUND THEN
            pr_error('La línea ' || r.id_detalle_pedido || ' no pertenece al comprobante ' || p_comprobante);
        END;

        SELECT NVL(SUM(dn.dnc_cantidad), 0) INTO v_acreditado
        FROM detalle_nota_credito dn
        JOIN nota_credito n ON n.id_nota_credito = dn.id_nota_credito
        WHERE dn.id_detalle_pedido = r.id_detalle_pedido AND n.ncr_estado <> 'ANULADA';
        IF v_acreditado + r.cantidad > v_facturado THEN
            pr_error('Se intenta devolver ' || r.cantidad || ' de la línea ' || r.id_detalle_pedido
                     || ', pero solo quedan ' || (v_facturado - v_acreditado) || ' por devolver');
        END IF;

        INSERT INTO detalle_nota_credito (id_nota_credito, id_detalle_pedido, dnc_cantidad, dnc_reingresa_stock)
        VALUES (v_nc, r.id_detalle_pedido, r.cantidad, r.reingresa)
        RETURNING id_detalle_nota_credito INTO v_dnc;

        IF r.reingresa = 1 THEN
            IF v_movimiento IS NULL THEN
                INSERT INTO movimiento_inventario (id_tipo_movimiento, id_usuario, id_nota_credito)
                VALUES ('DCL', p_usuario, v_nc)
                RETURNING id_movimiento INTO v_movimiento;
            END IF;

            -- Devuelve a los lotes de origen, empezando por el último consumido
            v_pendiente := r.cantidad * v_factor;
            FOR l IN (SELECT dm.id_lote,
                             SUM(dm.dmo_cantidad) - NVL((
                                 SELECT SUM(dd.dmo_cantidad)
                                 FROM detalle_movimiento dd
                                 JOIN detalle_nota_credito dn2 ON dn2.id_detalle_nota_credito = dd.id_detalle_nota_credito
                                 WHERE dn2.id_detalle_pedido = r.id_detalle_pedido AND dd.id_lote = dm.id_lote), 0) AS devolvible,
                             MAX(dm.id_detalle_movimiento) AS orden
                      FROM detalle_movimiento dm
                      WHERE dm.id_detalle_pedido = r.id_detalle_pedido
                      GROUP BY dm.id_lote
                      ORDER BY orden DESC) LOOP
                EXIT WHEN v_pendiente <= 0;
                CONTINUE WHEN l.devolvible <= 0;
                v_tomar := LEAST(l.devolvible, v_pendiente);
                INSERT INTO detalle_movimiento (id_movimiento, id_lote, dmo_cantidad, id_detalle_nota_credito)
                VALUES (v_movimiento, l.id_lote, v_tomar, v_dnc);
                v_pendiente := v_pendiente - v_tomar;
            END LOOP;
            IF v_pendiente > 0 THEN
                pr_error('No se encontró el lote de origen de la línea ' || r.id_detalle_pedido);
            END IF;
        END IF;
    END LOOP;

    -- Si el cliente debe algo de esa misma compra (crédito o avance), la nota
    -- de crédito se compensa primero con esa deuda; lo que sobre se reembolsa
    SELECT total INTO v_disponible FROM v_nota_credito WHERE id_nota_credito = v_nc;
    FOR c IN (SELECT id_cuenta_por_cobrar, saldo
              FROM v_cuentas_por_cobrar
              WHERE id_pedido = v_fac.id_pedido AND saldo > 0
              ORDER BY CASE tipo WHEN 'CREDITO' THEN 0 ELSE 1 END, fecha, id_cuenta_por_cobrar) LOOP
        EXIT WHEN v_disponible <= 0;
        v_tomar := LEAST(c.saldo, v_disponible);
        INSERT INTO abono_cliente (id_cuenta_por_cobrar, id_nota_credito, abo_monto, abo_referencia, id_usuario_registra)
        VALUES (c.id_cuenta_por_cobrar, v_nc, v_tomar, 'Compensación con nota de crédito', p_usuario);
        v_disponible := v_disponible - v_tomar;
    END LOOP;

    pr_log('INFO', 'FACTURACION', 'NC_EMITIDA', 'Nota de crédito ' || v_nc || ' sobre el comprobante ' || p_comprobante,
           p_usuario, '{"id_nota_credito": ' || v_nc || ', "id_comprobante_venta": ' || p_comprobante || '}');
    RETURN v_nc;
END fn_emitir_nota_credito;
/


-- C9b. Respuesta del SRI (la registra el servicio que transmite).
--      p_tipo: 'FACTURA' o 'NOTA_CREDITO'; p_estado: 'AUTORIZADA' o 'RECHAZADA'
CREATE OR REPLACE PROCEDURE fn_registrar_respuesta_sri(p_tipo IN VARCHAR2, p_id IN NUMBER, p_estado IN VARCHAR2,
                                                       p_usuario IN NUMBER,
                                                       p_fecha_autorizacion IN TIMESTAMP DEFAULT LOCALTIMESTAMP) IS
BEGIN
    fn_exigir_permiso(p_usuario, 'SRI_GESTIONAR');
    IF p_estado IS NULL OR p_estado NOT IN ('AUTORIZADA', 'RECHAZADA') THEN
        pr_error('Respuesta del SRI no válida: ' || p_estado);
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
        pr_error('Tipo de comprobante no válido: ' || p_tipo);
    END IF;
    IF SQL%ROWCOUNT = 0 THEN
        pr_error('El comprobante ' || p_tipo || ' ' || p_id || ' no existe o ya fue procesado');
    END IF;
    pr_log(CASE WHEN p_estado = 'RECHAZADA' THEN 'ERROR' ELSE 'INFO' END, 'SRI', 'SRI_' || p_estado,
           'Comprobante ' || p_tipo || ' ' || p_id || ': ' || p_estado || ' por el SRI', p_usuario,
           '{"tipo": "' || p_tipo || '", "id": ' || p_id || '}');
END fn_registrar_respuesta_sri;
/


-- C10. Compras: cambio de estado de la OC con permiso
CREATE OR REPLACE PROCEDURE fn_cambiar_estado_oc(p_orden IN NUMBER, p_estado IN VARCHAR2, p_usuario IN NUMBER) IS
BEGIN
    fn_exigir_permiso(p_usuario, 'COMPRA_GESTIONAR');
    UPDATE orden_compra SET oc_estado = p_estado WHERE id_orden_compra = p_orden;
    IF SQL%ROWCOUNT = 0 THEN
        pr_error('La OC ' || p_orden || ' no existe');
    END IF;
END fn_cambiar_estado_oc;
/


-- C11. Recepción de mercadería (total o parcial). Cada línea crea un lote
--      con el costo real (si no se indica, el pactado en la OC).
--      p_lineas: '[{"id_detalle_orden_compra": 1, "cantidad": 90,
--                   "costo_unitario": 4.10, "fecha_vencimiento": "2027-01-15",
--                   "codigo_lote": "L-889"}, ...]'
CREATE OR REPLACE FUNCTION fn_recepcionar_compra(p_orden IN NUMBER, p_usuario IN NUMBER, p_lineas IN CLOB,
                                                 p_comprobante_compra IN NUMBER DEFAULT NULL,
                                                 p_fechahora IN TIMESTAMP DEFAULT LOCALTIMESTAMP)
RETURN NUMBER IS
    v_movimiento NUMBER;
    v_lote       NUMBER;
    v_bloqueo    NUMBER;
    d            v_orden_compra_detalle%ROWTYPE;
BEGIN
    fn_exigir_permiso(p_usuario, 'INV_RECEPCIONAR');
    SELECT MAX(id_orden_compra) INTO v_bloqueo FROM orden_compra WHERE id_orden_compra = p_orden;
    IF v_bloqueo IS NOT NULL THEN
        SELECT id_orden_compra INTO v_bloqueo FROM orden_compra WHERE id_orden_compra = p_orden FOR UPDATE;
    END IF;

    INSERT INTO movimiento_inventario (id_tipo_movimiento, mov_fechahora, id_usuario, id_orden_compra, id_comprobante_compra)
    VALUES ('COM', p_fechahora, p_usuario, p_orden, p_comprobante_compra)
    RETURNING id_movimiento INTO v_movimiento;

    FOR r IN (SELECT j.*
              FROM JSON_TABLE(p_lineas, '$[*]' COLUMNS (
                       id_detalle_orden_compra NUMBER        PATH '$.id_detalle_orden_compra',
                       cantidad                NUMBER        PATH '$.cantidad',
                       costo_unitario          NUMBER        PATH '$.costo_unitario',
                       fecha_vencimiento       VARCHAR2(10)  PATH '$.fecha_vencimiento',
                       codigo_lote             VARCHAR2(30)  PATH '$.codigo_lote')) j) LOOP
        BEGIN
            SELECT * INTO d FROM v_orden_compra_detalle
            WHERE id_detalle_orden_compra = r.id_detalle_orden_compra AND id_orden_compra = p_orden;
        EXCEPTION WHEN NO_DATA_FOUND THEN
            pr_error('La línea ' || r.id_detalle_orden_compra || ' no pertenece a la OC ' || p_orden);
        END;
        IF r.cantidad > d.cantidad_pendiente THEN
            pr_error('Se intenta recibir ' || r.cantidad || ' de ' || d.var_sku || ', pero solo quedan '
                     || d.cantidad_pendiente || ' pendientes');
        END IF;

        INSERT INTO lote (id_variante, lot_costo_unitario, lot_fecha_vencimiento, lot_codigo_proveedor)
        VALUES (d.id_variante, NVL(r.costo_unitario, d.costo_pactado), TO_DATE(r.fecha_vencimiento, 'YYYY-MM-DD'), r.codigo_lote)
        RETURNING id_lote INTO v_lote;

        INSERT INTO detalle_movimiento (id_movimiento, id_lote, dmo_cantidad, id_detalle_orden_compra)
        VALUES (v_movimiento, v_lote, r.cantidad, r.id_detalle_orden_compra);
    END LOOP;

    RETURN v_movimiento;
END fn_recepcionar_compra;
/


-- C12. Devolución a proveedor de mercadería de un lote recibido
CREATE OR REPLACE FUNCTION fn_devolver_a_proveedor(p_lote IN NUMBER, p_cantidad IN NUMBER, p_motivo IN VARCHAR2,
                                                   p_usuario IN NUMBER)
RETURN NUMBER IS
    v_orden      NUMBER;
    v_movimiento NUMBER;
BEGIN
    fn_exigir_permiso(p_usuario, 'COMPRA_GESTIONAR');
    SELECT MAX(m.id_orden_compra) INTO v_orden
    FROM detalle_movimiento dm
    JOIN movimiento_inventario m ON m.id_movimiento = dm.id_movimiento
    WHERE dm.id_lote = p_lote AND m.id_tipo_movimiento = 'COM';
    IF v_orden IS NULL THEN
        pr_error('El lote ' || p_lote || ' no proviene de una compra');
    END IF;

    INSERT INTO movimiento_inventario (id_tipo_movimiento, id_usuario, mov_motivo, id_orden_compra)
    VALUES ('DPR', p_usuario, p_motivo, v_orden)
    RETURNING id_movimiento INTO v_movimiento;
    INSERT INTO detalle_movimiento (id_movimiento, id_lote, dmo_cantidad)
    VALUES (v_movimiento, p_lote, p_cantidad);
    RETURN v_movimiento;
END fn_devolver_a_proveedor;
/


-- C13. Inventario inicial, ajustes por conteo físico y mermas
--      INI / AJP crean un lote (costo obligatorio en INI; en AJP, si no se
--      indica, se usa el del último lote). AJN / MER consumen por FEFO/PEPS
--      o de un lote específico (p_lote).
CREATE OR REPLACE FUNCTION fn_registrar_ajuste(p_variante IN NUMBER, p_tipo IN VARCHAR2, p_cantidad IN NUMBER,
                                               p_motivo IN VARCHAR2, p_usuario IN NUMBER,
                                               p_costo_unitario IN NUMBER DEFAULT NULL,
                                               p_fecha_vencimiento IN DATE DEFAULT NULL,
                                               p_lote IN NUMBER DEFAULT NULL,
                                               p_fechahora IN TIMESTAMP DEFAULT LOCALTIMESTAMP)
RETURN NUMBER IS
    v_movimiento NUMBER;
    v_lote       NUMBER;
    v_costo      NUMBER := p_costo_unitario;
    v_n          NUMBER;
BEGIN
    fn_exigir_permiso(p_usuario, 'INV_AJUSTAR');
    IF p_tipo IS NULL OR p_tipo NOT IN ('INI', 'AJP', 'AJN', 'MER') THEN
        pr_error('Tipo de ajuste no válido: ' || p_tipo);
    END IF;
    IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
        pr_error('La cantidad del ajuste debe ser mayor que cero');
    END IF;

    INSERT INTO movimiento_inventario (id_tipo_movimiento, mov_fechahora, id_usuario, mov_motivo)
    VALUES (p_tipo, p_fechahora, p_usuario, p_motivo)
    RETURNING id_movimiento INTO v_movimiento;

    IF p_tipo IN ('INI', 'AJP') THEN
        IF v_costo IS NULL AND p_tipo = 'AJP' THEN
            SELECT MAX(lot_costo_unitario) KEEP (DENSE_RANK LAST ORDER BY id_lote) INTO v_costo
            FROM lote WHERE id_variante = p_variante;
        END IF;
        IF v_costo IS NULL THEN
            pr_error('Indique el costo unitario del ingreso');
        END IF;
        INSERT INTO lote (id_variante, lot_costo_unitario, lot_fecha_vencimiento)
        VALUES (p_variante, v_costo, p_fecha_vencimiento)
        RETURNING id_lote INTO v_lote;
        INSERT INTO detalle_movimiento (id_movimiento, id_lote, dmo_cantidad)
        VALUES (v_movimiento, v_lote, p_cantidad);
    ELSIF p_lote IS NOT NULL THEN
        SELECT COUNT(*) INTO v_n FROM lote WHERE id_lote = p_lote AND id_variante = p_variante;
        IF v_n = 0 THEN
            pr_error('El lote ' || p_lote || ' no pertenece a la variante indicada');
        END IF;
        INSERT INTO detalle_movimiento (id_movimiento, id_lote, dmo_cantidad)
        VALUES (v_movimiento, p_lote, p_cantidad);
    ELSE
        fn_consumir_lotes(v_movimiento, p_variante, p_cantidad);
    END IF;

    pr_log(CASE WHEN p_tipo IN ('AJN', 'MER') THEN 'AVISO' ELSE 'INFO' END, 'INVENTARIO', 'AJUSTE_INVENTARIO',
           p_tipo || ' de ' || p_cantidad || ' (variante ' || p_variante || '): ' || p_motivo,
           p_usuario, '{"id_movimiento": ' || v_movimiento || '}');
    RETURN v_movimiento;
END fn_registrar_ajuste;
/


-- C13b. Fraccionar una pieza (banda) en paquetes, p. ej. dos medias bandas.
--       p_piezas: '[11.20, 11.20]' en unidad base. Sale lo cortado de la
--       pieza (FRS) y entra cada paquete como lote nuevo (FRE) con la pieza
--       de origen: conserva costo, vencimiento y antigüedad. Lo que no se
--       corta queda en la pieza original. Devuelve los lotes nuevos.
CREATE OR REPLACE FUNCTION fn_fraccionar_lote(p_lote IN NUMBER, p_piezas IN CLOB, p_usuario IN NUMBER,
                                              p_motivo IN VARCHAR2 DEFAULT NULL)
RETURN SYS.ODCINUMBERLIST IS
    v_l      lote%ROWTYPE;
    v_total  NUMBER;
    v_n      NUMBER;
    v_malas  NUMBER;
    v_motivo movimiento_inventario.mov_motivo%TYPE;
    v_frs    NUMBER;
    v_fre    NUMBER;
    v_nuevo  NUMBER;
    v_lotes  SYS.ODCINUMBERLIST := SYS.ODCINUMBERLIST();
BEGIN
    fn_exigir_permiso(p_usuario, 'INV_FRACCIONAR');
    BEGIN
        SELECT * INTO v_l FROM lote WHERE id_lote = p_lote;
    EXCEPTION WHEN NO_DATA_FOUND THEN
        pr_error('El lote ' || p_lote || ' no existe');
    END;
    SELECT COUNT(*), SUM(medida), COUNT(CASE WHEN medida IS NULL OR medida <= 0 THEN 1 END)
      INTO v_n, v_total, v_malas
    FROM JSON_TABLE(p_piezas, '$[*]' COLUMNS (medida NUMBER PATH '$'));
    IF p_piezas IS NULL OR v_n = 0 THEN
        pr_error('Indique las medidas de los paquetes (por ejemplo [11.20, 11.20])');
    END IF;
    IF v_malas > 0 THEN
        pr_error('Cada paquete debe medir más de cero');
    END IF;
    v_motivo := NVL(p_motivo, 'Fraccionamiento de ' || NVL(v_l.lot_codigo_proveedor, 'lote ' || p_lote));

    INSERT INTO movimiento_inventario (id_tipo_movimiento, id_usuario, mov_motivo)
    VALUES ('FRS', p_usuario, v_motivo) RETURNING id_movimiento INTO v_frs;
    INSERT INTO detalle_movimiento (id_movimiento, id_lote, dmo_cantidad)
    VALUES (v_frs, p_lote, v_total);

    INSERT INTO movimiento_inventario (id_tipo_movimiento, id_usuario, mov_motivo)
    VALUES ('FRE', p_usuario, v_motivo) RETURNING id_movimiento INTO v_fre;
    FOR x IN (SELECT n, medida
              FROM JSON_TABLE(p_piezas, '$[*]' COLUMNS (n FOR ORDINALITY, medida NUMBER PATH '$'))
              ORDER BY n) LOOP
        INSERT INTO lote (id_variante, lot_costo_unitario, lot_fecha_vencimiento, lot_codigo_proveedor, id_lote_origen)
        VALUES (v_l.id_variante, v_l.lot_costo_unitario, v_l.lot_fecha_vencimiento,
                SUBSTR(NVL(v_l.lot_codigo_proveedor, 'L' || p_lote), 1, 26) || '-' || x.n, p_lote)
        RETURNING id_lote INTO v_nuevo;
        INSERT INTO detalle_movimiento (id_movimiento, id_lote, dmo_cantidad)
        VALUES (v_fre, v_nuevo, x.medida);
        v_lotes.EXTEND;
        v_lotes(v_lotes.COUNT) := v_nuevo;
    END LOOP;
    RETURN v_lotes;
END fn_fraccionar_lote;
/


-- C13c. Buscar cuánto debe un cliente por nombre, cédula/RUC, teléfono o
--       correo. Devuelve un cursor con las filas de v_deuda_cliente:
--         VAR c REFCURSOR
--         EXEC :c := fn_buscar_deuda_cliente('perez')
--         PRINT c
CREATE OR REPLACE FUNCTION fn_buscar_deuda_cliente(p_texto IN VARCHAR2)
RETURN SYS_REFCURSOR IS
    c SYS_REFCURSOR;
    v VARCHAR2(4000) := '%' || UPPER(p_texto) || '%';
BEGIN
    OPEN c FOR
        SELECT d.*
        FROM v_deuda_cliente d
        JOIN cliente cl ON cl.id_cliente = d.id_cliente
        WHERE UPPER(d.cliente) LIKE v
           OR UPPER(d.identificaciones) LIKE v
           OR UPPER(d.telefonos) LIKE v
           OR UPPER(cl.cli_correo) LIKE v
        ORDER BY d.deuda_total DESC, d.cliente;
    RETURN c;
END fn_buscar_deuda_cliente;
/


-- C13d. Proveedores: asociar el comprobante que llegó después de la
--       mercadería, y registrar la nota de crédito del proveedor
CREATE OR REPLACE PROCEDURE fn_asociar_comprobante_compra(p_movimiento IN NUMBER, p_comprobante_compra IN NUMBER,
                                                          p_usuario IN NUMBER) IS
BEGIN
    fn_exigir_permiso(p_usuario, 'COMPRA_GESTIONAR');
    UPDATE movimiento_inventario SET id_comprobante_compra = p_comprobante_compra WHERE id_movimiento = p_movimiento;
    IF SQL%ROWCOUNT = 0 THEN
        pr_error('La recepción ' || p_movimiento || ' no existe');
    END IF;
END fn_asociar_comprobante_compra;
/

CREATE OR REPLACE FUNCTION fn_registrar_nc_proveedor(p_comprobante_compra IN NUMBER, p_numero IN VARCHAR2, p_fecha IN DATE,
                                                     p_subtotal_0 IN NUMBER, p_subtotal_gravado IN NUMBER, p_iva IN NUMBER,
                                                     p_motivo IN VARCHAR2, p_usuario IN NUMBER,
                                                     p_clave_acceso IN VARCHAR2 DEFAULT NULL)
RETURN NUMBER IS
    v_id NUMBER;
BEGIN
    fn_exigir_permiso(p_usuario, 'COMPRA_GESTIONAR');
    INSERT INTO nota_credito_proveedor (id_comprobante_compra, ncp_numero, ncp_clave_acceso, ncp_fecha_emision,
                                        ncp_subtotal_0, ncp_subtotal_gravado, ncp_iva, ncp_motivo, id_usuario_registra)
    VALUES (p_comprobante_compra, p_numero, p_clave_acceso, p_fecha, NVL(p_subtotal_0, 0),
            NVL(p_subtotal_gravado, 0), NVL(p_iva, 0), p_motivo, p_usuario)
    RETURNING id_nota_credito_proveedor INTO v_id;
    RETURN v_id;
END fn_registrar_nc_proveedor;
/


-- C16. Registrar el comprobante de una compra: factura '01' (con sus datos
--      del SRI e IVA), nota de venta '02' o sin comprobante '00' (recibo).
--      Las dos últimas van sin IVA (su valor completo en p_subtotal_0).
CREATE OR REPLACE FUNCTION fn_registrar_comprobante_compra(p_proveedor IN NUMBER, p_tipo IN VARCHAR2, p_numero IN VARCHAR2,
                                                           p_fecha_emision IN DATE, p_fecha_vencimiento IN DATE,
                                                           p_subtotal_0 IN NUMBER, p_subtotal_gravado IN NUMBER, p_iva IN NUMBER,
                                                           p_usuario IN NUMBER, p_clave_acceso IN VARCHAR2 DEFAULT NULL)
RETURN NUMBER IS
    v_id NUMBER;
BEGIN
    fn_exigir_permiso(p_usuario, 'COMPRA_GESTIONAR');
    INSERT INTO comprobante_compra (id_proveedor, id_tipo_comprobante, cco_numero, cco_clave_acceso, cco_fecha_emision,
                                    cco_fecha_vencimiento, cco_subtotal_0, cco_subtotal_gravado, cco_iva, id_usuario_registra)
    VALUES (p_proveedor, p_tipo, TRIM(p_numero), p_clave_acceso, p_fecha_emision, p_fecha_vencimiento,
            NVL(p_subtotal_0, 0), NVL(p_subtotal_gravado, 0), NVL(p_iva, 0), p_usuario)
    RETURNING id_comprobante_compra INTO v_id;
    RETURN v_id;
END fn_registrar_comprobante_compra;
/


-- C15. Ofertas: el descuento preestablecido de un producto. Registrar una
--      oferta (inmediata o programada) y cambiar su estado (pausar,
--      reactivar o ponerle fin). El porcentaje no se edita una vez usada.
CREATE OR REPLACE FUNCTION fn_registrar_oferta(p_producto IN NUMBER, p_porcentaje IN NUMBER, p_usuario IN NUMBER,
                                               p_desde IN TIMESTAMP DEFAULT LOCALTIMESTAMP,
                                               p_hasta IN TIMESTAMP DEFAULT NULL,
                                               p_descripcion IN VARCHAR2 DEFAULT NULL)
RETURN NUMBER IS
    v_id NUMBER;
BEGIN
    fn_exigir_permiso(p_usuario, 'PRECIO_GESTIONAR');
    INSERT INTO oferta (id_producto, ofe_porcentaje, ofe_descripcion, ofe_desde, ofe_hasta, id_usuario_registra)
    VALUES (p_producto, p_porcentaje, p_descripcion, p_desde, p_hasta, p_usuario)
    RETURNING id_oferta INTO v_id;
    RETURN v_id;
END fn_registrar_oferta;
/

-- p_activa: 1 activa, 0 pausada
CREATE OR REPLACE PROCEDURE fn_cambiar_estado_oferta(p_oferta IN NUMBER, p_activa IN NUMBER, p_usuario IN NUMBER,
                                                     p_hasta IN TIMESTAMP DEFAULT NULL) IS
BEGIN
    fn_exigir_permiso(p_usuario, 'PRECIO_GESTIONAR');
    UPDATE oferta
    SET ofe_activa = p_activa,
        ofe_hasta  = NVL(p_hasta, ofe_hasta)
    WHERE id_oferta = p_oferta;
    IF SQL%ROWCOUNT = 0 THEN
        pr_error('La oferta ' || p_oferta || ' no existe');
    END IF;
END fn_cambiar_estado_oferta;
/


-- C14. Cambio de precio (inmediato o programado)
CREATE OR REPLACE FUNCTION fn_registrar_precio(p_presentacion IN NUMBER, p_precio IN NUMBER, p_usuario IN NUMBER,
                                               p_vigente_desde IN TIMESTAMP DEFAULT LOCALTIMESTAMP)
RETURN NUMBER IS
    v_id NUMBER;
BEGIN
    fn_exigir_permiso(p_usuario, 'PRECIO_GESTIONAR');
    INSERT INTO historial_precio (id_presentacion, hpr_precio, hpr_vigente_desde, id_usuario)
    VALUES (p_presentacion, p_precio, p_vigente_desde, p_usuario)
    RETURNING id_historial_precio INTO v_id;
    RETURN v_id;
END fn_registrar_precio;
/


-- =====================================================================
-- D. NODO E-COMMERCE (usuario/esquema ECOMMERCE)
--    Lo que la tienda en línea escribe por su cuenta (cuentas web,
--    carritos y su bitácora) y su interfaz con producción:
--    · lee catálogo, pedidos y clientes por vistas (al separar los
--      nodos: vistas materializadas sobre un DATABASE LINK);
--    · le pide a producción crear clientes y pedidos llamando a sus
--      funciones (al separar los nodos: fn_crear_pedido@produccion).
--    Producción nunca lee ni escribe este esquema.
-- =====================================================================

-- D0. Lo que producción le permite al e-commerce (el contrato entre nodos).
--     Las vistas del e-commerce se apoyan en estos permisos, por eso van
--     antes. WITH GRANT OPTION permite que el e-commerce comparta sus
--     propias vistas con el rol de su aplicación.
GRANT SELECT ON produccion.v_catalogo             TO ecommerce WITH GRANT OPTION;
GRANT SELECT ON produccion.v_categoria_principal  TO ecommerce WITH GRANT OPTION;
GRANT SELECT ON produccion.v_oferta_vigente       TO ecommerce WITH GRANT OPTION;
GRANT SELECT ON produccion.v_pedido_estado_actual TO ecommerce WITH GRANT OPTION;
GRANT SELECT ON produccion.v_pedido_totales       TO ecommerce WITH GRANT OPTION;
GRANT SELECT ON produccion.v_comprobante_venta    TO ecommerce WITH GRANT OPTION;
GRANT SELECT ON produccion.v_frecuencia_cliente   TO ecommerce WITH GRANT OPTION;
GRANT SELECT ON produccion.pedido                 TO ecommerce WITH GRANT OPTION;
GRANT SELECT ON produccion.cliente                TO ecommerce WITH GRANT OPTION;
GRANT SELECT ON produccion.telefono               TO ecommerce WITH GRANT OPTION;
GRANT SELECT ON produccion.direccion              TO ecommerce WITH GRANT OPTION;
GRANT SELECT ON produccion.datos_facturacion      TO ecommerce WITH GRANT OPTION;
GRANT SELECT ON produccion.ciudad                 TO ecommerce WITH GRANT OPTION;
GRANT SELECT ON produccion.provincia              TO ecommerce WITH GRANT OPTION;
GRANT SELECT ON produccion.tipo_identificacion    TO ecommerce WITH GRANT OPTION;
GRANT INSERT ON produccion.telefono               TO ecommerce;
GRANT INSERT ON produccion.direccion              TO ecommerce;
GRANT INSERT ON produccion.datos_facturacion      TO ecommerce;
GRANT EXECUTE ON produccion.fn_crear_pedido       TO ecommerce WITH GRANT OPTION;
GRANT EXECUTE ON produccion.fn_registrar_cliente  TO ecommerce WITH GRANT OPTION;
GRANT EXECUTE ON produccion.fn_registrar_pago     TO ecommerce WITH GRANT OPTION;

ALTER SESSION SET CURRENT_SCHEMA = ecommerce;

-- Error de negocio del nodo (cada nodo lleva el suyo)
CREATE OR REPLACE PROCEDURE pr_error(p_mensaje IN VARCHAR2) IS
BEGIN
    RAISE_APPLICATION_ERROR(-20001, SUBSTR(p_mensaje, 1, 2000));
END pr_error;
/


-- D1. Interfaz de lectura hacia producción

-- Catálogo publicado con precio, oferta y disponibilidad
CREATE OR REPLACE VIEW v_catalogo_web AS
SELECT * FROM produccion.v_catalogo;

-- Categorías principales (las que no son subcategoría) para la portada y los filtros
CREATE OR REPLACE VIEW v_categoria_web AS
SELECT * FROM produccion.v_categoria_principal;

-- Pedidos web con su estado, total y comprobante ("mis pedidos")
CREATE OR REPLACE VIEW v_pedido_web AS
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
LEFT JOIN produccion.v_comprobante_venta f ON f.id_pedido = p.id_pedido AND f.estado_sri <> 'ANULADA'
LEFT JOIN carrito                      c ON c.id_pedido = p.id_pedido
LEFT JOIN cuenta_web                  cw ON cw.id_cliente = p.id_cliente
WHERE p.id_canal_venta = 'WEB';

-- Cuentas web con la actividad de compra del cliente (en todos los canales)
CREATE OR REPLACE VIEW v_cuenta_web AS
SELECT cw.id_cuenta_web,
       cw.cwe_correo              AS correo,
       cw.cwe_activa              AS activa,
       cw.cwe_creada              AS creada,
       cw.cwe_ultimo_acceso       AS ultimo_acceso,
       cw.id_cliente,
       cl.cli_nombres || NVL2(cl.cli_apellidos, ' ' || cl.cli_apellidos, NULL) AS cliente,
       NVL(f.compras, 0)          AS compras,
       f.ultima_compra,
       NVL(f.segmento, 'SIN COMPRAS') AS segmento
FROM cuenta_web cw
JOIN produccion.cliente                   cl ON cl.id_cliente = cw.id_cliente
LEFT JOIN produccion.v_frecuencia_cliente f  ON f.id_cliente  = cw.id_cliente;

-- Carritos abandonados: con productos, sin pedido y sin actividad hace más de un día
CREATE OR REPLACE VIEW v_carrito_abandonado AS
SELECT c.id_carrito,
       c.car_token,
       c.id_cliente,
       cw.cwe_correo              AS correo,
       c.car_actualizado          AS ultima_actividad,
       COUNT(*)                   AS productos,
       SUM(i.ica_cantidad * cat.precio_final_con_iva) AS valor_estimado
FROM carrito c
JOIN item_carrito i          ON i.id_carrito = c.id_carrito
LEFT JOIN cuenta_web cw      ON cw.id_cliente = c.id_cliente
LEFT JOIN v_catalogo_web cat ON cat.id_presentacion = i.id_presentacion
WHERE c.id_pedido IS NULL
  AND c.car_actualizado < LOCALTIMESTAMP - INTERVAL '1' DAY
GROUP BY c.id_carrito, c.car_token, c.id_cliente, cw.cwe_correo, c.car_actualizado;


-- D2. Disparadores del nodo

CREATE OR REPLACE TRIGGER tr_log_evento_web_inmutable
BEFORE UPDATE OR DELETE ON log_evento_web
FOR EACH ROW
BEGIN
    pr_error('Los registros de log_evento_web no se modifican ni se eliminan. La bitácora solo se inserta.');
END;
/

-- Última actividad del carrito (para detectar abandonos). Un carrito ya
-- convertido en pedido no se toca: el pedido vive en producción.
-- Si se borra el carrito entero, sus líneas se borran en cascada y el
-- carrito está "mutando" (ORA-04091): en ese caso no hay nada que anotar.
CREATE OR REPLACE TRIGGER tr_carrito_actividad
AFTER INSERT OR UPDATE OR DELETE ON item_carrito
FOR EACH ROW
DECLARE
    e_mutante EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_mutante, -4091);
    v_carrito NUMBER := CASE WHEN DELETING THEN :OLD.id_carrito ELSE :NEW.id_carrito END;
    v_pedido  NUMBER;
BEGIN
    SELECT MAX(id_pedido) INTO v_pedido FROM carrito WHERE id_carrito = v_carrito;
    IF v_pedido IS NOT NULL THEN
        pr_error('El carrito ' || v_carrito || ' ya se convirtió en el pedido ' || v_pedido || ' y no se modifica');
    END IF;
    UPDATE carrito SET car_actualizado = LOCALTIMESTAMP WHERE id_carrito = v_carrito;
EXCEPTION
    WHEN e_mutante THEN
        NULL;
END;
/

-- El pedido de un carrito se fija una sola vez
CREATE OR REPLACE TRIGGER tr_carrito_pedido
BEFORE UPDATE OF id_pedido ON carrito
FOR EACH ROW
BEGIN
    IF :OLD.id_pedido IS NOT NULL AND (:NEW.id_pedido IS NULL OR :NEW.id_pedido <> :OLD.id_pedido) THEN
        pr_error('El carrito ' || :OLD.id_carrito || ' ya se convirtió en el pedido ' || :OLD.id_pedido);
    END IF;
END;
/


-- D3. Funciones del nodo

-- Bitácora del e-commerce (p_detalle: texto JSON)
CREATE OR REPLACE FUNCTION fn_log_web(p_nivel IN VARCHAR2, p_evento IN VARCHAR2, p_mensaje IN VARCHAR2,
                                      p_cuenta IN NUMBER DEFAULT NULL, p_sesion IN VARCHAR2 DEFAULT NULL,
                                      p_ip IN VARCHAR2 DEFAULT NULL, p_agente IN VARCHAR2 DEFAULT NULL,
                                      p_detalle IN CLOB DEFAULT NULL)
RETURN NUMBER IS
    v_id NUMBER;
BEGIN
    INSERT INTO log_evento_web (lew_nivel, lew_evento, lew_mensaje, id_cuenta_web, lew_sesion, lew_ip, lew_agente, lew_detalle)
    VALUES (p_nivel, p_evento, SUBSTR(p_mensaje, 1, 500), p_cuenta, p_sesion, p_ip, SUBSTR(p_agente, 1, 250), p_detalle)
    RETURNING id_log_evento_web INTO v_id;
    RETURN v_id;
END fn_log_web;
/

CREATE OR REPLACE PROCEDURE pr_log_web(p_nivel IN VARCHAR2, p_evento IN VARCHAR2, p_mensaje IN VARCHAR2,
                                       p_cuenta IN NUMBER DEFAULT NULL, p_sesion IN VARCHAR2 DEFAULT NULL,
                                       p_ip IN VARCHAR2 DEFAULT NULL, p_agente IN VARCHAR2 DEFAULT NULL,
                                       p_detalle IN CLOB DEFAULT NULL) IS
    v_id NUMBER;
BEGIN
    v_id := fn_log_web(p_nivel, p_evento, p_mensaje, p_cuenta, p_sesion, p_ip, p_agente, p_detalle);
END pr_log_web;
/

-- Registro en la tienda en línea: el cliente se crea (o se reconoce por
-- su correo) en producción y la cuenta queda en este nodo
CREATE OR REPLACE FUNCTION fn_registrar_cuenta_web(p_nombres IN VARCHAR2, p_apellidos IN VARCHAR2, p_correo IN VARCHAR2,
                                                   p_hash_clave IN VARCHAR2, p_telefono IN VARCHAR2 DEFAULT NULL,
                                                   p_ip IN VARCHAR2 DEFAULT NULL)
RETURN NUMBER IS
    v_correo  cuenta_web.cwe_correo%TYPE := LOWER(TRIM(p_correo));
    v_cliente NUMBER;
    v_cuenta  NUMBER;
    v_n       NUMBER;
BEGIN
    IF v_correo IS NULL OR p_hash_clave IS NULL THEN
        pr_error('El correo y la clave son obligatorios');
    END IF;
    SELECT COUNT(*) INTO v_n FROM cuenta_web WHERE cwe_correo = v_correo;
    IF v_n > 0 THEN
        pr_error('Ya existe una cuenta con el correo ' || v_correo);
    END IF;
    -- Llamada a producción (al separar los nodos: por enlace de base de datos)
    v_cliente := produccion.fn_registrar_cliente(p_nombres, p_apellidos, v_correo, p_telefono);
    SELECT COUNT(*) INTO v_n FROM cuenta_web WHERE id_cliente = v_cliente;
    IF v_n > 0 THEN
        pr_error('Ese cliente ya tiene una cuenta web');
    END IF;
    INSERT INTO cuenta_web (id_cliente, cwe_correo, cwe_hash_clave)
    VALUES (v_cliente, v_correo, p_hash_clave)
    RETURNING id_cuenta_web INTO v_cuenta;
    pr_log_web('INFO', 'REGISTRO', 'Cuenta creada para ' || v_correo, v_cuenta, NULL, p_ip);
    RETURN v_cuenta;
END fn_registrar_cuenta_web;
/

-- Inicio de sesión de un cliente (la aplicación valida la clave y registra
-- aquí el resultado). Devuelve la cuenta si el acceso vale. p_exito: 1 / 0
CREATE OR REPLACE FUNCTION fn_registrar_acceso_web(p_correo IN VARCHAR2, p_exito IN NUMBER, p_sesion IN VARCHAR2 DEFAULT NULL,
                                                   p_ip IN VARCHAR2 DEFAULT NULL, p_agente IN VARCHAR2 DEFAULT NULL)
RETURN NUMBER IS
    v_correo cuenta_web.cwe_correo%TYPE := LOWER(TRIM(p_correo));
    v_cuenta NUMBER;
    v_activa NUMBER;
BEGIN
    SELECT MAX(id_cuenta_web), MAX(cwe_activa) INTO v_cuenta, v_activa FROM cuenta_web WHERE cwe_correo = v_correo;
    IF p_exito = 1 AND v_activa = 1 THEN
        UPDATE cuenta_web SET cwe_ultimo_acceso = LOCALTIMESTAMP WHERE id_cuenta_web = v_cuenta;
        pr_log_web('INFO', 'LOGIN_OK', 'Inicio de sesión de ' || v_correo, v_cuenta, p_sesion, p_ip, p_agente);
        RETURN v_cuenta;
    END IF;
    pr_log_web('AVISO', CASE WHEN v_activa = 0 THEN 'LOGIN_BLOQUEADO' ELSE 'LOGIN_FALLIDO' END,
               'Acceso rechazado para ' || v_correo, v_cuenta, p_sesion, p_ip, p_agente);
    RETURN NULL;
END fn_registrar_acceso_web;
/

-- Confirmar el carrito: producción crea el pedido web (con el precio y la
-- oferta vigentes de cada producto) y el carrito queda cerrado con ese pedido.
-- El carrito no lleva precios ni descuentos: no hay forma de colar uno.
CREATE OR REPLACE FUNCTION fn_crear_pedido_desde_carrito(p_carrito IN NUMBER, p_observacion IN VARCHAR2 DEFAULT NULL,
                                                         p_sesion IN VARCHAR2 DEFAULT NULL, p_ip IN VARCHAR2 DEFAULT NULL)
RETURN NUMBER IS
    c        carrito%ROWTYPE;
    v_cuenta NUMBER;
    v_activa NUMBER;
    v_lineas CLOB;
    v_pedido NUMBER;
BEGIN
    BEGIN
        SELECT * INTO c FROM carrito WHERE id_carrito = p_carrito FOR UPDATE;
    EXCEPTION WHEN NO_DATA_FOUND THEN
        pr_error('El carrito ' || p_carrito || ' no existe');
    END;
    IF c.id_pedido IS NOT NULL THEN
        pr_error('El carrito ' || p_carrito || ' ya se convirtió en el pedido ' || c.id_pedido);
    END IF;
    IF c.id_cliente IS NULL THEN
        pr_error('Identifique al cliente (cuenta o datos de invitado) antes de confirmar el carrito');
    END IF;
    SELECT MAX(id_cuenta_web), MAX(cwe_activa) INTO v_cuenta, v_activa FROM cuenta_web WHERE id_cliente = c.id_cliente;
    IF v_activa = 0 THEN
        pr_error('La cuenta web del cliente está desactivada');
    END IF;
    SELECT JSON_ARRAYAGG(JSON_OBJECT('id_presentacion' VALUE id_presentacion, 'cantidad' VALUE ica_cantidad)
                         ORDER BY id_presentacion RETURNING CLOB)
      INTO v_lineas
    FROM item_carrito WHERE id_carrito = p_carrito;
    IF v_lineas IS NULL THEN
        pr_error('El carrito ' || p_carrito || ' está vacío');
    END IF;

    -- Llamada a producción (al separar los nodos: por enlace de base de datos)
    v_pedido := produccion.fn_crear_pedido(c.id_cliente, 'WEB', v_lineas, NULL, p_observacion);

    UPDATE carrito SET id_pedido = v_pedido WHERE id_carrito = p_carrito;
    pr_log_web('INFO', 'CHECKOUT', 'Carrito ' || p_carrito || ' confirmado como pedido ' || v_pedido,
               v_cuenta, NVL(p_sesion, c.car_token), p_ip, NULL,
               '{"id_carrito": ' || p_carrito || ', "id_pedido": ' || v_pedido || '}');
    RETURN v_pedido;
END fn_crear_pedido_desde_carrito;
/


-- =====================================================================
-- E. CONTRATO ENTRE NODOS: un rol por nodo para las aplicaciones
--    · ELITE_PRODUCCION: todo el esquema PRODUCCION.
--    · ELITE_ECOMMERCE: todo el esquema ECOMMERCE y, de producción, solo
--      las vistas y tablas de la sección D0 (lectura), alta de teléfonos,
--      direcciones y datos de facturación, y las funciones fn_crear_pedido,
--      fn_registrar_cliente y fn_registrar_pago (corren con los permisos de
--      producción: AUTHID DEFINER, el valor por omisión).
--    Para una aplicación: CREATE USER app_web ...; GRANT CREATE SESSION,
--    elite_ecommerce TO app_web; y desde la aplicación ALTER SESSION SET
--    CURRENT_SCHEMA = ecommerce.
-- =====================================================================
DECLARE
    v_n   NUMBER;
    v_rol VARCHAR2(30);
    PROCEDURE ejecutar(p_sql IN VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE p_sql;
    END;
BEGIN
    FOR r IN (SELECT 'ELITE_PRODUCCION' AS rol FROM dual UNION ALL SELECT 'ELITE_ECOMMERCE' FROM dual) LOOP
        SELECT COUNT(*) INTO v_n FROM dba_roles WHERE role = r.rol;
        IF v_n = 0 THEN
            ejecutar('CREATE ROLE ' || r.rol);
        END IF;
    END LOOP;

    FOR o IN (SELECT owner, object_name, object_type
              FROM dba_objects
              WHERE owner IN ('PRODUCCION', 'ECOMMERCE')
                AND object_type IN ('TABLE', 'VIEW', 'FUNCTION', 'PROCEDURE', 'PACKAGE')
                AND object_name NOT LIKE 'BIN$%'
              ORDER BY owner, object_type, object_name) LOOP
        v_rol := CASE o.owner WHEN 'PRODUCCION' THEN 'ELITE_PRODUCCION' ELSE 'ELITE_ECOMMERCE' END;
        ejecutar('GRANT ' || CASE o.object_type WHEN 'TABLE' THEN 'SELECT, INSERT, UPDATE, DELETE'
                                                WHEN 'VIEW'  THEN 'SELECT'
                                                ELSE 'EXECUTE' END
                 || ' ON ' || o.owner || '."' || o.object_name || '" TO ' || v_rol);
    END LOOP;

    -- De producción, el e-commerce solo recibe lo del contrato
    FOR o IN (SELECT column_value AS objeto FROM TABLE(SYS.ODCIVARCHAR2LIST(
                  'V_CATALOGO', 'V_CATEGORIA_PRINCIPAL', 'V_OFERTA_VIGENTE', 'V_PEDIDO_ESTADO_ACTUAL', 'V_PEDIDO_TOTALES',
                  'V_COMPROBANTE_VENTA', 'V_FRECUENCIA_CLIENTE', 'PEDIDO', 'CLIENTE', 'TELEFONO', 'DIRECCION',
                  'DATOS_FACTURACION', 'CIUDAD', 'PROVINCIA', 'TIPO_IDENTIFICACION'))) LOOP
        ejecutar('GRANT SELECT ON produccion.' || o.objeto || ' TO elite_ecommerce');
    END LOOP;
    ejecutar('GRANT INSERT ON produccion.telefono TO elite_ecommerce');
    ejecutar('GRANT INSERT ON produccion.direccion TO elite_ecommerce');
    ejecutar('GRANT INSERT ON produccion.datos_facturacion TO elite_ecommerce');
    ejecutar('GRANT EXECUTE ON produccion.fn_crear_pedido TO elite_ecommerce');
    ejecutar('GRANT EXECUTE ON produccion.fn_registrar_cliente TO elite_ecommerce');
    ejecutar('GRANT EXECUTE ON produccion.fn_registrar_pago TO elite_ecommerce');
END;
/


-- =====================================================================
-- F. AL SEPARAR LOS NODOS (referencia, no se ejecuta)
--  Cada esquema pasa a su propia PDB (o servidor). En la PDB del
--  e-commerce:
--    CREATE DATABASE LINK produccion CONNECT TO ecommerce_enlace
--        IDENTIFIED BY "..." USING '//servidor:1521/PDB_PRODUCCION';
--    · v_catalogo_web pasa a MATERIALIZED VIEW ... REFRESH COMPLETE
--      START WITH SYSDATE NEXT SYSDATE + 5/1440 AS SELECT * FROM
--      v_catalogo@produccion (refresco cada 5 minutos);
--    · produccion.fn_crear_pedido(...) pasa a fn_crear_pedido@produccion(...)
--      (lo mismo con fn_registrar_cliente y fn_registrar_pago). El CLOB de
--      líneas viaja bien por el enlace desde 12.2;
--    · fkx_item_carrito_presentacion apunta a la réplica local del catálogo;
--    · fkx_carrito_cliente, fkx_cuenta_web_cliente y fkx_carrito_pedido se
--      eliminan: no hay claves foráneas entre bases; las validan las
--      funciones del e-commerce.
--  Ninguna tabla se escribe en los dos nodos: las identidades no chocan y
--  no hace falta resolver conflictos de réplica.
-- =====================================================================


-- =====================================================================
-- G. VERIFICACIÓN: recompila lo que haya quedado pendiente y muestra los
--    errores de compilación (si hay alguno, cópielos tal cual para
--    corregirlos)
-- =====================================================================
ALTER SESSION SET CURRENT_SCHEMA = produccion;
WHENEVER SQLERROR CONTINUE
BEGIN
    DBMS_UTILITY.COMPILE_SCHEMA('PRODUCCION', FALSE);
    DBMS_UTILITY.COMPILE_SCHEMA('ECOMMERCE', FALSE);
EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('No se pudo recompilar automáticamente: ' || SQLERRM);
END;
/

SET LINESIZE 200
SET PAGESIZE 100
COLUMN objeto FORMAT A45
COLUMN tipo   FORMAT A14
COLUMN error  FORMAT A120
SELECT owner || '.' || name AS objeto, type AS tipo, line AS linea, SUBSTR(text, 1, 120) AS error
FROM dba_errors
WHERE owner IN ('PRODUCCION', 'ECOMMERCE')
ORDER BY owner, name, sequence;

SELECT owner AS nodo, object_type AS tipo, COUNT(*) AS cantidad,
       SUM(CASE WHEN status <> 'VALID' THEN 1 ELSE 0 END) AS invalidos
FROM dba_objects
WHERE owner IN ('PRODUCCION', 'ECOMMERCE')
  AND object_type IN ('TABLE', 'VIEW', 'TRIGGER', 'FUNCTION', 'PROCEDURE', 'PACKAGE', 'PACKAGE BODY', 'INDEX')
GROUP BY owner, object_type
ORDER BY owner, object_type;

DECLARE
    v_n NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_n FROM dba_objects
    WHERE owner IN ('PRODUCCION', 'ECOMMERCE') AND status <> 'VALID';
    IF v_n = 0 THEN
        DBMS_OUTPUT.PUT_LINE('LÓGICA INSTALADA: todos los objetos de PRODUCCION y ECOMMERCE son válidos.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('ATENCIÓN: ' || v_n || ' objetos inválidos. Revise la lista de errores de arriba.');
    END IF;
END;
/
WHENEVER SQLERROR EXIT FAILURE
