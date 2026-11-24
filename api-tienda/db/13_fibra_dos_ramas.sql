/*==============================================================*/
/* Migracion: fibra de caucho, plancha de 12 pie2 y DOS RAMAS   */
/* de corte                                                     */
/*                                                              */
/* Correccion: la plancha mide 12 pie2 (1/2 plancha = 6 = tres  */
/* cortes de 2 pies, como en el ejemplo del negocio), no 24.    */
/* Y la fibra tiene dos formas de medida que NO se mezclan:     */
/*                                                              */
/*            plancha (12)                                      */
/*                 |                                            */
/*            1/2 plancha (6)                                   */
/*           /               \                                  */
/*   1/4 plancha (3)       2 pies (2)      <- rama de pies      */
/*        |                    |                                */
/*   1/8 plancha (1.5)     1 pie (1)                            */
/*   (rama de fracciones)                                       */
/*                                                              */
/* Si una 1/2 plancha se corta en cuartos, esos cuartos ya no   */
/* se cortan en pies (y viceversa).                             */
/*                                                              */
/*  1. presentacion.pre_corte_de: la medida de la pieza de la   */
/*     que sale este corte (NULL = pieza entera, la plancha).   */
/*     El arbol de cortes es dato, no codigo.                   */
/*  2. fn_cortar_estandar recorre el arbol: solo corta piezas   */
/*     que esten en el camino hacia la medida pedida.           */
/*  3. fn_disponible_corte: cuantas piezas de una medida salen  */
/*     de las piezas libres (un cuarto no cuenta para pies).    */
/*     v_catalogo la usa.                                       */
/*  4. CE-9101: presentaciones con la medida real (12, 6, 3,    */
/*     1.5, 2, 1) y su arbol; el inventario de prueba (planchas */
/*     de 24 y sus cortes) se da de baja con un ajuste y entran */
/*     7 planchas de 12. El pedido de prueba pendiente con      */
/*  5. fn_crear_pedido: una pieza elegida (id_lote) de un corte */
/*     estandar ya no se ve "reservada" por su propia linea.    */
/*     fibra se cancela (liberaba piezas que ya no existen).    */
/*                                                              */
/* Se puede correr mas de una vez.                              */
/*==============================================================*/
SET DEFINE OFF
SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

ALTER SESSION SET CURRENT_SCHEMA = produccion;

-- 1. Estructura
DECLARE
    v_n NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_n FROM all_tab_columns
    WHERE owner = 'PRODUCCION' AND table_name = 'PRESENTACION' AND column_name = 'PRE_CORTE_DE';
    IF v_n = 0 THEN
        EXECUTE IMMEDIATE 'ALTER TABLE produccion.presentacion ADD pre_corte_de NUMBER(12,3) NULL';
        EXECUTE IMMEDIATE 'ALTER TABLE produccion.presentacion ADD CONSTRAINT ck_presentacion_corte_de
            CHECK (pre_corte_de IS NULL OR pre_corte_de > pre_factor)';
        EXECUTE IMMEDIATE q'[COMMENT ON COLUMN produccion.presentacion.pre_corte_de IS 'Cortes estandar: medida (en unidad base) de la pieza de la que sale este corte. NULL = pieza entera (plancha). Define el arbol de cortes: 12 -> 6 -> {3 -> 1.5 | 2 -> 1}.']';
        DBMS_OUTPUT.PUT_LINE('  + presentacion.pre_corte_de');
    END IF;
END;
/

-- 2. Camino de cortes de una medida: [medida, padre, abuelo, ... , plancha]
CREATE OR REPLACE FUNCTION fn_ruta_corte(p_variante IN NUMBER, p_medida IN NUMBER)
RETURN SYS.ODCINUMBERLIST IS
    v_ruta  SYS.ODCINUMBERLIST := SYS.ODCINUMBERLIST(p_medida);
    v_padre NUMBER;
    v_hay   NUMBER;
BEGIN
    SELECT COUNT(pre_corte_de) INTO v_hay FROM presentacion WHERE id_variante = p_variante AND pre_activa = 1;
    IF v_hay = 0 THEN
        RETURN NULL; -- sin arbol definido: se usa la regla de divisibilidad
    END IF;
    LOOP
        SELECT MAX(pre_corte_de) INTO v_padre
        FROM presentacion WHERE id_variante = p_variante AND pre_activa = 1 AND pre_factor = v_ruta(v_ruta.COUNT);
        EXIT WHEN v_padre IS NULL OR v_ruta.COUNT > 10;
        v_ruta.EXTEND;
        v_ruta(v_ruta.COUNT) := v_padre;
    END LOOP;
    RETURN v_ruta;
END fn_ruta_corte;
/

-- ¿Es la medida un nodo del arbol (alguna presentacion la usa)?
CREATE OR REPLACE FUNCTION fn_es_corte(p_variante IN NUMBER, p_medida IN NUMBER) RETURN NUMBER IS
    v_n NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_n FROM presentacion WHERE id_variante = p_variante AND pre_activa = 1 AND pre_factor = p_medida;
    RETURN CASE WHEN v_n > 0 THEN 1 ELSE 0 END;
END fn_es_corte;
/


-- 3. Disponible de un corte: piezas libres en su camino (o retazos fuera del arbol)
CREATE OR REPLACE FUNCTION fn_disponible_corte(p_variante IN NUMBER, p_medida IN NUMBER) RETURN NUMBER IS
    v_ruta  SYS.ODCINUMBERLIST := fn_ruta_corte(p_variante, p_medida);
    v_total NUMBER := 0;
    FUNCTION en_ruta(x IN NUMBER) RETURN BOOLEAN IS
    BEGIN
        FOR i IN 1 .. v_ruta.COUNT LOOP
            IF v_ruta(i) = x THEN RETURN TRUE; END IF;
        END LOOP;
        RETURN FALSE;
    END;
BEGIN
    FOR p IN (SELECT saldo FROM v_pieza_libre WHERE id_variante = p_variante AND reservado = 0 AND saldo >= p_medida) LOOP
        -- sin arbol: todo cuenta; con arbol: las piezas del camino y los retazos fuera de medida
        IF v_ruta IS NULL OR en_ruta(p.saldo) OR fn_es_corte(p_variante, p.saldo) = 0 THEN
            v_total := v_total + FLOOR(p.saldo / p_medida);
        END IF;
    END LOOP;
    RETURN v_total;
END fn_disponible_corte;
/

-- 4. Corte en cascada siguiendo el arbol
CREATE OR REPLACE FUNCTION fn_cortar_estandar(p_variante IN NUMBER, p_medida IN NUMBER,
                                              p_motivo IN VARCHAR2 DEFAULT NULL,
                                              p_desde IN NUMBER DEFAULT NULL)
RETURN NUMBER IS
    v_ruta      SYS.ODCINUMBERLIST := fn_ruta_corte(p_variante, p_medida);
    v_pieza     NUMBER;
    v_tam       NUMBER;
    v_reservado NUMBER;
    v_corte     NUMBER;
    v_n         NUMBER;
    v_json      VARCHAR2(4000);
    v_lotes     SYS.ODCINUMBERLIST;
    v_sistema   NUMBER;
    v_previo    NUMBER := pk_sesion.usuario;
    FUNCTION num(x IN NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN RTRIM(TO_CHAR(x, 'FM9999990.999', 'NLS_NUMERIC_CHARACTERS=''.,'''), '.');
    END;
    FUNCTION en_ruta(x IN NUMBER) RETURN BOOLEAN IS
    BEGIN
        IF v_ruta IS NULL THEN RETURN TRUE; END IF;
        FOR i IN 1 .. v_ruta.COUNT LOOP
            IF v_ruta(i) = x THEN RETURN TRUE; END IF;
        END LOOP;
        RETURN FALSE;
    END;
    -- el corte que sigue a "tam" en el camino hacia la medida
    FUNCTION siguiente(tam IN NUMBER) RETURN NUMBER IS
        v NUMBER;
    BEGIN
        IF v_ruta IS NOT NULL THEN
            FOR i IN 2 .. v_ruta.COUNT LOOP
                IF v_ruta(i) = tam THEN RETURN v_ruta(i - 1); END IF;
            END LOOP;
            RETURN p_medida; -- retazo fuera del arbol: se corta directo
        END IF;
        -- sin arbol: el corte estandar mas grande que divide la pieza y la medida
        SELECT MAX(pre_factor) INTO v FROM presentacion
        WHERE id_variante = p_variante AND pre_activa = 1 AND pre_factor < tam AND pre_factor >= p_medida
          AND MOD(tam, pre_factor) = 0 AND MOD(pre_factor, p_medida) = 0;
        RETURN NVL(v, p_medida);
    END;
BEGIN
    IF p_medida IS NULL OR p_medida <= 0 THEN
        pr_error('La medida del corte debe ser mayor que cero');
    END IF;
    IF p_desde IS NOT NULL THEN
        SELECT MAX(saldo), MAX(reservado) INTO v_tam, v_reservado
        FROM v_pieza_libre WHERE id_lote = p_desde AND id_variante = p_variante;
        IF v_tam IS NULL THEN
            pr_error('La pieza ' || p_desde || ' no existe, está agotada o no es de esta variante');
        END IF;
        IF v_reservado > 0 THEN
            pr_error('La pieza ' || p_desde || ' ya está reservada por otro pedido pendiente');
        END IF;
        IF v_tam < p_medida OR (v_tam > p_medida AND NOT en_ruta(v_tam) AND fn_es_corte(p_variante, v_tam) = 1) THEN
            pr_error('De la pieza ' || p_desde || ' (' || num(v_tam) || ') no sale un corte de ' || num(p_medida)
                     || ': es de la otra forma de medida (fracciones de plancha y pies no se mezclan)');
        END IF;
        v_pieza := p_desde;
    ELSE
        -- 1) una pieza suelta de la medida exacta (la mas antigua)
        SELECT MIN(id_lote) KEEP (DENSE_RANK FIRST ORDER BY fecha_ingreso, id_lote) INTO v_pieza
        FROM v_pieza_libre WHERE id_variante = p_variante AND reservado = 0 AND saldo = p_medida;
        IF v_pieza IS NOT NULL THEN
            RETURN v_pieza;
        END IF;
        -- 2) la pieza mas pequena DEL CAMINO que alcanza (un cuarto nunca se corta en pies)
        FOR p IN (SELECT id_lote, saldo FROM v_pieza_libre
                  WHERE id_variante = p_variante AND reservado = 0 AND saldo > p_medida
                  ORDER BY saldo, fecha_ingreso, id_lote) LOOP
            IF en_ruta(p.saldo) THEN
                v_pieza := p.id_lote;
                v_tam := p.saldo;
                EXIT;
            END IF;
        END LOOP;
        -- 3) si no, un retazo fuera de medida (no es un corte del arbol)
        IF v_pieza IS NULL THEN
            FOR p IN (SELECT id_lote, saldo FROM v_pieza_libre
                      WHERE id_variante = p_variante AND reservado = 0 AND saldo > p_medida
                      ORDER BY saldo, fecha_ingreso, id_lote) LOOP
                IF fn_es_corte(p_variante, p.saldo) = 0 THEN
                    v_pieza := p.id_lote;
                    v_tam := p.saldo;
                    EXIT;
                END IF;
            END LOOP;
        END IF;
        IF v_pieza IS NULL THEN
            RETURN NULL;
        END IF;
    END IF;

    SELECT id_usuario INTO v_sistema FROM usuario WHERE usu_correo = 'sistema@comercialelite.local';
    WHILE v_tam > p_medida LOOP
        v_corte := siguiente(v_tam);
        -- piezas nuevas de v_corte; la original se queda con una de ellas o con el sobrante
        v_n := FLOOR(v_tam / v_corte) - CASE WHEN MOD(v_tam, v_corte) = 0 THEN 1 ELSE 0 END;
        v_json := '[';
        FOR i IN 1 .. v_n LOOP
            v_json := v_json || CASE WHEN i > 1 THEN ',' END || num(v_corte);
        END LOOP;
        v_json := v_json || ']';
        v_lotes := fn_fraccionar_lote(v_pieza, v_json, v_sistema,
                                      NVL(p_motivo, 'Corte estándar') || ': pieza de ' || num(v_tam)
                                      || ' en ' || (v_n + 1) || ' partes de ' || num(v_corte));
        v_pieza := v_lotes(1);
        v_tam := v_corte;
    END LOOP;
    pk_sesion.fijar_usuario(v_previo);
    RETURN v_pieza;
END fn_cortar_estandar;
/

-- 5. CE-9101: medidas reales, arbol de cortes e inventario de 12 pie2 por plancha
DECLARE
    v_sistema NUMBER;
    v_bodega  NUMBER;
    v_mov     NUMBER;
    v_lote    NUMBER;
    v_n       NUMBER;
    v_hecho   NUMBER;
    TYPE t_corte IS RECORD (viejo VARCHAR2(40), nuevo VARCHAR2(40), factor NUMBER, corte_de NUMBER, precio NUMBER);
    TYPE t_cortes IS TABLE OF t_corte;
    -- Precios SIN IVA (referenciales: se ajustan en la administracion). Mas barato por pie2 mientras mas grande.
    v_cortes t_cortes := t_cortes(
        t_corte('Plancha (24 pie²)',     'Plancha (12 pie²)',       12,  NULL, 24.00),
        t_corte('1/2 plancha (12 pie²)', '1/2 plancha (6 pie²)',     6,  12,   12.60),
        t_corte('1/4 plancha (6 pie²)',  '1/4 plancha (3 pie²)',     3,  6,    6.60),
        t_corte(NULL,                    '1/8 plancha (1,5 pie²)',   1.5, 3,   3.45),
        t_corte('2 pies',                '2 pies',                   2,  6,    4.40),
        t_corte('1 pie',                 '1 pie',                    1,  2,    2.30));
    v_pre NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_hecho FROM presentacion pr JOIN variante v ON v.id_variante = pr.id_variante
    WHERE v.var_sku LIKE 'CE-9101-%' AND pr.pre_descripcion = 'Plancha (12 pie²)';
    IF v_hecho > 0 THEN
        DBMS_OUTPUT.PUT_LINE('  = CE-9101 ya tiene la plancha de 12 pie2');
        RETURN;
    END IF;
    SELECT id_usuario INTO v_sistema FROM usuario WHERE usu_correo = 'sistema@comercialelite.local';
    SELECT id_usuario INTO v_bodega  FROM usuario WHERE usu_correo = 'inventario@comercialelite.local';
    fn_usuario_sesion(v_bodega);

    -- pedidos de prueba pendientes con fibra: reservaban cortes de planchas que no existian asi
    FOR p IN (SELECT DISTINCT d.id_pedido FROM detalle_pedido d
              JOIN presentacion pr ON pr.id_presentacion = d.id_presentacion
              JOIN variante v ON v.id_variante = pr.id_variante
              JOIN v_pedido_estado_actual ea ON ea.id_pedido = d.id_pedido
              WHERE v.var_sku LIKE 'CE-9101-%' AND ea.id_estado_pedido IN ('PEN', 'PAG')) LOOP
        fn_cambiar_estado_pedido(p.id_pedido, 'CAN', v_sistema, 'Cancelado: la plancha de fibra se corrigió a 12 pie²');
        DBMS_OUTPUT.PUT_LINE('  ~ pedido ' || p.id_pedido || ' cancelado');
    END LOOP;

    -- baja del inventario de prueba (planchas de 24 y sus cortes): ajuste negativo por pieza
    FOR l IN (SELECT pl.id_lote, pl.id_variante, pl.saldo FROM v_pieza_libre pl
              JOIN variante v ON v.id_variante = pl.id_variante WHERE v.var_sku LIKE 'CE-9101-%') LOOP
        v_mov := fn_registrar_ajuste(l.id_variante, 'AJN', l.saldo,
                                     'Corrección: la plancha de fibra mide 12 pie², no 24 (inventario de prueba dado de baja)',
                                     v_bodega, NULL, NULL, l.id_lote);
    END LOOP;

    -- presentaciones: medida real y arbol de cortes
    FOR v IN (SELECT id_variante, var_sku FROM variante WHERE var_sku LIKE 'CE-9101-%' ORDER BY var_sku) LOOP
        FOR i IN 1 .. v_cortes.COUNT LOOP
            v_pre := NULL;
            IF v_cortes(i).viejo IS NOT NULL THEN
                SELECT MAX(id_presentacion) INTO v_pre FROM presentacion
                WHERE id_variante = v.id_variante AND pre_descripcion = v_cortes(i).viejo;
            END IF;
            IF v_pre IS NOT NULL THEN
                UPDATE presentacion SET pre_descripcion = v_cortes(i).nuevo, pre_factor = v_cortes(i).factor,
                       pre_corte_de = v_cortes(i).corte_de
                WHERE id_presentacion = v_pre;
            ELSE
                INSERT INTO presentacion (id_variante, pre_descripcion, pre_factor, pre_corte_de)
                VALUES (v.id_variante, v_cortes(i).nuevo, v_cortes(i).factor, v_cortes(i).corte_de)
                RETURNING id_presentacion INTO v_pre;
            END IF;
            -- precio nuevo (el anterior queda en el historial); vigente desde ayer, ver 06
            INSERT INTO historial_precio (id_presentacion, hpr_precio, hpr_vigente_desde, id_usuario)
            VALUES (v_pre, v_cortes(i).precio, CAST(SYSDATE - 1 AS TIMESTAMP), v_sistema);
        END LOOP;
    END LOOP;

    -- 7 planchas reales de 12 pie2 (4 negras, 3 cafe): una pieza (lote) por plancha
    INSERT INTO movimiento_inventario (id_tipo_movimiento, id_usuario, mov_motivo)
    VALUES ('INI', v_bodega, 'Inventario de fibra: planchas de 12 pie²')
    RETURNING id_movimiento INTO v_mov;
    FOR v IN (SELECT id_variante, var_sku FROM variante WHERE var_sku LIKE 'CE-9101-%' ORDER BY var_sku) LOOP
        v_n := CASE WHEN v.var_sku LIKE '%-01' THEN 4 ELSE 3 END;
        FOR k IN 1 .. v_n LOOP
            INSERT INTO lote (id_variante, lot_costo_unitario, lot_codigo_proveedor)
            VALUES (v.id_variante, 1.10, 'P12-' || CASE WHEN v.var_sku LIKE '%-01' THEN 'NEG' ELSE 'CAF' END || '-' || LPAD(k, 3, '0'))
            RETURNING id_lote INTO v_lote;
            INSERT INTO detalle_movimiento (id_movimiento, id_lote, dmo_cantidad) VALUES (v_mov, v_lote, 12);
        END LOOP;
    END LOOP;

    UPDATE producto SET prd_nombre = 'Fibra de caucho para suela (plancha de 12 pie²)',
           prd_descripcion = 'Plancha de 12 pie². Se vende entera, en fracciones (1/2, 1/4, 1/8) o en pies (2 pies, 1 pie). Una 1/2 plancha se corta en cuartos o en pies, no en ambos.'
    WHERE prd_codigo = 'CE-9101';
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('  + CE-9101 con plancha de 12 pie2, arbol de cortes y 7 planchas');
END;
/

-- 5b. Pedido: la pieza elegida de un corte estandar se puede cortar
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
        -- la pieza elegida aun no cuenta como reservada por esta misma linea
        -- (si no, fn_cortar_estandar la veria ocupada y no podria cortarla)
        UPDATE detalle_pedido SET id_lote_reservado = NULL WHERE id_detalle_pedido = r.id_detalle_pedido;
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

-- 6. Catálogo: disponible de cada corte segun el arbol
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
            THEN fn_disponible_corte(v.id_variante, pr.pre_factor)
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
       p.prd_cortes_estandar                                   AS cortes_estandar,
       pr.pre_corte_de                                         AS corte_de
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