/*==============================================================*/
/* Administracion de Comercial Elite: usuario de base, permisos  */
/* y datos esenciales del negocio                               */
/*                                                              */
/* Como SYSTEM/SYSDBA en la PDB, pasando la clave de app_admin: */
/*   sqlplus system@//localhost:1521/FREEPDB1 @11_administracion.sql "<clave>" */
/*                                                              */
/* app_admin es la aplicacion del nodo PRODUCCION (la tienda es */
/* app_web en el nodo e-commerce). No es dueno de nada: solo    */
/* recibe el rol ELITE_PRODUCCION. Las reglas de negocio (stock, */
/* precios, comprobantes, permisos por usuario) las hace cumplir */
/* la propia base con sus funciones y disparadores.             */
/*                                                              */
/* Se puede correr mas de una vez.                              */
/*==============================================================*/
SET DEFINE ON
SET VERIFY OFF
SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

-- 1. Usuario de la aplicacion de administracion
DECLARE
    v_n NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_n FROM dba_users WHERE username = 'APP_ADMIN';
    IF v_n = 0 THEN
        EXECUTE IMMEDIATE 'CREATE USER app_admin IDENTIFIED BY "&1"';
    ELSE
        EXECUTE IMMEDIATE 'ALTER USER app_admin IDENTIFIED BY "&1"';
    END IF;
END;
/
GRANT CREATE SESSION TO app_admin;
GRANT elite_produccion TO app_admin;
ALTER USER app_admin DEFAULT ROLE ALL;

SET DEFINE OFF

-- 2. El rol del nodo produccion alcanza tambien a lo agregado despues de la
--    instalacion (marcas, combos, descuentos por volumen y sus vistas).
BEGIN
    FOR t IN (SELECT table_name FROM all_tables
              WHERE owner = 'PRODUCCION'
                AND table_name IN ('MARCA', 'DESCUENTO_VOLUMEN', 'COMBO', 'COMBO_COMPONENTE')) LOOP
        EXECUTE IMMEDIATE 'GRANT SELECT, INSERT, UPDATE, DELETE ON produccion.' || t.table_name || ' TO elite_produccion';
    END LOOP;
    FOR v IN (SELECT view_name FROM all_views WHERE owner = 'PRODUCCION') LOOP
        EXECUTE IMMEDIATE 'GRANT SELECT ON produccion.' || v.view_name || ' TO elite_produccion';
    END LOOP;
END;
/

ALTER SESSION SET CURRENT_SCHEMA = produccion;

-- 3. Datos esenciales
DECLARE
    v_sistema NUMBER;
    v_prov    NUMBER;
    v_quito   NUMBER;
    v_dir     NUMBER;
    v_n       NUMBER;

    FUNCTION provincia(p_nombre IN VARCHAR2) RETURN NUMBER IS
        v_id NUMBER;
    BEGIN
        SELECT MAX(id_provincia) INTO v_id FROM provincia WHERE pvc_nombre = p_nombre;
        IF v_id IS NULL THEN
            INSERT INTO provincia (pvc_nombre) VALUES (p_nombre) RETURNING id_provincia INTO v_id;
        END IF;
        RETURN v_id;
    END;

    PROCEDURE ciudades(p_provincia IN VARCHAR2, p_nombres IN SYS.ODCIVARCHAR2LIST) IS
        v_p NUMBER := provincia(p_provincia);
    BEGIN
        FOR i IN 1 .. p_nombres.COUNT LOOP
            INSERT INTO ciudad (id_provincia, ciu_nombre)
            SELECT v_p, p_nombres(i) FROM dual
            WHERE NOT EXISTS (SELECT 1 FROM ciudad WHERE id_provincia = v_p AND ciu_nombre = p_nombres(i));
        END LOOP;
    END;

    PROCEDURE unidad(p_codigo IN VARCHAR2, p_nombre IN VARCHAR2) IS
    BEGIN
        INSERT INTO unidad_medida (id_unidad_medida, umd_nombre)
        SELECT p_codigo, p_nombre FROM dual
        WHERE NOT EXISTS (SELECT 1 FROM unidad_medida WHERE id_unidad_medida = p_codigo);
    END;

    PROCEDURE transportista(p_nombre IN VARCHAR2, p_telefono IN VARCHAR2, p_url IN VARCHAR2) IS
    BEGIN
        INSERT INTO transportista (tra_nombre, tra_telefono, tra_url_rastreo)
        SELECT p_nombre, p_telefono, p_url FROM dual
        WHERE NOT EXISTS (SELECT 1 FROM transportista WHERE tra_nombre = p_nombre);
    END;

    PROCEDURE proveedor(p_ruc IN VARCHAR2, p_razon IN VARCHAR2, p_comercial IN VARCHAR2, p_correo IN VARCHAR2,
                        p_telefono IN VARCHAR2) IS
    BEGIN
        INSERT INTO proveedor (id_tipo_identificacion, prv_identificacion, prv_razon_social, prv_nombre_comercial,
                               prv_correo, prv_telefono)
        SELECT '04', p_ruc, p_razon, p_comercial, p_correo, p_telefono FROM dual
        WHERE NOT EXISTS (SELECT 1 FROM proveedor WHERE prv_identificacion = p_ruc);
    END;

    PROCEDURE punto(p_est IN VARCHAR2, p_pto IN VARCHAR2, p_desc IN VARCHAR2) IS
    BEGIN
        INSERT INTO punto_emision (pem_establecimiento, pem_punto, pem_descripcion)
        SELECT p_est, p_pto, p_desc FROM dual
        WHERE NOT EXISTS (SELECT 1 FROM punto_emision WHERE pem_establecimiento = p_est AND pem_punto = p_pto);
    END;
BEGIN
    SELECT id_usuario INTO v_sistema FROM usuario WHERE usu_correo = 'sistema@comercialelite.local';
    fn_usuario_sesion(v_sistema);

    -- Provincias del Ecuador y sus cantones principales (cabecera cantonal).
    -- Tungurahua y Azuay con mas detalle: son los polos del calzado y el cuero.
    ciudades('Azuay',            SYS.ODCIVARCHAR2LIST('Cuenca', 'Gualaceo', 'Paute', 'Sígsig', 'Santa Isabel', 'Girón', 'Chordeleg'));
    ciudades('Bolívar',          SYS.ODCIVARCHAR2LIST('Guaranda', 'Chillanes', 'San Miguel', 'Caluma', 'Echeandía'));
    ciudades('Cañar',            SYS.ODCIVARCHAR2LIST('Azogues', 'Cañar', 'La Troncal', 'Biblián'));
    ciudades('Carchi',           SYS.ODCIVARCHAR2LIST('Tulcán', 'San Gabriel', 'El Ángel', 'Mira'));
    ciudades('Chimborazo',       SYS.ODCIVARCHAR2LIST('Riobamba', 'Guano', 'Alausí', 'Colta', 'Chambo'));
    ciudades('Cotopaxi',         SYS.ODCIVARCHAR2LIST('Latacunga', 'Salcedo', 'Pujilí', 'Saquisilí', 'La Maná'));
    ciudades('El Oro',           SYS.ODCIVARCHAR2LIST('Machala', 'Pasaje', 'Santa Rosa', 'Huaquillas', 'Piñas', 'El Guabo'));
    ciudades('Esmeraldas',       SYS.ODCIVARCHAR2LIST('Esmeraldas', 'Atacames', 'Quinindé', 'Muisne', 'San Lorenzo'));
    ciudades('Galápagos',        SYS.ODCIVARCHAR2LIST('Puerto Baquerizo Moreno', 'Puerto Ayora', 'Puerto Villamil'));
    ciudades('Guayas',           SYS.ODCIVARCHAR2LIST('Guayaquil', 'Durán', 'Samborondón', 'Daule', 'Milagro', 'Nobol', 'Playas'));
    ciudades('Imbabura',         SYS.ODCIVARCHAR2LIST('Ibarra', 'Otavalo', 'Cotacachi', 'Atuntaqui', 'Pimampiro'));
    ciudades('Loja',             SYS.ODCIVARCHAR2LIST('Loja', 'Catamayo', 'Macará', 'Cariamanga', 'Saraguro'));
    ciudades('Los Ríos',         SYS.ODCIVARCHAR2LIST('Babahoyo', 'Quevedo', 'Ventanas', 'Vinces', 'Buena Fe'));
    ciudades('Manabí',           SYS.ODCIVARCHAR2LIST('Portoviejo', 'Manta', 'Chone', 'Jipijapa', 'Bahía de Caráquez', 'Montecristi', 'El Carmen'));
    ciudades('Morona Santiago',  SYS.ODCIVARCHAR2LIST('Macas', 'Gualaquiza', 'Sucúa'));
    ciudades('Napo',             SYS.ODCIVARCHAR2LIST('Tena', 'Archidona', 'El Chaco'));
    ciudades('Orellana',         SYS.ODCIVARCHAR2LIST('Puerto Francisco de Orellana', 'La Joya de los Sachas', 'Loreto'));
    ciudades('Pastaza',          SYS.ODCIVARCHAR2LIST('Puyo', 'Mera', 'Santa Clara'));
    ciudades('Pichincha',        SYS.ODCIVARCHAR2LIST('Quito', 'Cayambe', 'Machachi', 'Sangolquí', 'Tabacundo', 'San Miguel de los Bancos', 'Pedro Vicente Maldonado', 'Puerto Quito'));
    ciudades('Santa Elena',      SYS.ODCIVARCHAR2LIST('Santa Elena', 'La Libertad', 'Salinas'));
    ciudades('Santo Domingo de los Tsáchilas', SYS.ODCIVARCHAR2LIST('Santo Domingo', 'La Concordia'));
    ciudades('Sucumbíos',        SYS.ODCIVARCHAR2LIST('Nueva Loja', 'Shushufindi', 'Cascales'));
    ciudades('Tungurahua',       SYS.ODCIVARCHAR2LIST('Ambato', 'Pelileo', 'Baños de Agua Santa', 'Píllaro', 'Cevallos', 'Quero', 'Mocha', 'Tisaleo', 'Patate'));
    ciudades('Zamora Chinchipe', SYS.ODCIVARCHAR2LIST('Zamora', 'Yantzaza', 'Zumbi'));

    -- Unidades de medida que usa el rubro (las de la instalacion ya estan)
    unidad('cm',  'Centímetro');
    unidad('mm',  'Milímetro');
    unidad('g',   'Gramo');
    unidad('ml',  'Mililitro');
    unidad('yd',  'Yarda');
    unidad('pie', 'Pie lineal');
    unidad('gal', 'Galón');

    -- Empresa (una sola fila) con su direccion matriz
    SELECT COUNT(*) INTO v_n FROM empresa;
    IF v_n = 0 THEN
        SELECT c.id_ciudad INTO v_quito FROM ciudad c JOIN provincia p ON p.id_provincia = c.id_provincia
        WHERE p.pvc_nombre = 'Pichincha' AND c.ciu_nombre = 'Quito';
        INSERT INTO direccion (id_cliente, id_ciudad, dir_calle_principal, dir_calle_secundaria, dir_referencia)
        VALUES (NULL, v_quito, 'Calle Esmeraldas', 'Venezuela', 'Centro histórico de Quito')
        RETURNING id_direccion INTO v_dir;
        INSERT INTO empresa (id_empresa, emp_ruc, emp_razon_social, emp_nombre_comercial, emp_eslogan, emp_correo,
                             emp_telefono, id_direccion_matriz, emp_dias_devolucion, emp_ambiente_sri,
                             emp_max_consumidor_final)
        VALUES (1, '1792345678001', 'COMERCIAL ELITE CIA. LTDA.', 'Comercial Elite',
                'Insumos para calzado y marroquinería', 'comercialelite313@gmail.com', '0987855906',
                v_dir, 8, '1', 50);
    END IF;

    -- Puntos de emision (SRI): el local y la tienda en linea
    punto('001', '001', 'Local matriz (Quito)');
    punto('001', '002', 'Tienda en línea');

    -- Transportistas habituales para envios a talleres de provincia
    transportista('Servientrega',         '1700737837', 'https://www.servientrega.com.ec/rastreo');
    transportista('Tramaco Express',      '1700872626', 'https://www.tramaco.com.ec');
    transportista('Laar Courier',         '1800527227', 'https://www.laarcourier.com');
    transportista('Retiro en el local',   NULL,         NULL);

    -- Proveedores de ejemplo (RUC ficticios con forma valida)
    proveedor('1891234567001', 'CURTIEMBRE ANDINA S.A.',        'Curtiembre Andina',  'ventas@curtiembreandina.ec', '032845100');
    proveedor('0991234567001', 'SINTETICOS DEL PACIFICO CIA. LTDA.', 'Sintecuero',     'pedidos@sintecuero.ec',      '042600200');
    proveedor('1791234567001', 'METALICAS QUITO S.A.',          'Metálicas Quito',    'info@metalicasquito.ec',     '022500300');

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('  datos esenciales listos');
END;
/

SELECT 'provincias: ' || (SELECT COUNT(*) FROM provincia) || ', ciudades: ' || (SELECT COUNT(*) FROM ciudad)
       || ', unidades: ' || (SELECT COUNT(*) FROM unidad_medida) || ', puntos: ' || (SELECT COUNT(*) FROM punto_emision)
       || ', transportistas: ' || (SELECT COUNT(*) FROM transportista) || ', proveedores: ' || (SELECT COUNT(*) FROM proveedor)
       AS resumen FROM dual;
EXIT
