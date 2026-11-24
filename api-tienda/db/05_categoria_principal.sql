/*==============================================================*/
/* Migracion: categorias principales para el e-commerce         */
/*   produccion.v_categoria_principal: categorias raiz (sin     */
/*   padre, es decir que NO son subcategoria), con productos    */
/*   publicados de todo su arbol; ecommerce.v_categoria_web.    */
/*                                                              */
/* Para una base YA instalada (una nueva ya la trae). El texto  */
/* de las vistas es el del script fuente.                       */
/*                                                              */
/* Como SYSTEM/SYSDBA en la PDB:                                */
/*   sqlplus system@//localhost:1521/FREEPDB1 @05_categoria_principal.sql */
/*==============================================================*/
SET DEFINE OFF
WHENEVER SQLERROR EXIT FAILURE

ALTER SESSION SET CURRENT_SCHEMA = produccion;
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

-- Contrato entre nodos: el e-commerce puede leerla (y compartirla con su rol)
GRANT SELECT ON produccion.v_categoria_principal TO ecommerce WITH GRANT OPTION;
GRANT SELECT ON produccion.v_categoria_principal TO elite_ecommerce;

ALTER SESSION SET CURRENT_SCHEMA = ecommerce;
CREATE OR REPLACE VIEW v_categoria_web AS
SELECT * FROM produccion.v_categoria_principal;
GRANT SELECT ON ecommerce.v_categoria_web TO elite_ecommerce;

SELECT owner, object_name, object_type FROM dba_objects
WHERE owner IN ('PRODUCCION', 'ECOMMERCE') AND status <> 'VALID';
PROMPT (si la consulta anterior no devolvio filas, todo quedo valido)
EXIT
