/*==============================================================*/
/* Migracion: la banda (pieza) vendida queda RESERVADA          */
/*                                                              */
/* Falla corregida: un pedido pendiente reservaba pie2 de la    */
/* variante pero no la BANDA concreta. La misma banda se podia  */
/* vender dos veces (un segundo pedido de 29 pie2 se aceptaba), */
/* la tienda seguia mostrandola, y al poner una banda en la     */
/* lista se bloqueaban TODAS las demas de ese color (el tope    */
/* era "la pieza mas grande" menos lo que habia en la lista).   */
/* Ademas carrito y pedido eran unicos por presentacion: dos    */
/* bandas del mismo color se sumaban en una linea imposible.    */
/*                                                              */
/*  1. v_pieza_libre: cada pieza con su saldo, lo reservado por */
/*     pedidos PEN/PAG (la misma regla de v_stock_variante) y   */
/*     lo LIBRE. v_pieza_web y v_catalogo usan lo libre.        */
/*  2. detalle_pedido.id_lote_reservado: la pieza de la linea.  */
/*     La linea es unica por (pedido, presentacion, pieza):     */
/*     dos bandas del mismo color son dos lineas.               */
/*  3. fn_crear_pedido acepta "id_lote" por linea (la banda que */
/*     eligio el cliente) y la valida; si no viene, reserva la  */
/*     mas pequena LIBRE que alcanza. Rechaza reservar por      */
/*     encima de lo que mide la pieza.                          */
/*  4. fn_facturar_pedido descuenta de la pieza reservada si    */
/*     quien factura no elige otra.                             */
/*  5. ecommerce.item_carrito.ica_pieza (0 = sin pieza) entra   */
/*     en la clave: cada banda es su propia linea del carrito,  */
/*     y fn_crear_pedido_desde_carrito la manda como id_lote.   */
/*                                                              */
/* Se puede correr mas de una vez.                              */
/*   sqlplus system@//localhost:1521/FREEPDB1 @10_pieza_reservada.sql */
/*==============================================================*/
SET DEFINE OFF
SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

ALTER SESSION SET CURRENT_SCHEMA = produccion;

-- 1. Estructura
DECLARE
    v_n NUMBER;
    PROCEDURE ddl(p_sql IN VARCHAR2) IS BEGIN EXECUTE IMMEDIATE p_sql; END;
BEGIN
    SELECT COUNT(*) INTO v_n FROM all_tab_columns
    WHERE owner = 'PRODUCCION' AND table_name = 'DETALLE_PEDIDO' AND column_name = 'ID_LOTE_RESERVADO';
    IF v_n = 0 THEN
        ddl('ALTER TABLE produccion.detalle_pedido ADD id_lote_reservado NUMBER(10) NULL');
        ddl('ALTER TABLE produccion.detalle_pedido ADD CONSTRAINT fk_detalle_pedido_lote_reservado
                FOREIGN KEY (id_lote_reservado) REFERENCES produccion.lote (id_lote)');
        ddl(q'[COMMENT ON COLUMN produccion.detalle_pedido.id_lote_reservado IS 'Productos por pieza (cuero): la pieza de la que sale la linea, reservada mientras el pedido esta PEN/PAG.']');
        ddl('CREATE INDEX ix_detalle_pedido_lote_reservado ON produccion.detalle_pedido (id_lote_reservado)');
        DBMS_OUTPUT.PUT_LINE('  + detalle_pedido.id_lote_reservado');
    END IF;
    SELECT COUNT(*) INTO v_n FROM all_constraints
    WHERE owner = 'PRODUCCION' AND constraint_name = 'AK_DETALLE_PEDIDO_PRESENTACION';
    IF v_n > 0 THEN
        ddl('ALTER TABLE produccion.detalle_pedido DROP CONSTRAINT ak_detalle_pedido_presentacion DROP INDEX');
        ddl('CREATE UNIQUE INDEX ak_detalle_pedido_pres_pieza ON produccion.detalle_pedido
                (id_pedido, id_presentacion, NVL(id_lote_reservado, 0))');
        DBMS_OUTPUT.PUT_LINE('  ~ linea unica por (pedido, presentacion, pieza)');
    END IF;

    SELECT COUNT(*) INTO v_n FROM all_tab_columns
    WHERE owner = 'ECOMMERCE' AND table_name = 'ITEM_CARRITO' AND column_name = 'ICA_PIEZA';
    IF v_n = 0 THEN
        ddl('ALTER TABLE ecommerce.item_carrito ADD ica_pieza NUMBER(10) DEFAULT 0 NOT NULL');
        ddl(q'[COMMENT ON COLUMN ecommerce.item_carrito.ica_pieza IS 'Productos por pieza: la banda elegida en la tienda (id_lote); 0 = sin pieza (la asigna la base al pedir).']');
        ddl('ALTER TABLE ecommerce.item_carrito DROP CONSTRAINT pk_item_carrito DROP INDEX');
        ddl('ALTER TABLE ecommerce.item_carrito ADD CONSTRAINT pk_item_carrito
                PRIMARY KEY (id_carrito, id_presentacion, ica_pieza)');
        DBMS_OUTPUT.PUT_LINE('  + item_carrito.ica_pieza (en la clave)');
    END IF;
END;
/

-- 2. Piezas con lo reservado y lo libre
CREATE OR REPLACE VIEW v_pieza_libre AS
WITH reservas AS (
    SELECT d.id_lote_reservado AS id_lote, SUM(d.dpe_cantidad * pr.pre_factor) AS reservado
    FROM detalle_pedido d
    JOIN presentacion pr           ON pr.id_presentacion = d.id_presentacion
    JOIN v_pedido_estado_actual ea ON ea.id_pedido       = d.id_pedido
    WHERE d.id_lote_reservado IS NOT NULL AND ea.id_estado_pedido IN ('PEN', 'PAG')
    GROUP BY d.id_lote_reservado
)
SELECT ls.id_lote,
       ls.id_variante,
       ls.id_lote_origen,
       ls.lot_codigo_proveedor,
       ls.fecha_ingreso,
       ls.saldo,
       NVL(r.reservado, 0)                                     AS reservado,
       ls.saldo - NVL(r.reservado, 0)                          AS libre
FROM v_lote_saldo ls
LEFT JOIN reservas r ON r.id_lote = ls.id_lote
WHERE ls.saldo > 0;

-- La tienda ve lo LIBRE de cada banda (una banda en un pedido pendiente ya no se ofrece)
CREATE OR REPLACE VIEW v_pieza_web AS
SELECT p.prd_codigo,
       v.id_variante,
       v.var_sku,
       pl.id_lote,
       pl.lot_codigo_proveedor                                 AS codigo,
       pl.libre                                                AS saldo,
       CASE WHEN pl.id_lote_origen IS NULL THEN 1 ELSE 0 END   AS pieza_entera,
       pl.fecha_ingreso
FROM v_pieza_libre pl
JOIN variante v ON v.id_variante = pl.id_variante
JOIN producto p ON p.id_producto = v.id_producto
WHERE p.prd_venta_por_pieza = 1 AND p.prd_publicado = 1 AND v.var_activa = 1 AND pl.libre > 0;

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
       -- es lo LIBRE de la pieza más grande (sin lo reservado por pedidos pendientes)
       FLOOR(GREATEST(CASE WHEN p.prd_venta_por_pieza = 1
                           THEN LEAST(s.disponible, NVL((SELECT MAX(pl.libre) FROM v_pieza_libre pl
                                                         WHERE pl.id_variante = v.id_variante), 0))
                           ELSE s.disponible END, 0) / pr.pre_factor / pr.pre_incremento)
       * pr.pre_incremento                                     AS disponible,
       CASE WHEN p.prd_fecha_creacion >= TRUNC(SYSDATE) - 30 THEN 1 ELSE 0 END AS es_novedad,
       -- datos de vitrina para el e-commerce
       p.prd_imagen_url                                        AS imagen_url,
       p.prd_uso                                               AS uso,
       c.cat_codigo                                            AS categoria_codigo,
       NVL(cp.cat_codigo, c.cat_codigo)                        AS linea_codigo,
       NVL(cp.cat_nombre, c.cat_nombre)                        AS linea,
       p.prd_fecha_creacion                                    AS fecha_creacion,
       p.id_unidad_medida                                      AS unidad_codigo,
       um.umd_nombre                                           AS unidad,
       p.prd_venta_por_pieza                                   AS venta_por_pieza,
       m.mar_nombre                                            AS marca,
       pr.pre_incremento                                       AS incremento,
       pr.pre_factor                                           AS factor
FROM producto p
JOIN categoria         c  ON c.id_categoria     = p.id_categoria
LEFT JOIN categoria    cp ON cp.id_categoria    = c.id_categoria_padre
LEFT JOIN marca        m  ON m.id_marca         = p.id_marca AND m.mar_activa = 1
JOIN unidad_medida     um ON um.id_unidad_medida = p.id_unidad_medida
JOIN tarifa_iva        t  ON t.id_tarifa_iva    = p.id_tarifa_iva
JOIN variante          v  ON v.id_producto      = p.id_producto
JOIN presentacion      pr ON pr.id_variante     = v.id_variante
JOIN v_precio_vigente  pv ON pv.id_presentacion = pr.id_presentacion
JOIN v_stock_variante  s  ON s.id_variante      = v.id_variante
LEFT JOIN v_oferta_vigente ov ON ov.id_producto = p.id_producto
WHERE p.prd_publicado = 1 AND v.var_activa = 1 AND pr.pre_activa = 1 AND c.cat_activa = 1;

-- 3. Funciones
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
    v_incremento NUMBER;
    v_regla     NUMBER;
    v_pieza     NUMBER;
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
    FOR r IN (SELECT j.id_presentacion, j.cantidad, NVL(j.descuento, 0) AS descuento, j.valor_final, j.id_lote
              FROM JSON_TABLE(p_lineas, '$[*]' COLUMNS (
                       id_presentacion NUMBER PATH '$.id_presentacion',
                       cantidad        NUMBER PATH '$.cantidad',
                       descuento       NUMBER PATH '$.descuento',
                       valor_final     NUMBER PATH '$.valor_final',
                       id_lote         NUMBER PATH '$.id_lote')) j) LOOP
        BEGIN
            SELECT pre.pre_descripcion, pre.pre_cantidad_minima, pre.pre_incremento, v.var_sku, p.id_tarifa_iva, pv.precio, t.tiv_porcentaje,
                   NVL(ov.ofe_porcentaje, 0)
              INTO v_desc_pre, v_minima, v_incremento, v_sku, v_tarifa, v_precio, v_pct_iva, v_pct_ofe
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
        -- Incremento de venta: el cuero por pie2 va de 0.25 en 0.25, lo demás en enteros
        IF MOD(r.cantidad, v_incremento) <> 0 THEN
            pr_error(v_sku || ' (' || v_desc_pre || ') se vende en múltiplos de '
                     || RTRIM(TO_CHAR(v_incremento, 'FM9999990.999'), '.')
                     || ': ' || RTRIM(TO_CHAR(r.cantidad, 'FM9999990.999'), '.') || ' no es válido');
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
                                    id_tarifa_iva, id_usuario_descuento, id_lote_reservado)
        VALUES (v_pedido, r.id_presentacion, r.cantidad, v_precio, v_desc, v_tarifa,
                CASE WHEN v_desc > 0 THEN p_vendedor END, r.id_lote);
    END LOOP;

    -- Descuento por volumen: como la oferta, lo asigna la base, nunca el cliente.
    -- Se mide lo que lleva el pedido de cada PRODUCTO (todas sus tallas y
    -- colores, en unidad base) y se toma el escalón más alto alcanzado. Las
    -- líneas negociadas no lo reciben: el valor pactado lo reemplaza.
    FOR r IN (SELECT d.id_detalle_pedido, v.id_producto
              FROM detalle_pedido d
              JOIN presentacion pr ON pr.id_presentacion = d.id_presentacion
              JOIN variante v      ON v.id_variante      = pr.id_variante
              WHERE d.id_pedido = v_pedido AND d.dpe_descuento = 0) LOOP
        SELECT MAX(dv.id_descuento_volumen) KEEP (DENSE_RANK LAST ORDER BY dv.dvo_cantidad_minima)
          INTO v_regla
        FROM descuento_volumen dv
        WHERE dv.id_producto = r.id_producto
          AND dv.dvo_activo = 1
          AND dv.dvo_cantidad_minima <= (SELECT SUM(x.dpe_cantidad * px.pre_factor)
                                         FROM detalle_pedido x
                                         JOIN presentacion px ON px.id_presentacion = x.id_presentacion
                                         JOIN variante vx     ON vx.id_variante     = px.id_variante
                                         WHERE x.id_pedido = v_pedido AND vx.id_producto = r.id_producto);
        IF v_regla IS NOT NULL THEN
            UPDATE detalle_pedido SET id_descuento_volumen = v_regla
            WHERE id_detalle_pedido = r.id_detalle_pedido;
        END IF;
    END LOOP;

    INSERT INTO historial_estado_pedido (id_pedido, id_estado_pedido, id_usuario, hep_observacion)
    VALUES (v_pedido, 'PEN', v_usuario, 'Pedido creado');

    -- Una pieza solo tiene sentido en productos por pieza: en el resto se ignora
    UPDATE detalle_pedido d SET d.id_lote_reservado = NULL
    WHERE d.id_pedido = v_pedido AND d.id_lote_reservado IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM presentacion pr
                      JOIN variante v ON v.id_variante = pr.id_variante
                      JOIN producto p ON p.id_producto = v.id_producto
                      WHERE pr.id_presentacion = d.id_presentacion AND p.prd_venta_por_pieza = 1);

    -- Productos que se venden por pieza (cuero): cada línea sale de UNA pieza
    -- y esa pieza queda RESERVADA para el pedido (detalle_pedido.id_lote_reservado),
    -- así nadie más puede comprar la misma banda mientras el pedido esté pendiente.
    -- Si el cliente eligió la banda, se valida; si no, la base toma la más pequeña
    -- LIBRE que alcanza (las líneas grandes primero, para que quepan).
    FOR r IN (SELECT d.id_detalle_pedido, d.id_lote_reservado, dv.id_variante, dv.cantidad_base,
                     v.var_sku, p.id_unidad_medida AS unidad
              FROM detalle_pedido d
              JOIN v_detalle_pedido_valor dv ON dv.id_detalle_pedido = d.id_detalle_pedido
              JOIN variante v ON v.id_variante = dv.id_variante
              JOIN producto p ON p.id_producto = v.id_producto
              WHERE d.id_pedido = v_pedido AND p.prd_venta_por_pieza = 1
              ORDER BY CASE WHEN d.id_lote_reservado IS NULL THEN 1 ELSE 0 END, dv.cantidad_base DESC) LOOP
        IF r.id_lote_reservado IS NOT NULL THEN
            SELECT COUNT(*) INTO v_n FROM lote WHERE id_lote = r.id_lote_reservado AND id_variante = r.id_variante;
            IF v_n = 0 THEN
                pr_error('La pieza ' || r.id_lote_reservado || ' no es de ' || r.var_sku);
            END IF;
        ELSE
            SELECT MIN(pl.id_lote) KEEP (DENSE_RANK FIRST ORDER BY pl.libre, pl.fecha_ingreso, pl.id_lote)
              INTO v_pieza
            FROM v_pieza_libre pl
            WHERE pl.id_variante = r.id_variante AND pl.libre >= r.cantidad_base;
            IF v_pieza IS NULL THEN
                pr_error('Ninguna pieza libre de ' || r.var_sku || ' alcanza para ' || r.cantidad_base || ' ' || r.unidad
                         || ' (los retazos no se juntan y las bandas de otros pedidos pendientes están reservadas)');
            END IF;
            UPDATE detalle_pedido SET id_lote_reservado = v_pieza WHERE id_detalle_pedido = r.id_detalle_pedido;
        END IF;
    END LOOP;
    -- Ninguna pieza puede quedar reservada por encima de lo que mide
    FOR r IN (SELECT pl.id_lote, pl.lot_codigo_proveedor, pl.saldo, pl.libre, v.var_sku
              FROM v_pieza_libre pl
              JOIN variante v ON v.id_variante = pl.id_variante
              WHERE pl.libre < 0
                AND pl.id_lote IN (SELECT id_lote_reservado FROM detalle_pedido WHERE id_pedido = v_pedido)) LOOP
        pr_error('La pieza ' || NVL(r.lot_codigo_proveedor, TO_CHAR(r.id_lote)) || ' de ' || r.var_sku
                 || ' no alcanza: mide ' || RTRIM(TO_CHAR(r.saldo, 'FM9999990.999'), '.')
                 || ' y otros pedidos pendientes ya tienen reservada parte o toda la pieza');
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
                     -- el lote que elija quien factura o, si no elige, la pieza reservada
                     NVL((SELECT MIN(x.id_lote)
                          FROM JSON_TABLE(v_lotes, '$[*]' COLUMNS (id_detalle_pedido NUMBER PATH '$.id_detalle_pedido',
                                                                   id_lote           NUMBER PATH '$.id_lote')) x
                          WHERE x.id_detalle_pedido = dv.id_detalle_pedido),
                         (SELECT d.id_lote_reservado FROM detalle_pedido d
                          WHERE d.id_detalle_pedido = dv.id_detalle_pedido)) AS id_lote_elegido
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

ALTER SESSION SET CURRENT_SCHEMA = ecommerce;

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
    -- ica_pieza: la banda elegida en la tienda (0 = la base la asigna)
    SELECT JSON_ARRAYAGG(JSON_OBJECT('id_presentacion' VALUE id_presentacion, 'cantidad' VALUE ica_cantidad,
                                     'id_lote' VALUE NULLIF(ica_pieza, 0))
                         ORDER BY id_presentacion, ica_pieza RETURNING CLOB)
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

-- 4. Vistas espejo del e-commerce (el SELECT * se expande al crearlas)
CREATE OR REPLACE VIEW v_catalogo_web AS
SELECT * FROM produccion.v_catalogo;
CREATE OR REPLACE VIEW v_pieza_web AS
SELECT * FROM produccion.v_pieza_web;

BEGIN
    DBMS_UTILITY.COMPILE_SCHEMA(schema => 'PRODUCCION', compile_all => FALSE);
    DBMS_UTILITY.COMPILE_SCHEMA(schema => 'ECOMMERCE', compile_all => FALSE);
END;
/

SELECT owner, object_name, object_type FROM dba_objects
WHERE owner IN ('PRODUCCION', 'ECOMMERCE') AND status <> 'VALID';
PROMPT (si la consulta anterior no devolvio filas, todo quedo valido)
EXIT
