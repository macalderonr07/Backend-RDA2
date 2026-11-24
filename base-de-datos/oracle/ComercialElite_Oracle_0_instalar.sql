/*==============================================================*/
/* COMERCIAL ELITE - Instalador para Oracle 19c / 21c           */
/*                                                              */
/* Desde la carpeta donde están los scripts, como SYSTEM en la  */
/* PDB (en Oracle XE 21c la PDB se llama XEPDB1):               */
/*    sqlplus system@//localhost:1521/XEPDB1 @ComercialElite_Oracle_0_instalar.sql */
/*                                                              */
/* 1. Crea los usuarios PRODUCCION y ECOMMERCE y sus tablas.    */
/* 2. Carga los datos base, vistas, disparadores y funciones.   */
/* 3. Corre la prueba de humo (y la deshace al terminar).       */
/*                                                              */
/* Para reinstalar desde cero, antes:                           */
/*    DROP USER ecommerce CASCADE;                              */
/*    DROP USER produccion CASCADE;                             */
/*==============================================================*/
SPOOL ComercialElite_Oracle_instalacion.log
@@ComercialElite_Oracle_1_esquema.sql
@@ComercialElite_Oracle_2_logica.sql
@@ComercialElite_Oracle_3_prueba.sql
SPOOL OFF
EXIT
