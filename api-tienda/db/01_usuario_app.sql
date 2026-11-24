/*==============================================================*/
/* Usuario de la aplicacion web (nodo e-commerce)               */
/*                                                              */
/* Requisito: la base Comercial Elite ya instalada              */
/* (ComercialElite_Oracle_0_instalar.sql), que crea el rol      */
/* ELITE_ECOMMERCE con exactamente el contrato entre nodos.     */
/*                                                              */
/* Como SYSTEM/SYSDBA en la PDB, pasando la clave como argumento*/
/*   sqlplus system@//localhost:1521/FREEPDB1 @01_usuario_app.sql "<clave>" */
/*                                                              */
/* app_web NO es dueno de nada: solo recibe el rol. Asi un      */
/* fallo o una inyeccion en la API nunca alcanza las tablas de  */
/* produccion (stock, dinero, comprobantes).                    */
/*==============================================================*/
SET DEFINE ON
SET VERIFY OFF
WHENEVER SQLERROR EXIT FAILURE

DECLARE
    v_n NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_n FROM dba_users WHERE username = 'APP_WEB';
    IF v_n = 0 THEN
        EXECUTE IMMEDIATE 'CREATE USER app_web IDENTIFIED BY "&1"';
    ELSE
        EXECUTE IMMEDIATE 'ALTER USER app_web IDENTIFIED BY "&1"';
    END IF;
END;
/

GRANT CREATE SESSION TO app_web;
GRANT elite_ecommerce TO app_web;
ALTER USER app_web DEFAULT ROLE ALL;

PROMPT Usuario APP_WEB listo con el rol ELITE_ECOMMERCE.
EXIT
