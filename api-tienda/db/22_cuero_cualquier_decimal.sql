/*==============================================================*/
/* Migracion: el cuero se pide con CUALQUIER decimal            */
/*                                                              */
/* El cuero se vendia de 0,25 en 0,25 pie2. Se mide con         */
/* cualquier decimal (23,4 pie2): sus formas de venta pasan a   */
/* incremento 0,01, que la tienda y la administracion muestran  */
/* como "Cualquier decimal". Solo cambia lo que estaba en       */
/* cuartos en productos de cuero por pieza (pie2). El sintetico */
/* sigue en cuartos de metro.                                   */
/* El trigger de presentacion avisa a la cache de la tienda.    */
/*                                                              */
/* Se puede correr mas de una vez.                              */
/*==============================================================*/
SET DEFINE OFF
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
ALTER SESSION SET CURRENT_SCHEMA = produccion;

UPDATE presentacion pr
SET pr.pre_incremento = 0.01
WHERE pr.pre_incremento = 0.25
  AND pr.id_variante IN (SELECT v.id_variante FROM variante v JOIN producto p ON p.id_producto = v.id_producto
                         WHERE p.prd_venta_por_pieza = 1 AND p.id_unidad_medida = 'pie2');
COMMIT;
EXIT
