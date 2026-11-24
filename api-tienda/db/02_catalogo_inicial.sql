/*==============================================================*/
/* Catalogo inicial de Comercial Elite (GENERADO, no editar)    */
/*   node db/generar-catalogo.mjs                                */
/* Fuente: data/catalogo.json del frontend.                     */
/*                                                              */
/* Como SYSTEM/SYSDBA en la PDB (escribe en el nodo PRODUCCION):*/
/*   sqlplus system@//localhost:1521/FREEPDB1 @02_catalogo_inicial.sql */
/*                                                              */
/* Se puede correr mas de una vez: un producto que ya existe    */
/* solo actualiza su uso e imagen (el historial de precios es   */
/* inmutable y no se duplica).                                  */
/*==============================================================*/
SET DEFINE OFF
SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
ALTER SESSION SET CURRENT_SCHEMA = produccion;

DECLARE
    v_usuario NUMBER;
    v_color   NUMBER;
    v_id      NUMBER;
    v_nuevos  PLS_INTEGER := 0;

    FUNCTION categoria(p_codigo IN VARCHAR2, p_nombre IN VARCHAR2, p_padre IN VARCHAR2) RETURN NUMBER IS
        v_cat   NUMBER;
        v_padre NUMBER;
    BEGIN
        SELECT MAX(id_categoria) INTO v_cat FROM categoria WHERE cat_codigo = p_codigo;
        IF v_cat IS NULL THEN
            IF p_padre IS NOT NULL THEN
                SELECT id_categoria INTO v_padre FROM categoria WHERE cat_codigo = p_padre;
            END IF;
            INSERT INTO categoria (id_categoria_padre, cat_codigo, cat_nombre)
            VALUES (v_padre, p_codigo, p_nombre)
            RETURNING id_categoria INTO v_cat;
            -- El color se define en la linea y lo heredan sus subcategorias
            IF p_padre IS NULL THEN
                INSERT INTO categoria_atributo (id_categoria, id_atributo) VALUES (v_cat, v_color);
            END IF;
        END IF;
        RETURN v_cat;
    END categoria;

    FUNCTION valor_color(p_valor IN VARCHAR2) RETURN NUMBER IS
        v_val NUMBER;
    BEGIN
        SELECT MAX(id_valor_atributo) INTO v_val
        FROM valor_atributo WHERE id_atributo = v_color AND val_valor = p_valor;
        IF v_val IS NULL THEN
            INSERT INTO valor_atributo (id_atributo, val_valor) VALUES (v_color, p_valor)
            RETURNING id_valor_atributo INTO v_val;
        END IF;
        RETURN v_val;
    END valor_color;

    PROCEDURE producto(p_codigo IN VARCHAR2, p_nombre IN VARCHAR2, p_linea IN VARCHAR2,
                       p_sub_codigo IN VARCHAR2, p_sub_nombre IN VARCHAR2, p_unidad IN VARCHAR2,
                       p_uso IN VARCHAR2, p_imagen_url IN VARCHAR2, p_fecha IN DATE,
                       p_presentacion IN VARCHAR2, p_factor IN NUMBER, p_precio IN NUMBER,
                       p_colores IN SYS.ODCIVARCHAR2LIST) IS
        v_prd NUMBER;
        v_cat NUMBER;
        v_var NUMBER;
        v_val NUMBER;
        v_pre NUMBER;
    BEGIN
        SELECT MAX(id_producto) INTO v_prd FROM producto WHERE prd_codigo = p_codigo;
        IF v_prd IS NOT NULL THEN
            UPDATE producto SET prd_uso = p_uso, prd_imagen_url = p_imagen_url WHERE id_producto = v_prd;
            RETURN;
        END IF;

        -- Las funciones locales del bloque no se pueden llamar dentro de un SQL
        v_cat := categoria(p_sub_codigo, p_sub_nombre, p_linea);
        INSERT INTO producto (id_categoria, id_unidad_medida, id_tarifa_iva, prd_codigo, prd_nombre,
                              prd_uso, prd_imagen_url, prd_publicado, prd_fecha_creacion)
        VALUES (v_cat, p_unidad, '4', p_codigo, p_nombre,
                p_uso, p_imagen_url, 1, CAST(p_fecha AS TIMESTAMP))
        RETURNING id_producto INTO v_prd;

        FOR i IN 1 .. p_colores.COUNT LOOP
            INSERT INTO variante (id_producto, var_sku)
            VALUES (v_prd, p_codigo || '-' || LPAD(i, 2, '0'))
            RETURNING id_variante INTO v_var;
            v_val := valor_color(p_colores(i));
            INSERT INTO variante_valor (id_variante, id_atributo, id_valor_atributo)
            VALUES (v_var, v_color, v_val);
            INSERT INTO presentacion (id_variante, pre_descripcion, pre_factor)
            VALUES (v_var, p_presentacion, p_factor)
            RETURNING id_presentacion INTO v_pre;
            INSERT INTO historial_precio (id_presentacion, hpr_precio, hpr_vigente_desde, id_usuario)
            VALUES (v_pre, p_precio, CAST(p_fecha AS TIMESTAMP), v_usuario);
        END LOOP;
        v_nuevos := v_nuevos + 1;
    END producto;
BEGIN
    -- Usuario tecnico de los datos base: queda como autor en precios y auditoria
    SELECT id_usuario INTO v_usuario FROM usuario WHERE usu_correo = 'sistema@comercialelite.local';
    fn_usuario_sesion(v_usuario);

    SELECT MAX(id_atributo) INTO v_color FROM atributo WHERE atr_nombre = 'Color';
    IF v_color IS NULL THEN
        INSERT INTO atributo (atr_nombre, atr_tipo_dato) VALUES ('Color', 'COLOR')
        RETURNING id_atributo INTO v_color;
    END IF;

    -- Lineas (categorias raiz), en el orden del catalogo
    v_id := categoria('cueros', 'Cueros', NULL);
    v_id := categoria('sinteticos', 'Sintéticos', NULL);
    v_id := categoria('suelas', 'Suelas', NULL);
    v_id := categoria('plantillas', 'Plantillas', NULL);
    v_id := categoria('hilos', 'Hilos', NULL);
    v_id := categoria('adhesivos', 'Adhesivos', NULL);
    v_id := categoria('herrajes', 'Herrajes', NULL);
    v_id := categoria('herramientas', 'Herramienta menor', NULL);

    -- Productos
    producto('CE-1042', 'Cuero graso natural', 'cueros', 'cueros-1', 'Vacuno',
             'pie2', 'Calzado casual y marroquinería', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/2/2d/Tannery_Manila_luxury_leather_cow_hideF.jpg/960px-Tannery_Manila_luxury_leather_cow_hideF.jpg',
             DATE '2026-09-15', 'Banda 18-29 pies', 23.5, 45.22, SYS.ODCIVARCHAR2LIST('Negro', 'Café', 'Miel'));
    producto('CE-1043', 'Cuero napa flor entera', 'cueros', 'cueros-1', 'Vacuno',
             'pie2', 'Calzado formal y marroquinería fina', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/6/6e/Nappaleder.JPG/960px-Nappaleder.JPG',
             DATE '2026-06-02', 'Banda 18-29 pies', 23.5, 50.87, SYS.ODCIVARCHAR2LIST('Negro', 'Café', 'Camel'));
    producto('CE-2010', 'Sintético PU texturizado', 'sinteticos', 'sinteticos-1', 'Poliuretano',
             'm', 'Calzado deportivo y casual', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/7/70/Synthetic_Leather.jpg/960px-Synthetic_Leather.jpg',
             DATE '2026-05-20', 'Rollo 1.4 m × 25 m', 25, 55.65, SYS.ODCIVARCHAR2LIST('Negro', 'Blanco', 'Café'));
    producto('CE-2011', 'Sintético símil serpiente', 'sinteticos', 'sinteticos-2', 'Poliuretano estampado',
             'm', 'Calzado de vestir y marroquinería de moda', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/c/cf/Python_bivittatus_skin.jpg/960px-Python_bivittatus_skin.jpg',
             DATE '2026-04-11', 'Rollo 1.4 m × 20 m', 20, 60.00, SYS.ODCIVARCHAR2LIST('Negro', 'Camel'));
    producto('CE-3005', 'Suela de caucho antideslizante modelo SR-220', 'suelas', 'suelas-1', 'Caucho',
             'par', 'Calzado de seguridad y trabajo', 'https://upload.wikimedia.org/wikipedia/commons/4/48/Shoe_sole_sewing.jpg',
             DATE '2026-03-10', 'Par, tallas 35 a 44', 1, 2.78, SYS.ODCIVARCHAR2LIST('Negro'));
    producto('CE-3006', 'Suela EVA liviana', 'suelas', 'suelas-2', 'EVA',
             'par', 'Calzado casual liviano', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/3/34/Hari_Mari_Outsole.jpg/960px-Hari_Mari_Outsole.jpg',
             DATE '2026-09-02', 'Par, tallas 34 a 42', 1, 2.35, SYS.ODCIVARCHAR2LIST('Blanco', 'Negro'));
    producto('CE-4001', 'Plantilla de armado prensada', 'plantillas', 'plantillas-1', 'Armado',
             'par', 'Base interna para el proceso de armado', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/d/de/Rockport_shoe_insole._Torsion_system_technology_by_Adidas_printing.jpg/960px-Rockport_shoe_insole._Torsion_system_technology_by_Adidas_printing.jpg',
             DATE '2026-02-18', 'Par, tallas 34 a 45', 1, 1.04, SYS.ODCIVARCHAR2LIST('Natural'));
    producto('CE-4002', 'Plantilla de terminado con látex', 'plantillas', 'plantillas-2', 'Terminado',
             'par', 'Confort y terminado final del calzado', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/9/98/Insoles-Plantillas-Plantari.jpg/960px-Insoles-Plantillas-Plantari.jpg',
             DATE '2026-01-22', 'Par, tallas 34 a 45', 1, 1.26, SYS.ODCIVARCHAR2LIST('Beige'));
    producto('CE-5001', 'Hilo encerado de nylon 210D', 'hilos', 'hilos-1', 'Nylon',
             'm', 'Costura de calzado y marroquinería', 'https://upload.wikimedia.org/wikipedia/commons/9/96/HKM_Suutarin_pikilankaa.jpg',
             DATE '2025-12-05', 'Cono 500 m', 500, 3.91, SYS.ODCIVARCHAR2LIST('Negro', 'Café', 'Blanco'));
    producto('CE-5002', 'Hilo de poliéster reforzado 30/3', 'hilos', 'hilos-2', 'Poliéster',
             'm', 'Costura de alta resistencia', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/a/a1/A_spool_of_bright_red_polyester_thread%2C_a_sewing_needle%2C_and_a_needle_threader.jpg/960px-A_spool_of_bright_red_polyester_thread%2C_a_sewing_needle%2C_and_a_needle_threader.jpg',
             DATE '2025-11-14', 'Cono 1000 m', 1000, 3.65, SYS.ODCIVARCHAR2LIST('Negro', 'Blanco'));
    producto('CE-6001', 'Adhesivo de contacto base solvente', 'adhesivos', 'adhesivos-1', 'Contacto',
             'l', 'Pegado de suelas y componentes', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/e/e9/2023_Butapren.jpg/960px-2023_Butapren.jpg',
             DATE '2025-10-30', 'Galón 3.7 L', 3.7, 11.74, SYS.ODCIVARCHAR2LIST('Ámbar'));
    producto('CE-6002', 'Cemento de poliuretano bicomponente', 'adhesivos', 'adhesivos-2', 'Poliuretano',
             'kg', 'Pegado de alta exigencia mecánica', 'https://upload.wikimedia.org/wikipedia/commons/6/62/Den_Braven_Sealants_-_Polyflex_440_cartridge.jpg',
             DATE '2025-09-19', 'Kit 1 kg', 1, 12.87, SYS.ODCIVARCHAR2LIST('Transparente'));
    producto('CE-7001', 'Ojalillo metálico niquelado', 'herrajes', 'herrajes-1', 'Ojalillos',
             'u', 'Cordonera de calzado y marroquinería', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/5/5d/Assorted_metal_eyelets_in_plastic_case_HN_Made_in_Sweden_ca_1970.jpg/960px-Assorted_metal_eyelets_in_plastic_case_HN_Made_in_Sweden_ca_1970.jpg',
             DATE '2025-08-08', 'Bolsa × 1000 u', 1000, 0.78, SYS.ODCIVARCHAR2LIST('Plateado', 'Dorado'));
    producto('CE-7002', 'Hebilla rectangular metálica', 'herrajes', 'herrajes-2', 'Hebillas',
             'u', 'Cierre y decoración de marroquinería', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/8/8a/Palladium_Plated_Belt_Buckle.jpg/960px-Palladium_Plated_Belt_Buckle.jpg',
             DATE '2025-07-01', 'Caja × 100 u', 100, 2.26, SYS.ODCIVARCHAR2LIST('Dorado', 'Plateado', 'Negro'));
    producto('CE-8001', 'Cuchilla de desbastar profesional', 'herramientas', 'herramientas-1', 'Corte',
             'u', 'Desbastado de cuero en taller', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/5/5c/Leathertools.jpg/960px-Leathertools.jpg',
             DATE '2025-06-15', 'Unidad', 1, 6.52, SYS.ODCIVARCHAR2LIST('Acero'));
    producto('CE-8002', 'Martillo de zapatero cabeza doble', 'herramientas', 'herramientas-2', 'Golpe',
             'u', 'Armado y terminado de calzado', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/b/b5/Marteaux_de_bottier.png/960px-Marteaux_de_bottier.png',
             DATE '2025-05-03', 'Unidad', 1, 7.74, SYS.ODCIVARCHAR2LIST('Madera y acero'));

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Catalogo inicial: ' || v_nuevos || ' productos nuevos, 16 en total.');
END;
/
EXIT
