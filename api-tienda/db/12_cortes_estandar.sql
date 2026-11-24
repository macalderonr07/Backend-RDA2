/*==============================================================*/
/* Migracion: fibra de caucho en planchas (cortes estandar)     */
/*                                                              */
/* La fibra llega en PLANCHAS de 24 pie2 y se vende en cortes   */
/* fijos: plancha (24), 1/2 (12), 1/4 (6), 2 pies y 1 pie. A    */
/* diferencia del cuero (el cliente pide cualquier medida de    */
/* una banda), aqui cada venta es una PIEZA FISICA de medida    */
/* exacta, y la plancha se va cortando de verdad:               */
/*                                                              */
/*   PL-001 (24) -> [12] queda 12 -> [6] queda 6 -> [2,2] ...   */
/*                                                              */
/*  1. producto.prd_cortes_estandar (0/1, exige venta por      */
/*     pieza). La escalera de cortes son los factores de las    */
/*     presentaciones activas de la variante: nada se duplica.  */
/*  2. fn_cortar_estandar(variante, medida, motivo): devuelve   */
/*     una pieza libre de esa medida exacta; si no hay suelta,  */
/*     corta en cascada la mas pequena que alcanza con          */
/*     fn_fraccionar_lote (kardex FRS/FRE, id_lote_origen). El  */
/*     inventario total nunca cambia: solo se parte.            */
/*  3. fn_crear_pedido: en estos productos una linea de N       */
/*     unidades se separa en N lineas de 1, cada una con su     */
/*     pieza exacta reservada (detalle_pedido.id_lote_reservado)*/
/*  4. v_catalogo: el disponible de un corte es cuantas piezas  */
/*     de esa medida salen de las libres (no solo la mayor), y  */
/*     expone cortes_estandar.                                  */
/*     fn_fraccionar_lote numera sin repetir codigos.           */
/*  5. El usuario SISTEMA recibe INV_FRACCIONAR (corta para los */
/*     pedidos web, que no tienen usuario interno).             */
/*  6. Producto CE-9101 (Suelas > Caucho) con 7 planchas.       */
/*                                                              */
/* Se puede correr mas de una vez.                              */
/*   sqlplus system@//localhost:1521/FREEPDB1 @12_cortes_estandar.sql */
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
    WHERE owner = 'PRODUCCION' AND table_name = 'PRODUCTO' AND column_name = 'PRD_CORTES_ESTANDAR';
    IF v_n = 0 THEN
        ddl('ALTER TABLE produccion.producto ADD prd_cortes_estandar NUMBER(1) DEFAULT 0 NOT NULL');
        ddl('ALTER TABLE produccion.producto ADD CONSTRAINT ck_producto_cortes_estandar
                CHECK (prd_cortes_estandar IN (0, 1) AND (prd_cortes_estandar = 0 OR prd_venta_por_pieza = 1))');
        ddl(q'[COMMENT ON COLUMN produccion.producto.prd_cortes_estandar IS 'Se vende en piezas de medida fija (los factores de sus presentaciones): cada unidad vendida es una pieza exacta, cortada en cascada de la plancha. Exige venta por pieza.']');
        DBMS_OUTPUT.PUT_LINE('  + producto.prd_cortes_estandar');
    END IF;
END;
/

-- 5. SISTEMA corta para los pedidos web
INSERT INTO rol_permiso (id_rol, id_permiso)
SELECT r.id_rol, pe.id_permiso FROM rol r CROSS JOIN permiso pe
WHERE r.rol_codigo = 'SISTEMA' AND pe.per_codigo = 'INV_FRACCIONAR'
  AND NOT EXISTS (SELECT 1 FROM rol_permiso x WHERE x.id_rol = r.id_rol AND x.id_permiso = pe.id_permiso);
COMMIT;

-- Fraccionar sin repetir codigos (antes: cortar dos veces la misma pieza
-- daba dos paquetes '-1')
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
    v_hijos  NUMBER;
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

    -- los paquetes se numeran a continuacion de los que ya salieron de esta
    -- pieza: cortarla dos veces no repite codigos (PL-001-1, PL-001-2, ...)
    SELECT COUNT(*) INTO v_hijos FROM lote WHERE id_lote_origen = p_lote;
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
                SUBSTR(NVL(v_l.lot_codigo_proveedor, 'L' || p_lote), 1, 26) || '-' || (v_hijos + x.n), p_lote)
        RETURNING id_lote INTO v_nuevo;
        INSERT INTO detalle_movimiento (id_movimiento, id_lote, dmo_cantidad)
        VALUES (v_fre, v_nuevo, x.medida);
        v_lotes.EXTEND;
        v_lotes(v_lotes.COUNT) := v_nuevo;
    END LOOP;
    RETURN v_lotes;
END fn_fraccionar_lote;
/

-- 2. Corte en cascada
CREATE OR REPLACE FUNCTION fn_cortar_estandar(p_variante IN NUMBER, p_medida IN NUMBER,
                                              p_motivo IN VARCHAR2 DEFAULT NULL,
                                              p_desde IN NUMBER DEFAULT NULL)
RETURN NUMBER IS
    v_pieza     NUMBER;
    v_tam       NUMBER;
    v_reservado NUMBER;
    v_corte     NUMBER;
    v_n         NUMBER;
    v_json      VARCHAR2(4000);
    v_lotes     SYS.ODCINUMBERLIST;
    v_sistema   NUMBER;
    v_previo    NUMBER := pk_sesion.usuario;
BEGIN
    IF p_medida IS NULL OR p_medida <= 0 THEN
        pr_error('La medida del corte debe ser mayor que cero');
    END IF;
    IF p_desde IS NOT NULL THEN
        -- pieza elegida: debe ser de la variante, estar libre y alcanzar
        SELECT MAX(saldo), MAX(reservado) INTO v_tam, v_reservado
        FROM v_pieza_libre WHERE id_lote = p_desde AND id_variante = p_variante;
        IF v_tam IS NULL THEN
            pr_error('La pieza ' || p_desde || ' no existe, está agotada o no es de esta variante');
        END IF;
        IF v_reservado > 0 THEN
            pr_error('La pieza ' || p_desde || ' ya está reservada por otro pedido pendiente');
        END IF;
        IF v_tam < p_medida THEN
            pr_error('La pieza ' || p_desde || ' mide ' || v_tam || ' y no alcanza para un corte de ' || p_medida);
        END IF;
        v_pieza := p_desde;
    ELSE
        -- 1) una pieza suelta de la medida exacta (la mas antigua)
        SELECT MIN(id_lote) KEEP (DENSE_RANK FIRST ORDER BY fecha_ingreso, id_lote) INTO v_pieza
        FROM v_pieza_libre
        WHERE id_variante = p_variante AND reservado = 0 AND saldo = p_medida;
        IF v_pieza IS NOT NULL THEN
            RETURN v_pieza;
        END IF;
        -- 2) la pieza libre mas pequena que alcanza (no se abre una plancha si hay un retazo)
        SELECT MIN(id_lote) KEEP (DENSE_RANK FIRST ORDER BY saldo, fecha_ingreso, id_lote),
               MIN(saldo)
          INTO v_pieza, v_tam
        FROM v_pieza_libre
        WHERE id_variante = p_variante AND reservado = 0 AND saldo > p_medida;
        IF v_pieza IS NULL THEN
            RETURN NULL;
        END IF;
    END IF;

    SELECT id_usuario INTO v_sistema FROM usuario WHERE usu_correo = 'sistema@comercialelite.local';
    WHILE v_tam > p_medida LOOP
        -- siguiente peldano de la escalera: el corte estandar mas grande que
        -- divide la pieza y que a su vez se puede seguir dividiendo hasta la medida
        SELECT MAX(pre_factor) INTO v_corte
        FROM presentacion
        WHERE id_variante = p_variante AND pre_activa = 1
          AND pre_factor < v_tam AND pre_factor >= p_medida
          AND MOD(v_tam, pre_factor) = 0 AND MOD(pre_factor, p_medida) = 0;
        IF v_corte IS NULL THEN
            v_corte := p_medida;   -- pieza fuera de medida (retazo): se corta directo
        END IF;
        -- piezas nuevas de v_corte; la pieza original se queda con una de ellas o con el sobrante
        v_n := FLOOR(v_tam / v_corte) - CASE WHEN MOD(v_tam, v_corte) = 0 THEN 1 ELSE 0 END;
        v_json := '[';
        FOR i IN 1 .. v_n LOOP
            v_json := v_json || CASE WHEN i > 1 THEN ',' END
                      || RTRIM(TO_CHAR(v_corte, 'FM9999990.999', 'NLS_NUMERIC_CHARACTERS=''.,'''), '.');
        END LOOP;
        v_json := v_json || ']';
        v_lotes := fn_fraccionar_lote(v_pieza, v_json, v_sistema,
                                      NVL(p_motivo, 'Corte estándar') || ': pieza de '
                                      || RTRIM(TO_CHAR(v_tam, 'FM9999990.999', 'NLS_NUMERIC_CHARACTERS=''.,'''), '.')
                                      || ' en ' || (v_n + 1) || ' partes');
        v_pieza := v_lotes(1);
        v_tam := v_corte;
    END LOOP;
    -- fn_exigir_permiso dejo a SISTEMA en la sesion: se devuelve a quien actuaba
    pk_sesion.fijar_usuario(v_previo);
    RETURN v_pieza;
END fn_cortar_estandar;
/

-- 3. Pedido: cada unidad de un corte estándar es una pieza exacta reservada
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
    v_desc_corte NUMBER;
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

    -- Cortes estándar (fibra de caucho en planchas): cada unidad pedida es UNA
    -- pieza física de la medida exacta de la presentación. Una línea de N
    -- unidades se separa en N líneas de 1, y cada una reserva su pieza; si no
    -- hay una suelta de esa medida, fn_cortar_estandar corta en cascada la
    -- pieza libre más pequeña que alcanza (24 -> 12 -> 6 -> 2 -> 1), con kárdex.
    FOR r IN (SELECT d.*, pr.pre_factor, pr.id_variante, v.var_sku, p.id_unidad_medida AS unidad
              FROM detalle_pedido d
              JOIN presentacion pr ON pr.id_presentacion = d.id_presentacion
              JOIN variante v      ON v.id_variante      = pr.id_variante
              JOIN producto p      ON p.id_producto      = v.id_producto
              WHERE d.id_pedido = v_pedido AND p.prd_cortes_estandar = 1
              ORDER BY pr.pre_factor DESC, d.id_detalle_pedido) LOOP
        IF r.dpe_cantidad <> TRUNC(r.dpe_cantidad) THEN
            pr_error(r.var_sku || ' se vende por piezas enteras: ' || r.dpe_cantidad || ' no es válido');
        END IF;
        IF r.id_lote_reservado IS NOT NULL AND r.dpe_cantidad > 1 THEN
            pr_error('Una pieza elegida de ' || r.var_sku || ' es una sola unidad: pida cantidad 1 por pieza');
        END IF;
        v_desc_corte := TRUNC(r.dpe_descuento / r.dpe_cantidad, 2);
        FOR k IN 1 .. r.dpe_cantidad LOOP
            v_pieza := fn_cortar_estandar(r.id_variante, r.pre_factor, 'Corte para el pedido ' || v_pedido,
                                          CASE WHEN k = 1 THEN r.id_lote_reservado END);
            IF v_pieza IS NULL THEN
                pr_error('No hay fibra suficiente de ' || r.var_sku || ' para ' || r.dpe_cantidad || ' pieza(s) de '
                         || r.pre_factor || ' ' || r.unidad || ' (ninguna pieza libre alcanza para cortarla)');
            END IF;
            IF k = 1 THEN
                UPDATE detalle_pedido
                   SET dpe_cantidad = 1,
                       dpe_descuento = r.dpe_descuento - v_desc_corte * (r.dpe_cantidad - 1),
                       id_lote_reservado = v_pieza
                WHERE id_detalle_pedido = r.id_detalle_pedido;
            ELSE
                INSERT INTO detalle_pedido (id_pedido, id_presentacion, dpe_cantidad, dpe_precio_unitario, dpe_descuento,
                                            id_tarifa_iva, id_usuario_descuento, id_oferta, id_descuento_volumen,
                                            id_lote_reservado)
                VALUES (v_pedido, r.id_presentacion, 1, r.dpe_precio_unitario, v_desc_corte,
                        r.id_tarifa_iva, r.id_usuario_descuento, r.id_oferta, r.id_descuento_volumen, v_pieza);
            END IF;
        END LOOP;
    END LOOP;

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

-- 4. Catálogo con el disponible por cortes
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
       -- cortes estándar: cuántas piezas de esa medida salen de las piezas libres
       CASE WHEN p.prd_cortes_estandar = 1
            THEN NVL((SELECT SUM(FLOOR(pl.libre / pr.pre_factor)) FROM v_pieza_libre pl
                      WHERE pl.id_variante = v.id_variante AND pl.reservado = 0), 0)
            ELSE
       FLOOR(GREATEST(CASE WHEN p.prd_venta_por_pieza = 1
                           THEN LEAST(s.disponible, NVL((SELECT MAX(pl.libre) FROM v_pieza_libre pl
                                                         WHERE pl.id_variante = v.id_variante), 0))
                           ELSE s.disponible END, 0) / pr.pre_factor / pr.pre_incremento)
       * pr.pre_incremento END                                 AS disponible,
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
       pr.pre_factor                                           AS factor,
       p.prd_cortes_estandar                                   AS cortes_estandar
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

-- 6. Producto: fibra de caucho en planchas de 24 pie2
DECLARE
    v_sistema NUMBER;
    v_bodega  NUMBER;
    v_color   NUMBER;
    v_cat     NUMBER;
    v_marca   NUMBER;
    v_prd     NUMBER;
    v_var     NUMBER;
    v_val     NUMBER;
    v_mov     NUMBER;
    v_lote    NUMBER;
    v_n       NUMBER;
    v_colores SYS.ODCIVARCHAR2LIST := SYS.ODCIVARCHAR2LIST('Negro', 'Café');
    v_planchas SYS.ODCINUMBERLIST  := SYS.ODCINUMBERLIST(4, 3);
    v_cod     SYS.ODCIVARCHAR2LIST := SYS.ODCIVARCHAR2LIST('NEG', 'CAF');

    PROCEDURE pres(p_variante IN NUMBER, p_desc IN VARCHAR2, p_factor IN NUMBER, p_precio IN NUMBER) IS
        v_pre NUMBER;
    BEGIN
        SELECT MAX(id_presentacion) INTO v_pre
        FROM presentacion WHERE id_variante = p_variante AND pre_descripcion = p_desc;
        IF v_pre IS NULL THEN
            INSERT INTO presentacion (id_variante, pre_descripcion, pre_factor)
            VALUES (p_variante, p_desc, p_factor)
            RETURNING id_presentacion INTO v_pre;
            -- vigente desde ayer: ver 06 (zona horaria del contenedor vs la API)
            INSERT INTO historial_precio (id_presentacion, hpr_precio, hpr_vigente_desde, id_usuario)
            VALUES (v_pre, p_precio, CAST(SYSDATE - 1 AS TIMESTAMP), v_sistema);
        END IF;
    END;
BEGIN
    SELECT MAX(id_producto) INTO v_prd FROM producto WHERE prd_codigo = 'CE-9101';
    IF v_prd IS NOT NULL THEN
        DBMS_OUTPUT.PUT_LINE('  = CE-9101 ya existe');
        RETURN;
    END IF;
    SELECT id_usuario INTO v_sistema FROM usuario WHERE usu_correo = 'sistema@comercialelite.local';
    SELECT id_usuario INTO v_bodega  FROM usuario WHERE usu_correo = 'inventario@comercialelite.local';
    fn_usuario_sesion(v_bodega);
    SELECT id_atributo  INTO v_color FROM atributo  WHERE atr_nombre = 'Color';
    SELECT id_categoria INTO v_cat   FROM categoria WHERE cat_codigo = 'suelas-1';
    SELECT MAX(id_marca) INTO v_marca FROM marca WHERE mar_nombre = 'Suelas del Pacífico';

    INSERT INTO producto (id_categoria, id_unidad_medida, id_tarifa_iva, prd_codigo, prd_nombre, prd_descripcion,
                          prd_uso, prd_imagen_url, prd_publicado, prd_venta_por_pieza, prd_cortes_estandar, id_marca)
    VALUES (v_cat, 'pie2', '4', 'CE-9101', 'Fibra de caucho para suela (plancha de 24 pie²)',
            'Plancha de fibra de caucho de 24 pie². Se vende la plancha o cortes fijos: 1/2, 1/4, 2 pies y 1 pie.',
            'Suelas y tapas de calzado, reparación',
            'https://thumb.wikimedia.org/wikipedia/commons/thumb/4/42/Crepe_rubbers.jpg/960px-Crepe_rubbers.jpg',
            1, 1, 1, v_marca)
    RETURNING id_producto INTO v_prd;

    -- Una sola entrada de inventario para todas las planchas; cada plancha es su lote
    INSERT INTO movimiento_inventario (id_tipo_movimiento, id_usuario, mov_motivo)
    VALUES ('INI', v_bodega, 'Inventario inicial: planchas de fibra de caucho')
    RETURNING id_movimiento INTO v_mov;

    FOR i IN 1 .. v_colores.COUNT LOOP
        INSERT INTO variante (id_producto, var_sku) VALUES (v_prd, 'CE-9101-0' || i)
        RETURNING id_variante INTO v_var;
        SELECT MAX(id_valor_atributo) INTO v_val FROM valor_atributo
        WHERE id_atributo = v_color AND val_valor = v_colores(i);
        IF v_val IS NULL THEN
            INSERT INTO valor_atributo (id_atributo, val_valor) VALUES (v_color, v_colores(i))
            RETURNING id_valor_atributo INTO v_val;
        END IF;
        INSERT INTO variante_valor (id_variante, id_atributo, id_valor_atributo) VALUES (v_var, v_color, v_val);

        -- La escalera de cortes. Precios SIN IVA; mas barato por pie2 mientras mas grande
        pres(v_var, 'Plancha (24 pie²)', 24, 42.00);
        pres(v_var, '1/2 plancha (12 pie²)', 12, 22.50);
        pres(v_var, '1/4 plancha (6 pie²)', 6, 12.00);
        pres(v_var, '2 pies', 2, 4.20);
        pres(v_var, '1 pie', 1, 2.20);

        FOR k IN 1 .. v_planchas(i) LOOP
            INSERT INTO lote (id_variante, lot_costo_unitario, lot_codigo_proveedor)
            VALUES (v_var, 1.10, 'PL-' || v_cod(i) || '-' || LPAD(k, 3, '0'))
            RETURNING id_lote INTO v_lote;
            INSERT INTO detalle_movimiento (id_movimiento, id_lote, dmo_cantidad) VALUES (v_mov, v_lote, 24);
        END LOOP;
    END LOOP;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('  + producto CE-9101 con 7 planchas');
END;
/

ALTER SESSION SET CURRENT_SCHEMA = ecommerce;
-- 7. Vistas espejo del e-commerce (el SELECT * se expande al crearlas)
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