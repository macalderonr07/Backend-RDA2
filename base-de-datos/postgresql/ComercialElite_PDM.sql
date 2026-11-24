/*==============================================================*/
/* COMERCIAL ELITE - Modelo físico corregido                    */
/* DBMS: PostgreSQL                                             */
/* Archivo único para ingeniería inversa en PowerDesigner       */
/* (File > Reverse Engineer > Database... > Using script files) */
/*                                                              */
/* Contiene solo lo que PowerDesigner convierte en modelo       */
/* físico: tablas, claves primarias, claves alternas (UNIQUE),  */
/* claves foráneas (referencias), restricciones CHECK, índices  */
/* y comentarios. No incluye funciones, disparadores, vistas    */
/* ni datos: esos van en ComercialElite_logica.sql, que se      */
/* ejecuta en la base después de crear estas tablas.            */
/*                                                              */
/* NODOS (un esquema por nodo; mañana, una PDB o un servidor)  */
/*   produccion  Ubicación, Seguridad, Auditoría, Clientes,     */
/*               Empresa, Productos, Compras, Ventas,           */
/*               Facturación, Cuentas por cobrar, Inventario    */
/*   ecommerce   Cuentas web, Carrito                           */
/*   Cada catálogo vive en el módulo que lo usa.                */
/*                                                              */
/* REGLAS DE DISTRIBUCIÓN                                       */
/*   - Cada tabla tiene un solo nodo dueño (el único que la     */
/*     escribe): no hay choques de claves entre nodos.          */
/*   - Las referencias entre nodos (fkx_) van solo de ecommerce */
/*     hacia produccion. Producción no depende del e-commerce.  */
/*   - Hoy son FK normales; al separar los nodos se reemplazan  */
/*     por réplicas de solo lectura (catálogo) o por validación */
/*     en las funciones que llaman a producción (cliente,       */
/*     pedido).                                                 */
/*                                                              */
/* VERIFICACIÓN DE FORMAS NORMALES                              */
/*   1FN Atributos atómicos, sin grupos repetitivos, toda tabla */
/*       con PK. Teléfonos, direcciones, valores de atributo,   */
/*       pagos, abonos y líneas de documentos van en tablas     */
/*       propias.                                               */
/*   2FN Las PK compuestas (usuario_rol, rol_permiso,           */
/*       categoria_atributo, variante_valor, item_carrito) no   */
/*       tienen atributos que dependan de solo una parte.       */
/*   3FN Ningún atributo no clave depende de otro no clave.     */
/*       NO se almacenan (se calculan en vistas):               */
/*        - totales de pedido, comprobante y nota de crédito    */
/*        - stock, saldo, fecha de ingreso y antigüedad de lote */
/*        - estado actual del pedido (último del historial)     */
/*        - precio vigente (último de historial_precio)         */
/*        - estado de recepción de la OC y saldo por pagar      */
/*        - saldo de cada cuenta por cobrar y deuda del cliente */
/*       SÍ se almacenan, por ser hechos propios:               */
/*        - precio, descuento y tarifa IVA en detalle_pedido    */
/*          (los del momento de la venta, no los actuales)      */
/*        - costo real en lote (puede diferir del de la OC)     */
/*        - montos de comprobante_compra (documento externo)    */
/*        - monto de cada cuenta por cobrar (crédito otorgado   */
/*          o dinero entregado: es el documento de la deuda)    */
/*        - descuento negociado de cada línea (el valor final   */
/*          pactado y el porcentaje se calculan a partir de él) */
/*        - oferta aplicada a cada línea; el descuento por      */
/*          oferta NO se guarda: sale de su porcentaje, que no  */
/*          cambia una vez usada en una venta                   */
/*        - último acceso de usuario y cuenta web (la bitácora  */
/*          se depura y no sirve para calcularlo)               */
/*        - montos de nota_credito_proveedor (documento externo)*/
/*                                                              */
/* COMPROBANTES                                                 */
/*   Venta: factura (electrónica, flujo SRI) o nota de venta    */
/*   (se registra con el número del talonario).                 */
/*   Compra: factura (con sus datos SRI e IVA), nota de venta o */
/*   sin comprobante (recibo). El tipo decide qué se exige.     */
/*       cuenta_por_cobrar NO guarda id_cliente: se obtiene     */
/*       del pedido (evita la dependencia pedido -> cliente).   */
/*   Caso especial: variante_valor está en 3FN pero no en FNBC  */
/*       (id_valor_atributo -> id_atributo, que es parte de una */
/*       clave candidata). Se acepta para garantizar un solo    */
/*       valor por atributo y variante de forma declarativa.    */
/*==============================================================*/

CREATE SCHEMA produccion;
CREATE SCHEMA ecommerce;


/*##############################################################*/
/* NODO PRODUCCIÓN                                              */
/* Operación interna: tienda física, inventario, compras,       */
/* facturación SRI, crédito y cobranza. Es el dueño de todo     */
/* dato que mueve stock, dinero o comprobantes.                 */
/*##############################################################*/


/*==============================================================*/
/* 1. UBICACIÓN                                                 */
/*    Provincias y ciudades.                                    */
/*==============================================================*/

CREATE TABLE produccion.provincia (
   id_provincia            SERIAL         NOT NULL,
   pvc_nombre              VARCHAR(40)    NOT NULL,
   CONSTRAINT pk_provincia PRIMARY KEY (id_provincia),
   CONSTRAINT ak_provincia_nombre UNIQUE (pvc_nombre)
);
COMMENT ON TABLE produccion.provincia IS 'Provincias.';

CREATE TABLE produccion.ciudad (
   id_ciudad               SERIAL         NOT NULL,
   id_provincia            INTEGER        NOT NULL,
   ciu_nombre              VARCHAR(60)    NOT NULL,
   CONSTRAINT pk_ciudad PRIMARY KEY (id_ciudad),
   CONSTRAINT ak_ciudad_provincia_nombre UNIQUE (id_provincia, ciu_nombre)
);
COMMENT ON TABLE produccion.ciudad IS 'Ciudades por provincia.';



/*==============================================================*/
/* 2. SEGURIDAD                                                 */
/*    Personal, roles y permisos del sistema interno.           */
/*==============================================================*/

CREATE TABLE produccion.usuario (
   id_usuario              SERIAL         NOT NULL,
   usu_correo              VARCHAR(120)   NOT NULL
      CONSTRAINT ckc_usu_correo CHECK (usu_correo = LOWER(usu_correo)),
   usu_hash_clave          VARCHAR(255)   NOT NULL,
   usu_activo              BOOLEAN        DEFAULT TRUE NOT NULL,
   usu_creado              TIMESTAMP      DEFAULT CURRENT_TIMESTAMP NOT NULL,
   usu_ultimo_acceso       TIMESTAMP      NULL,
   CONSTRAINT pk_usuario PRIMARY KEY (id_usuario),
   CONSTRAINT ak_usuario_correo UNIQUE (usu_correo)
);
COMMENT ON TABLE produccion.usuario IS 'Credenciales del personal (sistema interno). Supertipo de empleado. Los clientes web tienen su cuenta en ecommerce.cuenta_web.';
COMMENT ON COLUMN produccion.usuario.usu_ultimo_acceso IS 'Se guarda aunque la bitácora lo registre, porque la bitácora se depura por antigüedad.';
COMMENT ON COLUMN produccion.usuario.usu_hash_clave IS 'Hash de la contraseña (bcrypt/argon2), nunca la clave en texto plano.';

CREATE TABLE produccion.rol (
   id_rol                  SERIAL         NOT NULL,
   rol_codigo              VARCHAR(20)    NOT NULL,
   rol_nombre              VARCHAR(60)    NOT NULL,
   CONSTRAINT pk_rol PRIMARY KEY (id_rol),
   CONSTRAINT ak_rol_codigo UNIQUE (rol_codigo)
);
COMMENT ON TABLE produccion.rol IS 'Roles: ADMIN, VENDEDOR, BODEGA, COMPRAS, CLIENTE, SISTEMA.';

CREATE TABLE produccion.permiso (
   id_permiso              SERIAL         NOT NULL,
   per_codigo              VARCHAR(30)    NOT NULL,
   per_descripcion         VARCHAR(150)   NOT NULL,
   CONSTRAINT pk_permiso PRIMARY KEY (id_permiso),
   CONSTRAINT ak_permiso_codigo UNIQUE (per_codigo)
);
COMMENT ON TABLE produccion.permiso IS 'Acciones protegidas del sistema.';

CREATE TABLE produccion.usuario_rol (
   id_usuario              INTEGER        NOT NULL,
   id_rol                  INTEGER        NOT NULL,
   CONSTRAINT pk_usuario_rol PRIMARY KEY (id_usuario, id_rol)
);
COMMENT ON TABLE produccion.usuario_rol IS 'Asignación N:M de roles a usuarios.';

CREATE TABLE produccion.rol_permiso (
   id_rol                  INTEGER        NOT NULL,
   id_permiso              INTEGER        NOT NULL,
   CONSTRAINT pk_rol_permiso PRIMARY KEY (id_rol, id_permiso)
);
COMMENT ON TABLE produccion.rol_permiso IS 'Asignación N:M de permisos a roles.';

CREATE TABLE produccion.empleado (
   id_usuario              INTEGER        NOT NULL,
   id_tipo_identificacion  CHAR(2)        NOT NULL,
   epl_identificacion      VARCHAR(20)    NOT NULL,
   epl_nombres             VARCHAR(80)    NOT NULL,
   epl_apellidos           VARCHAR(80)    NOT NULL,
   epl_fecha_ingreso       DATE           DEFAULT CURRENT_DATE NOT NULL,
   CONSTRAINT pk_empleado PRIMARY KEY (id_usuario),
   CONSTRAINT ak_empleado_identificacion UNIQUE (id_tipo_identificacion, epl_identificacion)
);
COMMENT ON TABLE produccion.empleado IS 'Subtipo de usuario: personal de la empresa. Identifica al vendedor en ventas físicas.';



/*==============================================================*/
/* 3. AUDITORÍA                                                 */
/*    Bitácora de eventos y registro de cambios en tablas       */
/*    sensibles.                                                */
/*                                                              */
/*    Cada nodo tiene su propia bitácora (log_evento aquí,      */
/*    log_evento_web en el e-commerce): fragmentación           */
/*    horizontal por nodo. Ambas solo se insertan.              */
/*==============================================================*/

CREATE TABLE produccion.log_evento (
   id_log_evento           BIGSERIAL      NOT NULL,
   lev_fechahora           TIMESTAMP      DEFAULT CURRENT_TIMESTAMP NOT NULL,
   lev_nivel               VARCHAR(5)     NOT NULL
      CONSTRAINT ckc_lev_nivel CHECK (lev_nivel IN ('INFO', 'AVISO', 'ERROR')),
   lev_origen              VARCHAR(12)    NOT NULL
      CONSTRAINT ckc_lev_origen CHECK (lev_origen IN ('SEGURIDAD', 'VENTAS', 'FACTURACION', 'SRI', 'INVENTARIO', 'COMPRAS', 'CATALOGO', 'SISTEMA')),
   lev_evento              VARCHAR(40)    NOT NULL,
   lev_mensaje             VARCHAR(500)   NOT NULL,
   id_usuario              INTEGER        NULL,
   lev_ip                  VARCHAR(45)    NULL,
   lev_detalle             TEXT           NULL,
   CONSTRAINT pk_log_evento PRIMARY KEY (id_log_evento)
);
COMMENT ON TABLE produccion.log_evento IS 'Bitácora del sistema interno: accesos del personal, comprobantes emitidos, respuestas del SRI, ajustes, errores. Solo se inserta.';
COMMENT ON COLUMN produccion.log_evento.lev_evento IS 'Código del evento: LOGIN_OK, LOGIN_FALLIDO, FACTURA_EMITIDA, NC_EMITIDA, SRI_AUTORIZADA, SRI_RECHAZADA, AJUSTE_INVENTARIO...';
COMMENT ON COLUMN produccion.log_evento.lev_detalle IS 'Datos adicionales en JSON.';

CREATE TABLE produccion.auditoria (
   id_auditoria            BIGSERIAL      NOT NULL,
   aud_fechahora           TIMESTAMP      DEFAULT CURRENT_TIMESTAMP NOT NULL,
   aud_tabla               VARCHAR(60)    NOT NULL,
   aud_operacion           CHAR(1)        NOT NULL
      CONSTRAINT ckc_aud_operacion CHECK (aud_operacion IN ('I', 'U', 'D')),
   aud_id_registro         VARCHAR(100)   NOT NULL,
   aud_valores_anteriores  TEXT           NULL,
   aud_valores_nuevos      TEXT           NULL,
   id_usuario              INTEGER        NULL,
   aud_usuario_bd          VARCHAR(60)    NOT NULL,
   CONSTRAINT pk_auditoria PRIMARY KEY (id_auditoria),
   CONSTRAINT ckt_auditoria CHECK (
        (aud_operacion = 'I' AND aud_valores_anteriores IS NULL     AND aud_valores_nuevos IS NOT NULL)
     OR (aud_operacion = 'U' AND aud_valores_anteriores IS NOT NULL AND aud_valores_nuevos IS NOT NULL)
     OR (aud_operacion = 'D' AND aud_valores_anteriores IS NOT NULL AND aud_valores_nuevos IS NULL))
);
COMMENT ON TABLE produccion.auditoria IS 'Quién cambió qué en las tablas sensibles (usuarios, permisos, precios, ofertas, crédito, proveedores...). La llenan disparadores; solo se inserta.';
COMMENT ON COLUMN produccion.auditoria.aud_id_registro IS 'Clave primaria del registro afectado (las compuestas, separadas por coma).';
COMMENT ON COLUMN produccion.auditoria.aud_valores_anteriores IS 'Fila antes del cambio, en JSON (sin hashes de clave).';
COMMENT ON COLUMN produccion.auditoria.id_usuario IS 'Usuario de la aplicación que hizo el cambio (tomado de la sesión).';
COMMENT ON COLUMN produccion.auditoria.aud_usuario_bd IS 'Usuario de base de datos de la conexión.';



/*==============================================================*/
/* 4. CLIENTES                                                  */
/*    Clientes de todos los canales, contactos y perfiles de    */
/*    facturación.                                              */
/*==============================================================*/

CREATE TABLE produccion.tipo_identificacion (
   id_tipo_identificacion  CHAR(2)        NOT NULL,
   tid_nombre              VARCHAR(40)    NOT NULL,
   CONSTRAINT pk_tipo_identificacion PRIMARY KEY (id_tipo_identificacion),
   CONSTRAINT ak_tipo_identificacion_nombre UNIQUE (tid_nombre)
);
COMMENT ON TABLE produccion.tipo_identificacion IS 'Tipos de identificación con código SRI (RUC, cédula, pasaporte, consumidor final).';

CREATE TABLE produccion.cliente (
   id_cliente              SERIAL         NOT NULL,
   cli_nombres             VARCHAR(100)   NOT NULL,
   cli_apellidos           VARCHAR(100)   NULL,
   cli_correo              VARCHAR(120)   NULL
      CONSTRAINT ckc_cli_correo CHECK (cli_correo IS NULL OR cli_correo = LOWER(cli_correo)),
   cli_fecha_registro      TIMESTAMP      DEFAULT CURRENT_TIMESTAMP NOT NULL,
   cli_limite_credito      NUMERIC(12,2)  DEFAULT 0 NOT NULL
      CONSTRAINT ckc_cli_limite_credito CHECK (cli_limite_credito >= 0),
   CONSTRAINT pk_cliente PRIMARY KEY (id_cliente),
   CONSTRAINT ak_cliente_correo UNIQUE (cli_correo)
);
COMMENT ON COLUMN produccion.cliente.cli_limite_credito IS 'Deuda máxima permitida (ventas a crédito + avances). 0 = sin crédito.';
COMMENT ON TABLE produccion.cliente IS 'Quien compra, en cualquier canal. Maestro en producción (crédito, facturas, deuda). Si compra en la web con cuenta, su acceso está en ecommerce.cuenta_web.';

CREATE TABLE produccion.telefono (
   id_telefono             SERIAL         NOT NULL,
   id_cliente              INTEGER        NOT NULL,
   tel_numero              VARCHAR(15)    NOT NULL,
   tel_tipo                VARCHAR(5)     DEFAULT 'MOVIL' NOT NULL
      CONSTRAINT ckc_tel_tipo CHECK (tel_tipo IN ('MOVIL', 'FIJO')),
   CONSTRAINT pk_telefono PRIMARY KEY (id_telefono),
   CONSTRAINT ak_telefono_cliente_numero UNIQUE (id_cliente, tel_numero)
);
COMMENT ON TABLE produccion.telefono IS 'Teléfonos de contacto del cliente.';

CREATE TABLE produccion.direccion (
   id_direccion            SERIAL         NOT NULL,
   id_cliente              INTEGER        NULL,
   id_ciudad               INTEGER        NOT NULL,
   dir_calle_principal     VARCHAR(120)   NOT NULL,
   dir_numero              VARCHAR(15)    NULL,
   dir_calle_secundaria    VARCHAR(120)   NULL,
   dir_referencia          VARCHAR(200)   NULL,
   dir_activa              BOOLEAN        DEFAULT TRUE NOT NULL,
   CONSTRAINT pk_direccion PRIMARY KEY (id_direccion)
);
COMMENT ON TABLE produccion.direccion IS 'Direcciones de clientes (o de la empresa si id_cliente es nulo). Inmutable una vez usada: se desactiva y se crea otra.';

CREATE TABLE produccion.datos_facturacion (
   id_datos_facturacion    SERIAL         NOT NULL,
   id_cliente              INTEGER        NOT NULL,
   id_tipo_identificacion  CHAR(2)        NOT NULL,
   dfa_identificacion      VARCHAR(20)    NOT NULL,
   dfa_razon_social        VARCHAR(150)   NOT NULL,
   dfa_correo              VARCHAR(120)   NULL,
   id_direccion            INTEGER        NULL,
   dfa_activo              BOOLEAN        DEFAULT TRUE NOT NULL,
   CONSTRAINT pk_datos_facturacion PRIMARY KEY (id_datos_facturacion)
);
COMMENT ON TABLE produccion.datos_facturacion IS 'Perfiles de facturación del cliente (cédula o RUC). Inmutable una vez usado en una factura.';



/*==============================================================*/
/* 5. EMPRESA                                                   */
/*    Datos de la empresa y series de emisión del SRI.          */
/*==============================================================*/

CREATE TABLE produccion.empresa (
   id_empresa              SMALLINT       DEFAULT 1 NOT NULL
      CONSTRAINT ckc_id_empresa CHECK (id_empresa = 1),
   emp_ruc                 CHAR(13)       NOT NULL,
   emp_razon_social        VARCHAR(150)   NOT NULL,
   emp_nombre_comercial    VARCHAR(100)   NOT NULL,
   emp_eslogan             VARCHAR(150)   NULL,
   emp_correo              VARCHAR(120)   NOT NULL,
   emp_telefono            VARCHAR(15)    NULL,
   id_direccion_matriz     INTEGER        NOT NULL,
   emp_dias_devolucion     SMALLINT       DEFAULT 30 NOT NULL
      CONSTRAINT ckc_emp_dias_devolucion CHECK (emp_dias_devolucion > 0),
   emp_ambiente_sri        CHAR(1)        DEFAULT '1' NOT NULL
      CONSTRAINT ckc_emp_ambiente_sri CHECK (emp_ambiente_sri IN ('1', '2')),
   emp_max_consumidor_final NUMERIC(12,2) DEFAULT 50 NOT NULL
      CONSTRAINT ckc_emp_max_consumidor_final CHECK (emp_max_consumidor_final >= 0),
   CONSTRAINT pk_empresa PRIMARY KEY (id_empresa)
);
COMMENT ON TABLE produccion.empresa IS 'Datos institucionales y parámetros del negocio (fila única).';
COMMENT ON COLUMN produccion.empresa.emp_dias_devolucion IS 'Plazo de la política de devoluciones, en días desde el comprobante de venta.';
COMMENT ON COLUMN produccion.empresa.emp_ambiente_sri IS '1 = pruebas, 2 = producción.';
COMMENT ON COLUMN produccion.empresa.emp_max_consumidor_final IS 'Monto máximo de una factura sin identificar al comprador (SRI: USD 50 desde nov. 2022).';

CREATE TABLE produccion.punto_emision (
   id_punto_emision        SERIAL         NOT NULL,
   pem_establecimiento     CHAR(3)        NOT NULL,
   pem_punto               CHAR(3)        NOT NULL,
   pem_descripcion         VARCHAR(60)    NOT NULL,
   pem_activo              BOOLEAN        DEFAULT TRUE NOT NULL,
   CONSTRAINT pk_punto_emision PRIMARY KEY (id_punto_emision),
   CONSTRAINT ak_punto_emision_serie UNIQUE (pem_establecimiento, pem_punto)
);
COMMENT ON TABLE produccion.punto_emision IS 'Series SRI establecimiento-punto. Ej.: 001-001 tienda, 001-002 e-commerce.';



/*==============================================================*/
/* 6. PRODUCTOS                                                 */
/*    Catálogo maestro: categorías, atributos, variantes,       */
/*    presentaciones, precios y ofertas.                        */
/*                                                              */
/*    Oferta: descuento preestablecido por producto. Se         */
/*    aplica solo al crear el pedido (en la web es el único     */
/*    descuento). Una oferta ya usada no cambia su %: se        */
/*    pausa o se le pone fecha de fin.                          */
/*==============================================================*/

CREATE TABLE produccion.unidad_medida (
   id_unidad_medida        VARCHAR(4)     NOT NULL,
   umd_nombre              VARCHAR(30)    NOT NULL,
   CONSTRAINT pk_unidad_medida PRIMARY KEY (id_unidad_medida),
   CONSTRAINT ak_unidad_medida_nombre UNIQUE (umd_nombre)
);
COMMENT ON TABLE produccion.unidad_medida IS 'Unidades base en las que se lleva el inventario (metro, unidad, pie cuadrado...).';

CREATE TABLE produccion.tarifa_iva (
   id_tarifa_iva           VARCHAR(2)     NOT NULL,
   tiv_porcentaje          NUMERIC(5,2)   NOT NULL
      CONSTRAINT ckc_tiv_porcentaje CHECK (tiv_porcentaje >= 0),
   tiv_descripcion         VARCHAR(40)    NOT NULL,
   tiv_vigente             BOOLEAN        DEFAULT TRUE NOT NULL,
   CONSTRAINT pk_tarifa_iva PRIMARY KEY (id_tarifa_iva)
);
COMMENT ON TABLE produccion.tarifa_iva IS 'Tarifas de IVA con su código de porcentaje SRI. Una tarifa nueva es una fila nueva.';

CREATE TABLE produccion.categoria (
   id_categoria            SERIAL         NOT NULL,
   id_categoria_padre      INTEGER        NULL,
   cat_codigo              VARCHAR(20)    NOT NULL,
   cat_nombre              VARCHAR(80)    NOT NULL,
   cat_activa              BOOLEAN        DEFAULT TRUE NOT NULL,
   CONSTRAINT pk_categoria PRIMARY KEY (id_categoria),
   CONSTRAINT ak_categoria_codigo UNIQUE (cat_codigo),
   CONSTRAINT ckt_categoria CHECK (id_categoria_padre <> id_categoria)
);
COMMENT ON TABLE produccion.categoria IS 'Clasificación jerárquica del catálogo. Padre opcional (raíz = nulo).';

CREATE TABLE produccion.atributo (
   id_atributo             SERIAL         NOT NULL,
   atr_nombre              VARCHAR(40)    NOT NULL,
   atr_tipo_dato           VARCHAR(6)     DEFAULT 'TEXTO' NOT NULL
      CONSTRAINT ckc_atr_tipo_dato CHECK (atr_tipo_dato IN ('TEXTO', 'NUMERO', 'COLOR')),
   CONSTRAINT pk_atributo PRIMARY KEY (id_atributo),
   CONSTRAINT ak_atributo_nombre UNIQUE (atr_nombre)
);
COMMENT ON TABLE produccion.atributo IS 'Características que describen variantes (color, grosor...).';

CREATE TABLE produccion.categoria_atributo (
   id_categoria            INTEGER        NOT NULL,
   id_atributo             INTEGER        NOT NULL,
   CONSTRAINT pk_categoria_atributo PRIMARY KEY (id_categoria, id_atributo)
);
COMMENT ON TABLE produccion.categoria_atributo IS 'Atributos que aplican a una categoría y a sus subcategorías (N:M).';

CREATE TABLE produccion.valor_atributo (
   id_valor_atributo       SERIAL         NOT NULL,
   id_atributo             INTEGER        NOT NULL,
   val_valor               VARCHAR(60)    NOT NULL,
   CONSTRAINT pk_valor_atributo PRIMARY KEY (id_valor_atributo),
   CONSTRAINT ak_valor_atributo_valor UNIQUE (id_atributo, val_valor),
   CONSTRAINT ak_valor_atributo_par UNIQUE (id_valor_atributo, id_atributo)
);
COMMENT ON TABLE produccion.valor_atributo IS 'Valores permitidos de cada atributo (Negro, Café, 1.2 mm...).';

CREATE TABLE produccion.producto (
   id_producto             SERIAL         NOT NULL,
   id_categoria            INTEGER        NOT NULL,
   id_unidad_medida        VARCHAR(4)     NOT NULL,
   id_tarifa_iva           VARCHAR(2)     NOT NULL,
   prd_codigo              VARCHAR(20)    NOT NULL,
   prd_nombre              VARCHAR(150)   NOT NULL,
   prd_descripcion         TEXT           NULL,
   prd_uso                 VARCHAR(200)   NULL,
   prd_imagen_url          VARCHAR(500)   NULL
      CONSTRAINT ckc_prd_imagen_url CHECK (prd_imagen_url IS NULL OR prd_imagen_url ~ '^https?://[^[:space:]]+$'),
   prd_publicado           BOOLEAN        DEFAULT FALSE NOT NULL,
   prd_venta_por_pieza     BOOLEAN        DEFAULT FALSE NOT NULL,
   prd_fecha_creacion      TIMESTAMP      DEFAULT CURRENT_TIMESTAMP NOT NULL,
   CONSTRAINT pk_producto PRIMARY KEY (id_producto),
   CONSTRAINT ak_producto_codigo UNIQUE (prd_codigo)
);
COMMENT ON TABLE produccion.producto IS 'Artículo comercial. Define la unidad base del inventario y la tarifa de IVA.';
COMMENT ON COLUMN produccion.producto.prd_publicado IS 'Visible en el e-commerce.';
COMMENT ON COLUMN produccion.producto.prd_imagen_url IS 'URL absoluta (http/https) de la imagen principal del producto. La imagen no se guarda en la base.';
COMMENT ON COLUMN produccion.producto.prd_venta_por_pieza IS 'Cada lote es una pieza física (banda de cuero): una línea de venta sale de una sola pieza.';

CREATE TABLE produccion.variante (
   id_variante             SERIAL         NOT NULL,
   id_producto             INTEGER        NOT NULL,
   var_sku                 VARCHAR(30)    NOT NULL,
   var_stock_minimo        NUMERIC(12,3)  DEFAULT 0 NOT NULL
      CONSTRAINT ckc_var_stock_minimo CHECK (var_stock_minimo >= 0),
   var_activa              BOOLEAN        DEFAULT TRUE NOT NULL,
   CONSTRAINT pk_variante PRIMARY KEY (id_variante),
   CONSTRAINT ak_variante_sku UNIQUE (var_sku)
);
COMMENT ON TABLE produccion.variante IS 'SKU concreto de un producto. Nivel en el que se controla el stock, en la unidad base.';

CREATE TABLE produccion.variante_valor (
   id_variante             INTEGER        NOT NULL,
   id_atributo             INTEGER        NOT NULL,
   id_valor_atributo       INTEGER        NOT NULL,
   CONSTRAINT pk_variante_valor PRIMARY KEY (id_variante, id_atributo)
);
COMMENT ON TABLE produccion.variante_valor IS 'Valor de cada atributo para una variante: uno por atributo. 3FN, no FNBC.';

CREATE TABLE produccion.presentacion (
   id_presentacion         SERIAL         NOT NULL,
   id_variante             INTEGER        NOT NULL,
   pre_descripcion         VARCHAR(40)    NOT NULL,
   pre_factor              NUMERIC(12,3)  NOT NULL
      CONSTRAINT ckc_pre_factor CHECK (pre_factor > 0),
   pre_cantidad_minima     NUMERIC(12,3)  DEFAULT 1 NOT NULL
      CONSTRAINT ckc_pre_cantidad_minima CHECK (pre_cantidad_minima > 0),
   pre_activa              BOOLEAN        DEFAULT TRUE NOT NULL,
   CONSTRAINT pk_presentacion PRIMARY KEY (id_presentacion),
   CONSTRAINT ak_presentacion_descripcion UNIQUE (id_variante, pre_descripcion)
);
COMMENT ON TABLE produccion.presentacion IS 'Forma de venta de una variante (Metro, Rollo 30 m) y su factor de conversión.';
COMMENT ON COLUMN produccion.presentacion.pre_factor IS 'Unidades base que contiene la presentación (Rollo 30 m = 30).';

CREATE TABLE produccion.historial_precio (
   id_historial_precio     SERIAL         NOT NULL,
   id_presentacion         INTEGER        NOT NULL,
   hpr_precio              NUMERIC(12,2)  NOT NULL
      CONSTRAINT ckc_hpr_precio CHECK (hpr_precio >= 0),
   hpr_vigente_desde       TIMESTAMP      DEFAULT CURRENT_TIMESTAMP NOT NULL,
   id_usuario              INTEGER        NOT NULL,
   CONSTRAINT pk_historial_precio PRIMARY KEY (id_historial_precio),
   CONSTRAINT ak_historial_precio_vigencia UNIQUE (id_presentacion, hpr_vigente_desde)
);
COMMENT ON TABLE produccion.historial_precio IS 'Precios sin IVA por presentación. El vigente es el último con vigente_desde <= ahora.';

CREATE TABLE produccion.oferta (
   id_oferta               SERIAL         NOT NULL,
   id_producto             INTEGER        NOT NULL,
   ofe_porcentaje          NUMERIC(5,2)   NOT NULL
      CONSTRAINT ckc_ofe_porcentaje CHECK (ofe_porcentaje > 0 AND ofe_porcentaje < 100),
   ofe_descripcion         VARCHAR(100)   NULL,
   ofe_desde               TIMESTAMP      DEFAULT CURRENT_TIMESTAMP NOT NULL,
   ofe_hasta               TIMESTAMP      NULL,
   ofe_activa              BOOLEAN        DEFAULT TRUE NOT NULL,
   id_usuario_registra     INTEGER        NOT NULL,
   ofe_fecha_registro      TIMESTAMP      DEFAULT CURRENT_TIMESTAMP NOT NULL,
   CONSTRAINT pk_oferta PRIMARY KEY (id_oferta),
   CONSTRAINT ckt_oferta CHECK (ofe_hasta IS NULL OR ofe_hasta > ofe_desde)
);
COMMENT ON TABLE produccion.oferta IS 'Descuento preestablecido de un producto, con vigencia y estado. Es el único descuento del e-commerce; se aplica solo al crear el pedido.';
COMMENT ON COLUMN produccion.oferta.ofe_activa IS 'Estado de la oferta: se puede pausar y reactivar. Vigente = activa y dentro de desde/hasta.';
COMMENT ON COLUMN produccion.oferta.ofe_hasta IS 'Fin de la oferta; nulo = hasta que se desactive.';



/*==============================================================*/
/* 7. COMPRAS                                                   */
/*    Proveedores, órdenes de compra, comprobantes, notas de    */
/*    crédito y pagos a proveedores.                            */
/*                                                              */
/*    orden_compra (BORRADOR -> EMITIDA) -> recepciones         */
/*    (kárdex COM, crean lotes) -> comprobante_compra           */
/*    -> pago_proveedor / nota_credito_proveedor                */
/*==============================================================*/

CREATE TABLE produccion.proveedor (
   id_proveedor            SERIAL         NOT NULL,
   id_tipo_identificacion  CHAR(2)        NOT NULL,
   prv_identificacion      VARCHAR(20)    NOT NULL,
   prv_razon_social        VARCHAR(150)   NOT NULL,
   prv_nombre_comercial    VARCHAR(100)   NULL,
   prv_correo              VARCHAR(120)   NULL,
   prv_telefono            VARCHAR(15)    NULL,
   prv_activo              BOOLEAN        DEFAULT TRUE NOT NULL,
   CONSTRAINT pk_proveedor PRIMARY KEY (id_proveedor),
   CONSTRAINT ak_proveedor_identificacion UNIQUE (id_tipo_identificacion, prv_identificacion)
);
COMMENT ON TABLE produccion.proveedor IS 'Proveedores de mercadería.';

CREATE TABLE produccion.orden_compra (
   id_orden_compra         SERIAL         NOT NULL,
   id_proveedor            INTEGER        NOT NULL,
   id_usuario_crea         INTEGER        NOT NULL,
   oc_fecha                DATE           DEFAULT CURRENT_DATE NOT NULL,
   oc_fecha_entrega_esperada DATE         NULL,
   oc_estado               VARCHAR(8)     DEFAULT 'BORRADOR' NOT NULL
      CONSTRAINT ckc_oc_estado CHECK (oc_estado IN ('BORRADOR', 'EMITIDA', 'CERRADA', 'ANULADA')),
   oc_observacion          VARCHAR(250)   NULL,
   CONSTRAINT pk_orden_compra PRIMARY KEY (id_orden_compra),
   CONSTRAINT ckt_orden_compra CHECK (oc_fecha_entrega_esperada IS NULL OR oc_fecha_entrega_esperada >= oc_fecha)
);
COMMENT ON TABLE produccion.orden_compra IS 'Orden de compra al proveedor. El estado de recepción se calcula del kárdex.';

CREATE TABLE produccion.detalle_orden_compra (
   id_detalle_orden_compra SERIAL         NOT NULL,
   id_orden_compra         INTEGER        NOT NULL,
   id_variante             INTEGER        NOT NULL,
   dco_cantidad            NUMERIC(12,3)  NOT NULL
      CONSTRAINT ckc_dco_cantidad CHECK (dco_cantidad > 0),
   dco_costo_unitario      NUMERIC(12,4)  NOT NULL
      CONSTRAINT ckc_dco_costo_unitario CHECK (dco_costo_unitario >= 0),
   CONSTRAINT pk_detalle_orden_compra PRIMARY KEY (id_detalle_orden_compra),
   CONSTRAINT ak_detalle_oc_variante UNIQUE (id_orden_compra, id_variante)
);
COMMENT ON TABLE produccion.detalle_orden_compra IS 'Cantidades en unidad base y costos pactados (sin IVA) por variante.';

CREATE TABLE produccion.comprobante_compra (
   id_comprobante_compra   SERIAL         NOT NULL,
   id_proveedor            INTEGER        NOT NULL,
   id_tipo_comprobante     CHAR(2)        DEFAULT '01' NOT NULL,
   cco_numero              VARCHAR(17)    NOT NULL,
   cco_clave_acceso        CHAR(49)       NULL,
   cco_fecha_emision       DATE           NOT NULL,
   cco_fecha_vencimiento   DATE           NOT NULL,
   cco_subtotal_0          NUMERIC(12,2)  DEFAULT 0 NOT NULL
      CONSTRAINT ckc_cco_subtotal_0 CHECK (cco_subtotal_0 >= 0),
   cco_subtotal_gravado    NUMERIC(12,2)  DEFAULT 0 NOT NULL
      CONSTRAINT ckc_cco_subtotal_gravado CHECK (cco_subtotal_gravado >= 0),
   cco_iva                 NUMERIC(12,2)  DEFAULT 0 NOT NULL
      CONSTRAINT ckc_cco_iva CHECK (cco_iva >= 0),
   id_usuario_registra     INTEGER        NOT NULL,
   CONSTRAINT pk_comprobante_compra PRIMARY KEY (id_comprobante_compra),
   CONSTRAINT ak_comprobante_compra_numero UNIQUE (id_proveedor, id_tipo_comprobante, cco_numero),
   CONSTRAINT ckt_comprobante_compra CHECK (cco_fecha_vencimiento >= cco_fecha_emision
        AND (id_tipo_comprobante = '01' OR (cco_iva = 0 AND cco_subtotal_gravado = 0 AND cco_clave_acceso IS NULL)))
);
COMMENT ON TABLE produccion.comprobante_compra IS 'Documento que respalda una compra, con los montos tal como constan: factura (se registra con sus datos SRI e IVA), nota de venta o sin comprobante (recibo; solo número y valor, sin IVA).';
COMMENT ON COLUMN produccion.comprobante_compra.cco_numero IS 'Factura y nota de venta: número SRI 001-001-000000123. Recibo: número interno.';
COMMENT ON COLUMN produccion.comprobante_compra.cco_subtotal_0 IS 'En nota de venta y recibo, el valor total (no discriminan IVA).';

CREATE TABLE produccion.pago_proveedor (
   id_pago_proveedor       SERIAL         NOT NULL,
   id_comprobante_compra   INTEGER        NOT NULL,
   id_metodo_pago          INTEGER        NOT NULL,
   ppr_monto               NUMERIC(12,2)  NOT NULL
      CONSTRAINT ckc_ppr_monto CHECK (ppr_monto > 0),
   ppr_fecha               DATE           DEFAULT CURRENT_DATE NOT NULL,
   ppr_referencia          VARCHAR(60)    NULL,
   id_usuario_registra     INTEGER        NOT NULL,
   CONSTRAINT pk_pago_proveedor PRIMARY KEY (id_pago_proveedor)
);
COMMENT ON TABLE produccion.pago_proveedor IS 'Pagos a comprobantes de compra. El saldo por pagar se calcula.';

CREATE TABLE produccion.nota_credito_proveedor (
   id_nota_credito_proveedor SERIAL       NOT NULL,
   id_comprobante_compra   INTEGER        NOT NULL,
   ncp_numero              VARCHAR(17)    NOT NULL,
   ncp_clave_acceso        CHAR(49)       NULL,
   ncp_fecha_emision       DATE           NOT NULL,
   ncp_subtotal_0          NUMERIC(12,2)  DEFAULT 0 NOT NULL
      CONSTRAINT ckc_ncp_subtotal_0 CHECK (ncp_subtotal_0 >= 0),
   ncp_subtotal_gravado    NUMERIC(12,2)  DEFAULT 0 NOT NULL
      CONSTRAINT ckc_ncp_subtotal_gravado CHECK (ncp_subtotal_gravado >= 0),
   ncp_iva                 NUMERIC(12,2)  DEFAULT 0 NOT NULL
      CONSTRAINT ckc_ncp_iva CHECK (ncp_iva >= 0),
   ncp_motivo              VARCHAR(200)   NOT NULL,
   id_usuario_registra     INTEGER        NOT NULL,
   CONSTRAINT pk_nota_credito_proveedor PRIMARY KEY (id_nota_credito_proveedor),
   CONSTRAINT ak_ncp_comprobante_numero UNIQUE (id_comprobante_compra, ncp_numero),
   CONSTRAINT ckt_nota_credito_proveedor CHECK (ncp_subtotal_0 + ncp_subtotal_gravado > 0)
);
COMMENT ON TABLE produccion.nota_credito_proveedor IS 'Nota de crédito recibida del proveedor (p. ej. por una devolución): baja la deuda del comprobante (factura o nota de venta; un recibo no la admite).';



/*==============================================================*/
/* 8. VENTAS                                                    */
/*    Pedidos de todos los canales, líneas, estados, pagos y    */
/*    envíos.                                                   */
/*                                                              */
/*    Toda venta (web, tienda, WhatsApp) empieza como pedido.   */
/*    Estados: PEN -> PAG -> FAC -> (DES ->) ENT ; PEN/PAG -> CAN */
/*==============================================================*/

CREATE TABLE produccion.canal_venta (
   id_canal_venta          VARCHAR(3)     NOT NULL,
   cav_nombre              VARCHAR(40)    NOT NULL,
   CONSTRAINT pk_canal_venta PRIMARY KEY (id_canal_venta),
   CONSTRAINT ak_canal_venta_nombre UNIQUE (cav_nombre)
);
COMMENT ON TABLE produccion.canal_venta IS 'Dónde se realizó la venta: WEB (e-commerce), TDA (tienda física), WSP (WhatsApp/teléfono).';

CREATE TABLE produccion.estado_pedido (
   id_estado_pedido        VARCHAR(3)     NOT NULL,
   esp_nombre              VARCHAR(30)    NOT NULL,
   esp_orden               SMALLINT       NOT NULL,
   CONSTRAINT pk_estado_pedido PRIMARY KEY (id_estado_pedido),
   CONSTRAINT ak_estado_pedido_nombre UNIQUE (esp_nombre),
   CONSTRAINT ak_estado_pedido_orden UNIQUE (esp_orden)
);
COMMENT ON TABLE produccion.estado_pedido IS 'Estados del ciclo del pedido: PEN, PAG, FAC, DES, ENT, CAN.';

CREATE TABLE produccion.metodo_pago (
   id_metodo_pago          SERIAL         NOT NULL,
   mpa_nombre              VARCHAR(40)    NOT NULL,
   mpa_codigo_sri          CHAR(2)        NOT NULL,
   CONSTRAINT pk_metodo_pago PRIMARY KEY (id_metodo_pago),
   CONSTRAINT ak_metodo_pago_nombre UNIQUE (mpa_nombre)
);
COMMENT ON TABLE produccion.metodo_pago IS 'Formas de pago con su código SRI.';

CREATE TABLE produccion.transportista (
   id_transportista        SERIAL         NOT NULL,
   tra_nombre              VARCHAR(60)    NOT NULL,
   tra_telefono            VARCHAR(15)    NULL,
   tra_url_rastreo         VARCHAR(200)   NULL,
   CONSTRAINT pk_transportista PRIMARY KEY (id_transportista),
   CONSTRAINT ak_transportista_nombre UNIQUE (tra_nombre)
);
COMMENT ON TABLE produccion.transportista IS 'Empresas de transporte para envíos.';

CREATE TABLE produccion.pedido (
   id_pedido               SERIAL         NOT NULL,
   id_cliente              INTEGER        NOT NULL,
   id_canal_venta          VARCHAR(3)     NOT NULL,
   id_empleado_vendedor    INTEGER        NULL,
   ped_fechahora           TIMESTAMP      DEFAULT CURRENT_TIMESTAMP NOT NULL,
   ped_observacion         VARCHAR(250)   NULL,
   CONSTRAINT pk_pedido PRIMARY KEY (id_pedido),
   CONSTRAINT ckt_pedido CHECK ((id_canal_venta = 'WEB' AND id_empleado_vendedor IS NULL)
                             OR (id_canal_venta <> 'WEB' AND id_empleado_vendedor IS NOT NULL))
);
COMMENT ON TABLE produccion.pedido IS 'Toda venta. La web no tiene vendedor; tienda y WhatsApp siempre. Totales y estado actual se calculan.';

CREATE TABLE produccion.detalle_pedido (
   id_detalle_pedido       SERIAL         NOT NULL,
   id_pedido               INTEGER        NOT NULL,
   id_presentacion         INTEGER        NOT NULL,
   dpe_cantidad            NUMERIC(12,3)  NOT NULL
      CONSTRAINT ckc_dpe_cantidad CHECK (dpe_cantidad > 0),
   dpe_precio_unitario     NUMERIC(12,2)  NOT NULL
      CONSTRAINT ckc_dpe_precio_unitario CHECK (dpe_precio_unitario >= 0),
   dpe_descuento           NUMERIC(12,2)  DEFAULT 0 NOT NULL,
   id_tarifa_iva           VARCHAR(2)     NOT NULL,
   id_usuario_descuento    INTEGER        NULL,
   id_oferta               INTEGER        NULL,
   CONSTRAINT pk_detalle_pedido PRIMARY KEY (id_detalle_pedido),
   CONSTRAINT ak_detalle_pedido_presentacion UNIQUE (id_pedido, id_presentacion),
   CONSTRAINT ckt_detalle_pedido CHECK (dpe_descuento >= 0 AND dpe_descuento <= dpe_cantidad * dpe_precio_unitario
                                        AND ((dpe_descuento = 0 AND id_usuario_descuento IS NULL)
                                          OR (dpe_descuento > 0 AND id_usuario_descuento IS NOT NULL)))
);
COMMENT ON TABLE produccion.detalle_pedido IS 'Líneas del pedido con precio, oferta, descuento negociado y tarifa de IVA vigentes al vender.';
COMMENT ON COLUMN produccion.detalle_pedido.dpe_cantidad IS 'En unidades de la presentación (no en unidad base).';
COMMENT ON COLUMN produccion.detalle_pedido.dpe_descuento IS 'Rebaja NEGOCIADA en tienda o WhatsApp (desde el valor final pactado). La rebaja por oferta no se guarda: sale del porcentaje de la oferta aplicada.';
COMMENT ON COLUMN produccion.detalle_pedido.id_oferta IS 'Oferta vigente al crear el pedido; la asigna la base sola (en la web es el único descuento posible).';
COMMENT ON COLUMN produccion.detalle_pedido.id_usuario_descuento IS 'Quién negoció y autorizó el descuento de esta línea.';

CREATE TABLE produccion.historial_estado_pedido (
   id_historial_estado     SERIAL         NOT NULL,
   id_pedido               INTEGER        NOT NULL,
   id_estado_pedido        VARCHAR(3)     NOT NULL,
   hep_fechahora           TIMESTAMP      DEFAULT CURRENT_TIMESTAMP NOT NULL,
   id_usuario              INTEGER        NULL,
   hep_observacion         VARCHAR(200)   NULL,
   CONSTRAINT pk_historial_estado_pedido PRIMARY KEY (id_historial_estado)
);
COMMENT ON TABLE produccion.historial_estado_pedido IS 'Bitácora de estados: quién cambió el pedido y cuándo (usuario nulo = cliente invitado).';

CREATE TABLE produccion.pago (
   id_pago                 SERIAL         NOT NULL,
   id_pedido               INTEGER        NOT NULL,
   id_metodo_pago          INTEGER        NOT NULL,
   pag_monto               NUMERIC(12,2)  NOT NULL
      CONSTRAINT ckc_pag_monto CHECK (pag_monto > 0),
   pag_fechahora           TIMESTAMP      DEFAULT CURRENT_TIMESTAMP NOT NULL,
   pag_referencia          VARCHAR(60)    NULL,
   pag_estado              VARCHAR(9)     DEFAULT 'PENDIENTE' NOT NULL
      CONSTRAINT ckc_pag_estado CHECK (pag_estado IN ('PENDIENTE', 'APROBADO', 'RECHAZADO')),
   id_usuario_registra     INTEGER        NOT NULL,
   CONSTRAINT pk_pago PRIMARY KEY (id_pago)
);
COMMENT ON TABLE produccion.pago IS 'Pagos del pedido; puede haber varios (parciales, rechazados, reintentos).';

CREATE TABLE produccion.envio (
   id_envio                SERIAL         NOT NULL,
   id_pedido               INTEGER        NOT NULL,
   id_direccion            INTEGER        NOT NULL,
   id_transportista        INTEGER        NULL,
   env_guia                VARCHAR(40)    NULL,
   env_costo               NUMERIC(12,2)  DEFAULT 0 NOT NULL
      CONSTRAINT ckc_env_costo CHECK (env_costo >= 0),
   id_tarifa_iva           VARCHAR(2)     NOT NULL,
   CONSTRAINT pk_envio PRIMARY KEY (id_envio),
   CONSTRAINT ak_envio_pedido UNIQUE (id_pedido),
   CONSTRAINT ckt_envio CHECK (env_guia IS NULL OR id_transportista IS NOT NULL)
);
COMMENT ON TABLE produccion.envio IS 'Envío a domicilio (sin envío = retiro en tienda). Fechas de despacho y entrega en historial_estado_pedido.';



/*==============================================================*/
/* 9. FACTURACIÓN                                               */
/*    Tipos de comprobante, comprobantes de venta, notas de     */
/*    crédito por devolución y reembolsos.                      */
/*                                                              */
/*    El comprobante (factura o nota de venta) es el documento  */
/*    tributario del pedido: no repite sus líneas, las congela. */
/*==============================================================*/

CREATE TABLE produccion.motivo_devolucion (
   id_motivo_devolucion    SERIAL         NOT NULL,
   mde_nombre              VARCHAR(60)    NOT NULL,
   CONSTRAINT pk_motivo_devolucion PRIMARY KEY (id_motivo_devolucion),
   CONSTRAINT ak_motivo_devolucion_nombre UNIQUE (mde_nombre)
);
COMMENT ON TABLE produccion.motivo_devolucion IS 'Motivos aceptados por la política de devoluciones.';

CREATE TABLE produccion.tipo_comprobante (
   id_tipo_comprobante     CHAR(2)        NOT NULL,
   tco_nombre              VARCHAR(50)    NOT NULL,
   tco_en_venta            BOOLEAN        DEFAULT FALSE NOT NULL,
   tco_en_compra           BOOLEAN        DEFAULT FALSE NOT NULL,
   tco_desglosa_iva        BOOLEAN        DEFAULT FALSE NOT NULL,
   tco_electronico_sri     BOOLEAN        DEFAULT FALSE NOT NULL,
   CONSTRAINT pk_tipo_comprobante PRIMARY KEY (id_tipo_comprobante),
   CONSTRAINT ak_tipo_comprobante_nombre UNIQUE (tco_nombre)
);
COMMENT ON TABLE produccion.tipo_comprobante IS 'Tipos de comprobante con su código SRI: 01 factura, 02 nota de venta, 00 sin comprobante (recibo, solo compras). Solo el electrónico pasa por el flujo del SRI.';
COMMENT ON COLUMN produccion.tipo_comprobante.tco_electronico_sri IS 'Verdadero si al emitirlo en una venta se genera clave de acceso y se transmite al SRI (factura).';
COMMENT ON COLUMN produccion.tipo_comprobante.tco_desglosa_iva IS 'Verdadero si el documento separa el IVA (factura); la nota de venta y el recibo no.';

CREATE TABLE produccion.comprobante_venta (
   id_comprobante_venta    SERIAL         NOT NULL,
   id_tipo_comprobante     CHAR(2)        DEFAULT '01' NOT NULL,
   id_pedido               INTEGER        NOT NULL,
   id_datos_facturacion    INTEGER        NULL,
   id_punto_emision        INTEGER        NOT NULL,
   cve_secuencial          INTEGER        NOT NULL
      CONSTRAINT ckc_cve_secuencial CHECK (cve_secuencial BETWEEN 1 AND 999999999),
   cve_fechahora           TIMESTAMP      DEFAULT CURRENT_TIMESTAMP NOT NULL,
   id_usuario_emite        INTEGER        NOT NULL,
   cve_clave_acceso        CHAR(49)       NULL,
   cve_fecha_autorizacion  TIMESTAMP      NULL,
   cve_estado              VARCHAR(10)    DEFAULT 'PENDIENTE' NOT NULL
      CONSTRAINT ckc_cve_estado CHECK (cve_estado IN ('PENDIENTE', 'AUTORIZADA', 'RECHAZADA', 'EMITIDA', 'ANULADA')),
   CONSTRAINT pk_comprobante_venta PRIMARY KEY (id_comprobante_venta),
   CONSTRAINT ak_comprobante_venta_serie UNIQUE (id_tipo_comprobante, id_punto_emision, cve_secuencial),
   CONSTRAINT ak_comprobante_venta_clave UNIQUE (cve_clave_acceso),
   CONSTRAINT ckt_comprobante_venta CHECK (
        (id_tipo_comprobante = '01' AND id_datos_facturacion IS NOT NULL AND cve_estado <> 'EMITIDA')
     OR (id_tipo_comprobante <> '01' AND cve_clave_acceso IS NULL AND cve_fecha_autorizacion IS NULL
         AND cve_estado IN ('EMITIDA', 'ANULADA')))
);
COMMENT ON TABLE produccion.comprobante_venta IS 'Comprobante de venta del pedido: factura (electrónica, va al SRI) o nota de venta (se registra con el número del talonario). Congela las líneas del pedido; los totales se calculan.';
COMMENT ON COLUMN produccion.comprobante_venta.cve_clave_acceso IS 'Solo factura: clave de acceso SRI de 49 dígitos (también es el número de autorización).';
COMMENT ON COLUMN produccion.comprobante_venta.cve_estado IS 'Factura: PENDIENTE, AUTORIZADA, RECHAZADA o ANULADA (flujo del SRI). Nota de venta: EMITIDA o ANULADA.';
COMMENT ON COLUMN produccion.comprobante_venta.id_datos_facturacion IS 'Comprador. Obligatorio en factura; opcional en nota de venta.';

CREATE TABLE produccion.nota_credito (
   id_nota_credito         SERIAL         NOT NULL,
   id_comprobante_venta    INTEGER        NOT NULL,
   id_punto_emision        INTEGER        NOT NULL,
   ncr_secuencial          INTEGER        NOT NULL
      CONSTRAINT ckc_ncr_secuencial CHECK (ncr_secuencial BETWEEN 1 AND 999999999),
   ncr_fechahora           TIMESTAMP      DEFAULT CURRENT_TIMESTAMP NOT NULL,
   id_motivo_devolucion    INTEGER        NOT NULL,
   id_usuario_autoriza     INTEGER        NOT NULL,
   ncr_observacion         VARCHAR(250)   NULL,
   ncr_clave_acceso        CHAR(49)       NULL,
   ncr_fecha_autorizacion  TIMESTAMP      NULL,
   ncr_estado              VARCHAR(10)    DEFAULT 'PENDIENTE' NOT NULL
      CONSTRAINT ckc_ncr_estado CHECK (ncr_estado IN ('PENDIENTE', 'AUTORIZADA', 'RECHAZADA', 'EMITIDA', 'ANULADA')),
   CONSTRAINT pk_nota_credito PRIMARY KEY (id_nota_credito),
   CONSTRAINT ak_nota_credito_serie_secuencial UNIQUE (id_punto_emision, ncr_secuencial),
   CONSTRAINT ak_nota_credito_clave_acceso UNIQUE (ncr_clave_acceso),
   CONSTRAINT ckt_nota_credito CHECK (ncr_estado <> 'EMITIDA' OR (ncr_clave_acceso IS NULL AND ncr_fecha_autorizacion IS NULL))
);
COMMENT ON TABLE produccion.nota_credito IS 'Nota de crédito por devolución sobre un comprobante de venta, dentro del plazo de la política. Si modifica una factura es electrónica (va al SRI); si modifica una nota de venta se registra (estado EMITIDA).';

CREATE TABLE produccion.detalle_nota_credito (
   id_detalle_nota_credito SERIAL         NOT NULL,
   id_nota_credito         INTEGER        NOT NULL,
   id_detalle_pedido       INTEGER        NOT NULL,
   dnc_cantidad            NUMERIC(12,3)  NOT NULL
      CONSTRAINT ckc_dnc_cantidad CHECK (dnc_cantidad > 0),
   dnc_reingresa_stock     BOOLEAN        DEFAULT TRUE NOT NULL,
   CONSTRAINT pk_detalle_nota_credito PRIMARY KEY (id_detalle_nota_credito),
   CONSTRAINT ak_detalle_nc_linea UNIQUE (id_nota_credito, id_detalle_pedido)
);
COMMENT ON TABLE produccion.detalle_nota_credito IS 'Cantidad devuelta por línea facturada y si reingresa al stock (falso = producto dañado).';

CREATE TABLE produccion.reembolso (
   id_reembolso            SERIAL         NOT NULL,
   id_nota_credito         INTEGER        NOT NULL,
   id_metodo_pago          INTEGER        NOT NULL,
   ree_monto               NUMERIC(12,2)  NOT NULL
      CONSTRAINT ckc_ree_monto CHECK (ree_monto > 0),
   ree_fechahora           TIMESTAMP      DEFAULT CURRENT_TIMESTAMP NOT NULL,
   ree_referencia          VARCHAR(60)    NULL,
   id_usuario_registra     INTEGER        NOT NULL,
   CONSTRAINT pk_reembolso PRIMARY KEY (id_reembolso)
);
COMMENT ON TABLE produccion.reembolso IS 'Devolución de dinero asociada a una nota de crédito.';



/*==============================================================*/
/* 10. CUENTAS POR COBRAR                                       */
/*    Crédito de ventas, avances de dinero y abonos.            */
/*                                                              */
/*    CREDITO: saldo de una venta que no se pagó al facturar.   */
/*    AVANCE: dinero entregado al cliente (pasaje, material).   */
/*    No es una venta: no va en la factura. El cliente sale     */
/*    del pedido y el saldo de los abonos (ambos se calculan).  */
/*==============================================================*/

CREATE TABLE produccion.motivo_avance (
   id_motivo_avance        SERIAL         NOT NULL,
   mav_nombre              VARCHAR(60)    NOT NULL,
   CONSTRAINT pk_motivo_avance PRIMARY KEY (id_motivo_avance),
   CONSTRAINT ak_motivo_avance_nombre UNIQUE (mav_nombre)
);
COMMENT ON TABLE produccion.motivo_avance IS 'Para qué pide el cliente el dinero extra: pasaje, compra en otro establecimiento, otro.';

CREATE TABLE produccion.cuenta_por_cobrar (
   id_cuenta_por_cobrar    SERIAL         NOT NULL,
   id_pedido               INTEGER        NOT NULL,
   cxc_tipo                VARCHAR(7)     NOT NULL
      CONSTRAINT ckc_cxc_tipo CHECK (cxc_tipo IN ('CREDITO', 'AVANCE')),
   cxc_monto               NUMERIC(12,2)  NOT NULL
      CONSTRAINT ckc_cxc_monto CHECK (cxc_monto > 0),
   cxc_concepto            VARCHAR(150)   NOT NULL,
   cxc_fechahora           TIMESTAMP      DEFAULT CURRENT_TIMESTAMP NOT NULL,
   cxc_fecha_vencimiento   DATE           NOT NULL,
   id_metodo_entrega       INTEGER        NULL,
   id_motivo_avance        INTEGER        NULL,
   id_usuario_autoriza     INTEGER        NOT NULL,
   CONSTRAINT pk_cuenta_por_cobrar PRIMARY KEY (id_cuenta_por_cobrar),
   CONSTRAINT ckt_cuenta_por_cobrar CHECK (
        (cxc_tipo = 'CREDITO' AND id_metodo_entrega IS NULL     AND id_motivo_avance IS NULL)
     OR (cxc_tipo = 'AVANCE'  AND id_metodo_entrega IS NOT NULL AND id_motivo_avance IS NOT NULL))
);
COMMENT ON TABLE produccion.cuenta_por_cobrar IS 'Deuda del cliente por una compra: CREDITO (saldo no pagado al facturar) o AVANCE (dinero entregado). El saldo se calcula con los abonos.';
COMMENT ON COLUMN produccion.cuenta_por_cobrar.id_metodo_entrega IS 'Solo en avances: cómo se entregó el dinero (efectivo, transferencia).';
COMMENT ON COLUMN produccion.cuenta_por_cobrar.id_motivo_avance IS 'Solo en avances: para qué se pidió el dinero. No es un producto: no toca el inventario.';

CREATE TABLE produccion.abono_cliente (
   id_abono_cliente        SERIAL         NOT NULL,
   id_cuenta_por_cobrar    INTEGER        NOT NULL,
   id_metodo_pago          INTEGER        NULL,
   id_nota_credito         INTEGER        NULL,
   abo_monto               NUMERIC(12,2)  NOT NULL
      CONSTRAINT ckc_abo_monto CHECK (abo_monto > 0),
   abo_fechahora           TIMESTAMP      DEFAULT CURRENT_TIMESTAMP NOT NULL,
   abo_referencia          VARCHAR(60)    NULL,
   id_usuario_registra     INTEGER        NOT NULL,
   CONSTRAINT pk_abono_cliente PRIMARY KEY (id_abono_cliente),
   CONSTRAINT ckt_abono_cliente CHECK (
        (id_metodo_pago IS NOT NULL AND id_nota_credito IS NULL)
     OR (id_metodo_pago IS NULL AND id_nota_credito IS NOT NULL))
);
COMMENT ON TABLE produccion.abono_cliente IS 'Pagos a una cuenta por cobrar: con dinero (método de pago) o compensando una nota de crédito.';



/*==============================================================*/
/* 11. INVENTARIO                                               */
/*    Kárdex por lotes: tipos de movimiento, lotes,             */
/*    movimientos y sus líneas.                                 */
/*                                                              */
/*    Cada ingreso crea un lote con su costo real; las salidas  */
/*    consumen lotes por FEFO/PEPS; la devolución de cliente    */
/*    vuelve al lote de origen. Stock, saldo y antigüedad se    */
/*    calculan. El kárdex no se edita ni se borra.              */
/*==============================================================*/

CREATE TABLE produccion.tipo_movimiento (
   id_tipo_movimiento      CHAR(3)        NOT NULL,
   tmv_nombre              VARCHAR(40)    NOT NULL,
   tmv_signo               SMALLINT       NOT NULL
      CONSTRAINT ckc_tmv_signo CHECK (tmv_signo IN (1, -1)),
   CONSTRAINT pk_tipo_movimiento PRIMARY KEY (id_tipo_movimiento),
   CONSTRAINT ak_tipo_movimiento_nombre UNIQUE (tmv_nombre)
);
COMMENT ON TABLE produccion.tipo_movimiento IS 'Tipos de movimiento de kárdex y su signo (+1 entrada, -1 salida).';

CREATE TABLE produccion.lote (
   id_lote                 SERIAL         NOT NULL,
   id_variante             INTEGER        NOT NULL,
   lot_costo_unitario      NUMERIC(12,4)  NOT NULL
      CONSTRAINT ckc_lot_costo_unitario CHECK (lot_costo_unitario >= 0),
   lot_fecha_vencimiento   DATE           NULL,
   lot_codigo_proveedor    VARCHAR(30)    NULL,
   id_lote_origen          INTEGER        NULL,
   CONSTRAINT pk_lote PRIMARY KEY (id_lote),
   CONSTRAINT ckt_lote CHECK (id_lote_origen IS NULL OR id_lote_origen <> id_lote)
);
COMMENT ON TABLE produccion.lote IS 'Ingreso de una variante con su costo real (por unidad base) y vencimiento. En productos por pieza, cada lote es una pieza.';
COMMENT ON COLUMN produccion.lote.id_lote_origen IS 'Pieza de la que se cortó este paquete (fraccionamiento); conserva su antigüedad.';

CREATE TABLE produccion.movimiento_inventario (
   id_movimiento           SERIAL         NOT NULL,
   id_tipo_movimiento      CHAR(3)        NOT NULL,
   mov_fechahora           TIMESTAMP      DEFAULT CURRENT_TIMESTAMP NOT NULL,
   id_usuario              INTEGER        NOT NULL,
   mov_motivo              VARCHAR(200)   NULL,
   id_orden_compra         INTEGER        NULL,
   id_comprobante_compra   INTEGER        NULL,
   id_comprobante_venta    INTEGER        NULL,
   id_nota_credito         INTEGER        NULL,
   CONSTRAINT pk_movimiento_inventario PRIMARY KEY (id_movimiento),
   CONSTRAINT ckt_movimiento_inventario CHECK (
          ((id_tipo_movimiento IN ('COM', 'DPR') AND id_orden_compra IS NOT NULL)
        OR (id_tipo_movimiento NOT IN ('COM', 'DPR') AND id_orden_compra IS NULL))
      AND (id_comprobante_compra IS NULL OR id_tipo_movimiento = 'COM')
      AND ((id_tipo_movimiento = 'VEN' AND id_comprobante_venta IS NOT NULL)
        OR (id_tipo_movimiento <> 'VEN' AND id_comprobante_venta IS NULL))
      AND ((id_tipo_movimiento = 'DCL' AND id_nota_credito IS NOT NULL)
        OR (id_tipo_movimiento <> 'DCL' AND id_nota_credito IS NULL))
      AND (id_tipo_movimiento NOT IN ('AJP', 'AJN', 'MER', 'DPR') OR mov_motivo IS NOT NULL))
);
COMMENT ON TABLE produccion.movimiento_inventario IS 'Cabecera del kárdex. COM/DPR -> orden de compra, VEN -> factura, DCL -> nota de crédito; INI, AJP, AJN, MER con motivo; FRS/FRE fraccionamiento de una pieza en paquetes.';

CREATE TABLE produccion.detalle_movimiento (
   id_detalle_movimiento   SERIAL         NOT NULL,
   id_movimiento           INTEGER        NOT NULL,
   id_lote                 INTEGER        NOT NULL,
   dmo_cantidad            NUMERIC(12,3)  NOT NULL
      CONSTRAINT ckc_dmo_cantidad CHECK (dmo_cantidad > 0),
   id_detalle_orden_compra INTEGER        NULL,
   id_detalle_pedido       INTEGER        NULL,
   id_detalle_nota_credito INTEGER        NULL,
   CONSTRAINT pk_detalle_movimiento PRIMARY KEY (id_detalle_movimiento),
   CONSTRAINT ckt_detalle_movimiento CHECK (
        (CASE WHEN id_detalle_orden_compra IS NULL THEN 0 ELSE 1 END)
      + (CASE WHEN id_detalle_pedido       IS NULL THEN 0 ELSE 1 END)
      + (CASE WHEN id_detalle_nota_credito IS NULL THEN 0 ELSE 1 END) <= 1)
);
COMMENT ON TABLE produccion.detalle_movimiento IS 'Línea del kárdex por lote, en unidad base; el signo lo da el tipo de la cabecera.';


/*##############################################################*/
/* NODO E-COMMERCE                                              */
/* Tienda en línea de cara a internet: cuentas de clientes,     */
/* carritos y bitácora web. Lee el catálogo de producción y le  */
/* pide crear clientes y pedidos.                               */
/*##############################################################*/


/*==============================================================*/
/* 12. CUENTAS WEB                                              */
/*    Acceso de los clientes a la tienda en línea y su          */
/*    bitácora.                                                 */
/*==============================================================*/

CREATE TABLE ecommerce.cuenta_web (
   id_cuenta_web           SERIAL         NOT NULL,
   id_cliente              INTEGER        NOT NULL,
   cwe_correo              VARCHAR(120)   NOT NULL
      CONSTRAINT ckc_cwe_correo CHECK (cwe_correo = LOWER(cwe_correo)),
   cwe_hash_clave          VARCHAR(255)   NOT NULL,
   cwe_activa              BOOLEAN        DEFAULT TRUE NOT NULL,
   cwe_creada              TIMESTAMP      DEFAULT CURRENT_TIMESTAMP NOT NULL,
   cwe_ultimo_acceso       TIMESTAMP      NULL,
   CONSTRAINT pk_cuenta_web PRIMARY KEY (id_cuenta_web),
   CONSTRAINT ak_cuenta_web_cliente UNIQUE (id_cliente),
   CONSTRAINT ak_cuenta_web_correo UNIQUE (cwe_correo)
);
COMMENT ON TABLE ecommerce.cuenta_web IS 'Cuenta de un cliente en la tienda en línea. Vive en el nodo e-commerce: las claves del personal nunca salen a internet.';
COMMENT ON COLUMN ecommerce.cuenta_web.id_cliente IS 'Cliente en producción. Referencia entre nodos.';
COMMENT ON COLUMN ecommerce.cuenta_web.cwe_hash_clave IS 'Hash de la contraseña (bcrypt/argon2), nunca la clave en texto plano.';

CREATE TABLE ecommerce.log_evento_web (
   id_log_evento_web       BIGSERIAL      NOT NULL,
   lew_fechahora           TIMESTAMP      DEFAULT CURRENT_TIMESTAMP NOT NULL,
   lew_nivel               VARCHAR(5)     NOT NULL
      CONSTRAINT ckc_lew_nivel CHECK (lew_nivel IN ('INFO', 'AVISO', 'ERROR')),
   lew_evento              VARCHAR(40)    NOT NULL,
   lew_mensaje             VARCHAR(500)   NOT NULL,
   id_cuenta_web           INTEGER        NULL,
   lew_sesion              VARCHAR(64)    NULL,
   lew_ip                  VARCHAR(45)    NULL,
   lew_agente              VARCHAR(250)   NULL,
   lew_detalle             TEXT           NULL,
   CONSTRAINT pk_log_evento_web PRIMARY KEY (id_log_evento_web)
);
COMMENT ON TABLE ecommerce.log_evento_web IS 'Bitácora del e-commerce: registros, accesos, confirmaciones de carrito, respuestas de la pasarela, errores. Solo se inserta.';
COMMENT ON COLUMN ecommerce.log_evento_web.lew_sesion IS 'Sesión o token del visitante (también sin cuenta).';
COMMENT ON COLUMN ecommerce.log_evento_web.lew_agente IS 'Navegador o aplicación (User-Agent).';



/*==============================================================*/
/* 13. CARRITO                                                  */
/*    Carritos del e-commerce (sin precios ni descuentos).      */
/*==============================================================*/

CREATE TABLE ecommerce.carrito (
   id_carrito              SERIAL         NOT NULL,
   id_cliente              INTEGER        NULL,
   car_token               VARCHAR(36)    NOT NULL,
   car_creado              TIMESTAMP      DEFAULT CURRENT_TIMESTAMP NOT NULL,
   car_actualizado         TIMESTAMP      DEFAULT CURRENT_TIMESTAMP NOT NULL,
   id_pedido               INTEGER        NULL,
   CONSTRAINT pk_carrito PRIMARY KEY (id_carrito),
   CONSTRAINT ak_carrito_token UNIQUE (car_token),
   CONSTRAINT ak_carrito_pedido UNIQUE (id_pedido)
);
COMMENT ON TABLE ecommerce.carrito IS 'Carrito del e-commerce. Un visitante aún no identificado se reconoce por el token. No guarda precios ni descuentos.';
COMMENT ON COLUMN ecommerce.carrito.id_pedido IS 'Pedido en que se convirtió (en producción). Referencia entre nodos.';

CREATE TABLE ecommerce.item_carrito (
   id_carrito              INTEGER        NOT NULL,
   id_presentacion         INTEGER        NOT NULL,
   ica_cantidad            NUMERIC(12,3)  NOT NULL
      CONSTRAINT ckc_ica_cantidad CHECK (ica_cantidad > 0),
   CONSTRAINT pk_item_carrito PRIMARY KEY (id_carrito, id_presentacion)
);
COMMENT ON TABLE ecommerce.item_carrito IS 'Presentaciones y cantidades dentro del carrito.';


/*==============================================================*/
/* 14. REFERENCIAS (claves foráneas)                            */
/*==============================================================*/

-- Ubicación
ALTER TABLE produccion.ciudad ADD CONSTRAINT fk_ciudad_provincia
   FOREIGN KEY (id_provincia) REFERENCES produccion.provincia (id_provincia);

-- Seguridad
ALTER TABLE produccion.usuario_rol ADD CONSTRAINT fk_usuario_rol_usuario
   FOREIGN KEY (id_usuario) REFERENCES produccion.usuario (id_usuario);
ALTER TABLE produccion.usuario_rol ADD CONSTRAINT fk_usuario_rol_rol
   FOREIGN KEY (id_rol) REFERENCES produccion.rol (id_rol);
ALTER TABLE produccion.rol_permiso ADD CONSTRAINT fk_rol_permiso_rol
   FOREIGN KEY (id_rol) REFERENCES produccion.rol (id_rol);
ALTER TABLE produccion.rol_permiso ADD CONSTRAINT fk_rol_permiso_permiso
   FOREIGN KEY (id_permiso) REFERENCES produccion.permiso (id_permiso);
ALTER TABLE produccion.empleado ADD CONSTRAINT fk_empleado_usuario
   FOREIGN KEY (id_usuario) REFERENCES produccion.usuario (id_usuario);
ALTER TABLE produccion.empleado ADD CONSTRAINT fk_empleado_tipo_identificacion
   FOREIGN KEY (id_tipo_identificacion) REFERENCES produccion.tipo_identificacion (id_tipo_identificacion);

-- Auditoría
ALTER TABLE produccion.log_evento ADD CONSTRAINT fk_log_evento_usuario
   FOREIGN KEY (id_usuario) REFERENCES produccion.usuario (id_usuario);
ALTER TABLE produccion.auditoria ADD CONSTRAINT fk_auditoria_usuario
   FOREIGN KEY (id_usuario) REFERENCES produccion.usuario (id_usuario);

-- Clientes
ALTER TABLE produccion.telefono ADD CONSTRAINT fk_telefono_cliente
   FOREIGN KEY (id_cliente) REFERENCES produccion.cliente (id_cliente);
ALTER TABLE produccion.direccion ADD CONSTRAINT fk_direccion_cliente
   FOREIGN KEY (id_cliente) REFERENCES produccion.cliente (id_cliente);
ALTER TABLE produccion.direccion ADD CONSTRAINT fk_direccion_ciudad
   FOREIGN KEY (id_ciudad) REFERENCES produccion.ciudad (id_ciudad);
ALTER TABLE produccion.datos_facturacion ADD CONSTRAINT fk_datos_facturacion_cliente
   FOREIGN KEY (id_cliente) REFERENCES produccion.cliente (id_cliente);
ALTER TABLE produccion.datos_facturacion ADD CONSTRAINT fk_datos_facturacion_tipo_ident
   FOREIGN KEY (id_tipo_identificacion) REFERENCES produccion.tipo_identificacion (id_tipo_identificacion);
ALTER TABLE produccion.datos_facturacion ADD CONSTRAINT fk_datos_facturacion_direccion
   FOREIGN KEY (id_direccion) REFERENCES produccion.direccion (id_direccion);

-- Empresa
ALTER TABLE produccion.empresa ADD CONSTRAINT fk_empresa_direccion_matriz
   FOREIGN KEY (id_direccion_matriz) REFERENCES produccion.direccion (id_direccion);

-- Productos
ALTER TABLE produccion.categoria ADD CONSTRAINT fk_categoria_padre
   FOREIGN KEY (id_categoria_padre) REFERENCES produccion.categoria (id_categoria);
ALTER TABLE produccion.categoria_atributo ADD CONSTRAINT fk_categoria_atributo_categoria
   FOREIGN KEY (id_categoria) REFERENCES produccion.categoria (id_categoria);
ALTER TABLE produccion.categoria_atributo ADD CONSTRAINT fk_categoria_atributo_atributo
   FOREIGN KEY (id_atributo) REFERENCES produccion.atributo (id_atributo);
ALTER TABLE produccion.valor_atributo ADD CONSTRAINT fk_valor_atributo_atributo
   FOREIGN KEY (id_atributo) REFERENCES produccion.atributo (id_atributo);
ALTER TABLE produccion.producto ADD CONSTRAINT fk_producto_categoria
   FOREIGN KEY (id_categoria) REFERENCES produccion.categoria (id_categoria);
ALTER TABLE produccion.producto ADD CONSTRAINT fk_producto_unidad_medida
   FOREIGN KEY (id_unidad_medida) REFERENCES produccion.unidad_medida (id_unidad_medida);
ALTER TABLE produccion.producto ADD CONSTRAINT fk_producto_tarifa_iva
   FOREIGN KEY (id_tarifa_iva) REFERENCES produccion.tarifa_iva (id_tarifa_iva);
ALTER TABLE produccion.variante ADD CONSTRAINT fk_variante_producto
   FOREIGN KEY (id_producto) REFERENCES produccion.producto (id_producto);
ALTER TABLE produccion.variante_valor ADD CONSTRAINT fk_variante_valor_variante
   FOREIGN KEY (id_variante) REFERENCES produccion.variante (id_variante);
ALTER TABLE produccion.variante_valor ADD CONSTRAINT fk_variante_valor_valor
   FOREIGN KEY (id_valor_atributo, id_atributo) REFERENCES produccion.valor_atributo (id_valor_atributo, id_atributo);
ALTER TABLE produccion.presentacion ADD CONSTRAINT fk_presentacion_variante
   FOREIGN KEY (id_variante) REFERENCES produccion.variante (id_variante);
ALTER TABLE produccion.historial_precio ADD CONSTRAINT fk_historial_precio_presentacion
   FOREIGN KEY (id_presentacion) REFERENCES produccion.presentacion (id_presentacion);
ALTER TABLE produccion.historial_precio ADD CONSTRAINT fk_historial_precio_usuario
   FOREIGN KEY (id_usuario) REFERENCES produccion.usuario (id_usuario);
ALTER TABLE produccion.oferta ADD CONSTRAINT fk_oferta_producto
   FOREIGN KEY (id_producto) REFERENCES produccion.producto (id_producto);
ALTER TABLE produccion.oferta ADD CONSTRAINT fk_oferta_usuario
   FOREIGN KEY (id_usuario_registra) REFERENCES produccion.usuario (id_usuario);

-- Compras
ALTER TABLE produccion.proveedor ADD CONSTRAINT fk_proveedor_tipo_identificacion
   FOREIGN KEY (id_tipo_identificacion) REFERENCES produccion.tipo_identificacion (id_tipo_identificacion);
ALTER TABLE produccion.orden_compra ADD CONSTRAINT fk_orden_compra_proveedor
   FOREIGN KEY (id_proveedor) REFERENCES produccion.proveedor (id_proveedor);
ALTER TABLE produccion.orden_compra ADD CONSTRAINT fk_orden_compra_usuario
   FOREIGN KEY (id_usuario_crea) REFERENCES produccion.usuario (id_usuario);
ALTER TABLE produccion.detalle_orden_compra ADD CONSTRAINT fk_detalle_oc_orden_compra
   FOREIGN KEY (id_orden_compra) REFERENCES produccion.orden_compra (id_orden_compra);
ALTER TABLE produccion.detalle_orden_compra ADD CONSTRAINT fk_detalle_oc_variante
   FOREIGN KEY (id_variante) REFERENCES produccion.variante (id_variante);
ALTER TABLE produccion.comprobante_compra ADD CONSTRAINT fk_comprobante_compra_tipo
   FOREIGN KEY (id_tipo_comprobante) REFERENCES produccion.tipo_comprobante (id_tipo_comprobante);
ALTER TABLE produccion.comprobante_compra ADD CONSTRAINT fk_comprobante_compra_proveedor
   FOREIGN KEY (id_proveedor) REFERENCES produccion.proveedor (id_proveedor);
ALTER TABLE produccion.comprobante_compra ADD CONSTRAINT fk_comprobante_compra_usuario
   FOREIGN KEY (id_usuario_registra) REFERENCES produccion.usuario (id_usuario);
ALTER TABLE produccion.pago_proveedor ADD CONSTRAINT fk_pago_proveedor_comprobante
   FOREIGN KEY (id_comprobante_compra) REFERENCES produccion.comprobante_compra (id_comprobante_compra);
ALTER TABLE produccion.pago_proveedor ADD CONSTRAINT fk_pago_proveedor_metodo_pago
   FOREIGN KEY (id_metodo_pago) REFERENCES produccion.metodo_pago (id_metodo_pago);
ALTER TABLE produccion.pago_proveedor ADD CONSTRAINT fk_pago_proveedor_usuario
   FOREIGN KEY (id_usuario_registra) REFERENCES produccion.usuario (id_usuario);
ALTER TABLE produccion.nota_credito_proveedor ADD CONSTRAINT fk_ncp_comprobante_compra
   FOREIGN KEY (id_comprobante_compra) REFERENCES produccion.comprobante_compra (id_comprobante_compra);
ALTER TABLE produccion.nota_credito_proveedor ADD CONSTRAINT fk_ncp_usuario
   FOREIGN KEY (id_usuario_registra) REFERENCES produccion.usuario (id_usuario);

-- Ventas
ALTER TABLE produccion.pedido ADD CONSTRAINT fk_pedido_cliente
   FOREIGN KEY (id_cliente) REFERENCES produccion.cliente (id_cliente);
ALTER TABLE produccion.pedido ADD CONSTRAINT fk_pedido_canal_venta
   FOREIGN KEY (id_canal_venta) REFERENCES produccion.canal_venta (id_canal_venta);
ALTER TABLE produccion.pedido ADD CONSTRAINT fk_pedido_empleado_vendedor
   FOREIGN KEY (id_empleado_vendedor) REFERENCES produccion.empleado (id_usuario);
ALTER TABLE produccion.detalle_pedido ADD CONSTRAINT fk_detalle_pedido_pedido
   FOREIGN KEY (id_pedido) REFERENCES produccion.pedido (id_pedido);
ALTER TABLE produccion.detalle_pedido ADD CONSTRAINT fk_detalle_pedido_presentacion
   FOREIGN KEY (id_presentacion) REFERENCES produccion.presentacion (id_presentacion);
ALTER TABLE produccion.detalle_pedido ADD CONSTRAINT fk_detalle_pedido_tarifa_iva
   FOREIGN KEY (id_tarifa_iva) REFERENCES produccion.tarifa_iva (id_tarifa_iva);
ALTER TABLE produccion.detalle_pedido ADD CONSTRAINT fk_detalle_pedido_usuario_descuento
   FOREIGN KEY (id_usuario_descuento) REFERENCES produccion.usuario (id_usuario);
ALTER TABLE produccion.historial_estado_pedido ADD CONSTRAINT fk_historial_estado_pedido
   FOREIGN KEY (id_pedido) REFERENCES produccion.pedido (id_pedido);
ALTER TABLE produccion.historial_estado_pedido ADD CONSTRAINT fk_historial_estado_estado
   FOREIGN KEY (id_estado_pedido) REFERENCES produccion.estado_pedido (id_estado_pedido);
ALTER TABLE produccion.historial_estado_pedido ADD CONSTRAINT fk_historial_estado_usuario
   FOREIGN KEY (id_usuario) REFERENCES produccion.usuario (id_usuario);
ALTER TABLE produccion.pago ADD CONSTRAINT fk_pago_pedido
   FOREIGN KEY (id_pedido) REFERENCES produccion.pedido (id_pedido);
ALTER TABLE produccion.pago ADD CONSTRAINT fk_pago_metodo_pago
   FOREIGN KEY (id_metodo_pago) REFERENCES produccion.metodo_pago (id_metodo_pago);
ALTER TABLE produccion.pago ADD CONSTRAINT fk_pago_usuario
   FOREIGN KEY (id_usuario_registra) REFERENCES produccion.usuario (id_usuario);
ALTER TABLE produccion.envio ADD CONSTRAINT fk_envio_pedido
   FOREIGN KEY (id_pedido) REFERENCES produccion.pedido (id_pedido);
ALTER TABLE produccion.envio ADD CONSTRAINT fk_envio_direccion
   FOREIGN KEY (id_direccion) REFERENCES produccion.direccion (id_direccion);
ALTER TABLE produccion.envio ADD CONSTRAINT fk_envio_transportista
   FOREIGN KEY (id_transportista) REFERENCES produccion.transportista (id_transportista);
ALTER TABLE produccion.envio ADD CONSTRAINT fk_envio_tarifa_iva
   FOREIGN KEY (id_tarifa_iva) REFERENCES produccion.tarifa_iva (id_tarifa_iva);
ALTER TABLE produccion.detalle_pedido ADD CONSTRAINT fk_detalle_pedido_oferta
   FOREIGN KEY (id_oferta) REFERENCES produccion.oferta (id_oferta);

-- Facturación
ALTER TABLE produccion.comprobante_venta ADD CONSTRAINT fk_comprobante_venta_tipo
   FOREIGN KEY (id_tipo_comprobante) REFERENCES produccion.tipo_comprobante (id_tipo_comprobante);
ALTER TABLE produccion.comprobante_venta ADD CONSTRAINT fk_comprobante_venta_pedido
   FOREIGN KEY (id_pedido) REFERENCES produccion.pedido (id_pedido);
ALTER TABLE produccion.comprobante_venta ADD CONSTRAINT fk_comprobante_venta_datos_fact
   FOREIGN KEY (id_datos_facturacion) REFERENCES produccion.datos_facturacion (id_datos_facturacion);
ALTER TABLE produccion.comprobante_venta ADD CONSTRAINT fk_comprobante_venta_punto
   FOREIGN KEY (id_punto_emision) REFERENCES produccion.punto_emision (id_punto_emision);
ALTER TABLE produccion.comprobante_venta ADD CONSTRAINT fk_comprobante_venta_usuario
   FOREIGN KEY (id_usuario_emite) REFERENCES produccion.usuario (id_usuario);
ALTER TABLE produccion.nota_credito ADD CONSTRAINT fk_nota_credito_comprobante
   FOREIGN KEY (id_comprobante_venta) REFERENCES produccion.comprobante_venta (id_comprobante_venta);
ALTER TABLE produccion.nota_credito ADD CONSTRAINT fk_nota_credito_punto_emision
   FOREIGN KEY (id_punto_emision) REFERENCES produccion.punto_emision (id_punto_emision);
ALTER TABLE produccion.nota_credito ADD CONSTRAINT fk_nota_credito_motivo
   FOREIGN KEY (id_motivo_devolucion) REFERENCES produccion.motivo_devolucion (id_motivo_devolucion);
ALTER TABLE produccion.nota_credito ADD CONSTRAINT fk_nota_credito_usuario
   FOREIGN KEY (id_usuario_autoriza) REFERENCES produccion.usuario (id_usuario);
ALTER TABLE produccion.detalle_nota_credito ADD CONSTRAINT fk_detalle_nc_nota_credito
   FOREIGN KEY (id_nota_credito) REFERENCES produccion.nota_credito (id_nota_credito);
ALTER TABLE produccion.detalle_nota_credito ADD CONSTRAINT fk_detalle_nc_detalle_pedido
   FOREIGN KEY (id_detalle_pedido) REFERENCES produccion.detalle_pedido (id_detalle_pedido);
ALTER TABLE produccion.reembolso ADD CONSTRAINT fk_reembolso_nota_credito
   FOREIGN KEY (id_nota_credito) REFERENCES produccion.nota_credito (id_nota_credito);
ALTER TABLE produccion.reembolso ADD CONSTRAINT fk_reembolso_metodo_pago
   FOREIGN KEY (id_metodo_pago) REFERENCES produccion.metodo_pago (id_metodo_pago);
ALTER TABLE produccion.reembolso ADD CONSTRAINT fk_reembolso_usuario
   FOREIGN KEY (id_usuario_registra) REFERENCES produccion.usuario (id_usuario);

-- Cuentas por cobrar
ALTER TABLE produccion.cuenta_por_cobrar ADD CONSTRAINT fk_cxc_pedido
   FOREIGN KEY (id_pedido) REFERENCES produccion.pedido (id_pedido);
ALTER TABLE produccion.cuenta_por_cobrar ADD CONSTRAINT fk_cxc_metodo_entrega
   FOREIGN KEY (id_metodo_entrega) REFERENCES produccion.metodo_pago (id_metodo_pago);
ALTER TABLE produccion.cuenta_por_cobrar ADD CONSTRAINT fk_cxc_motivo_avance
   FOREIGN KEY (id_motivo_avance) REFERENCES produccion.motivo_avance (id_motivo_avance);
ALTER TABLE produccion.cuenta_por_cobrar ADD CONSTRAINT fk_cxc_usuario
   FOREIGN KEY (id_usuario_autoriza) REFERENCES produccion.usuario (id_usuario);
ALTER TABLE produccion.abono_cliente ADD CONSTRAINT fk_abono_cuenta_por_cobrar
   FOREIGN KEY (id_cuenta_por_cobrar) REFERENCES produccion.cuenta_por_cobrar (id_cuenta_por_cobrar);
ALTER TABLE produccion.abono_cliente ADD CONSTRAINT fk_abono_metodo_pago
   FOREIGN KEY (id_metodo_pago) REFERENCES produccion.metodo_pago (id_metodo_pago);
ALTER TABLE produccion.abono_cliente ADD CONSTRAINT fk_abono_nota_credito
   FOREIGN KEY (id_nota_credito) REFERENCES produccion.nota_credito (id_nota_credito);
ALTER TABLE produccion.abono_cliente ADD CONSTRAINT fk_abono_usuario
   FOREIGN KEY (id_usuario_registra) REFERENCES produccion.usuario (id_usuario);

-- Inventario
ALTER TABLE produccion.lote ADD CONSTRAINT fk_lote_variante
   FOREIGN KEY (id_variante) REFERENCES produccion.variante (id_variante);
ALTER TABLE produccion.lote ADD CONSTRAINT fk_lote_origen
   FOREIGN KEY (id_lote_origen) REFERENCES produccion.lote (id_lote);
ALTER TABLE produccion.movimiento_inventario ADD CONSTRAINT fk_movimiento_tipo
   FOREIGN KEY (id_tipo_movimiento) REFERENCES produccion.tipo_movimiento (id_tipo_movimiento);
ALTER TABLE produccion.movimiento_inventario ADD CONSTRAINT fk_movimiento_usuario
   FOREIGN KEY (id_usuario) REFERENCES produccion.usuario (id_usuario);
ALTER TABLE produccion.movimiento_inventario ADD CONSTRAINT fk_movimiento_orden_compra
   FOREIGN KEY (id_orden_compra) REFERENCES produccion.orden_compra (id_orden_compra);
ALTER TABLE produccion.movimiento_inventario ADD CONSTRAINT fk_movimiento_comprobante_compra
   FOREIGN KEY (id_comprobante_compra) REFERENCES produccion.comprobante_compra (id_comprobante_compra);
ALTER TABLE produccion.movimiento_inventario ADD CONSTRAINT fk_movimiento_comprobante_venta
   FOREIGN KEY (id_comprobante_venta) REFERENCES produccion.comprobante_venta (id_comprobante_venta);
ALTER TABLE produccion.movimiento_inventario ADD CONSTRAINT fk_movimiento_nota_credito
   FOREIGN KEY (id_nota_credito) REFERENCES produccion.nota_credito (id_nota_credito);
ALTER TABLE produccion.detalle_movimiento ADD CONSTRAINT fk_detalle_mov_movimiento
   FOREIGN KEY (id_movimiento) REFERENCES produccion.movimiento_inventario (id_movimiento);
ALTER TABLE produccion.detalle_movimiento ADD CONSTRAINT fk_detalle_mov_lote
   FOREIGN KEY (id_lote) REFERENCES produccion.lote (id_lote);
ALTER TABLE produccion.detalle_movimiento ADD CONSTRAINT fk_detalle_mov_detalle_oc
   FOREIGN KEY (id_detalle_orden_compra) REFERENCES produccion.detalle_orden_compra (id_detalle_orden_compra);
ALTER TABLE produccion.detalle_movimiento ADD CONSTRAINT fk_detalle_mov_detalle_pedido
   FOREIGN KEY (id_detalle_pedido) REFERENCES produccion.detalle_pedido (id_detalle_pedido);
ALTER TABLE produccion.detalle_movimiento ADD CONSTRAINT fk_detalle_mov_detalle_nc
   FOREIGN KEY (id_detalle_nota_credito) REFERENCES produccion.detalle_nota_credito (id_detalle_nota_credito);

-- Cuentas web
ALTER TABLE ecommerce.log_evento_web ADD CONSTRAINT fk_log_evento_web_cuenta
   FOREIGN KEY (id_cuenta_web) REFERENCES ecommerce.cuenta_web (id_cuenta_web);

-- Carrito
ALTER TABLE ecommerce.item_carrito ADD CONSTRAINT fk_item_carrito_carrito
   FOREIGN KEY (id_carrito) REFERENCES ecommerce.carrito (id_carrito) ON DELETE CASCADE;

-- Entre nodos (ecommerce -> produccion). Al separar los nodos:
--   fkx_item_carrito_presentacion  -> FK contra la réplica local del catálogo
--   fkx_carrito_cliente, fkx_cuenta_web_cliente, fkx_carrito_pedido
--     -> se quitan; las validan las funciones del e-commerce al llamar a producción
ALTER TABLE ecommerce.carrito ADD CONSTRAINT fkx_carrito_cliente
   FOREIGN KEY (id_cliente) REFERENCES produccion.cliente (id_cliente);
ALTER TABLE ecommerce.item_carrito ADD CONSTRAINT fkx_item_carrito_presentacion
   FOREIGN KEY (id_presentacion) REFERENCES produccion.presentacion (id_presentacion);
ALTER TABLE ecommerce.cuenta_web ADD CONSTRAINT fkx_cuenta_web_cliente
   FOREIGN KEY (id_cliente) REFERENCES produccion.cliente (id_cliente);
ALTER TABLE ecommerce.carrito ADD CONSTRAINT fkx_carrito_pedido
   FOREIGN KEY (id_pedido) REFERENCES produccion.pedido (id_pedido);


/*==============================================================*/
/* 15. ÍNDICES (columnas de FK usadas en consultas frecuentes)  */
/*==============================================================*/

CREATE INDEX ix_ciudad_provincia            ON produccion.ciudad (id_provincia);
CREATE INDEX ix_direccion_cliente           ON produccion.direccion (id_cliente);
CREATE INDEX ix_datos_facturacion_cliente   ON produccion.datos_facturacion (id_cliente);
CREATE INDEX ix_categoria_padre             ON produccion.categoria (id_categoria_padre);
CREATE INDEX ix_producto_categoria          ON produccion.producto (id_categoria);
CREATE INDEX ix_variante_producto           ON produccion.variante (id_producto);
CREATE INDEX ix_presentacion_variante       ON produccion.presentacion (id_variante);
CREATE INDEX ix_pedido_cliente              ON produccion.pedido (id_cliente, ped_fechahora);
CREATE INDEX ix_pedido_canal                ON produccion.pedido (id_canal_venta, ped_fechahora);
CREATE INDEX ix_historial_estado_pedido     ON produccion.historial_estado_pedido (id_pedido, hep_fechahora);
CREATE INDEX ix_pago_pedido                 ON produccion.pago (id_pedido);
CREATE INDEX ix_comprobante_venta_pedido              ON produccion.comprobante_venta (id_pedido);
CREATE INDEX ix_comprobante_venta_fecha               ON produccion.comprobante_venta (cve_fechahora);
CREATE INDEX ix_nota_credito_comprobante        ON produccion.nota_credito (id_comprobante_venta);
CREATE INDEX ix_detalle_nc_detalle_pedido   ON produccion.detalle_nota_credito (id_detalle_pedido);
CREATE INDEX ix_orden_compra_proveedor      ON produccion.orden_compra (id_proveedor);
CREATE INDEX ix_pago_proveedor_comprobante      ON produccion.pago_proveedor (id_comprobante_compra);
CREATE INDEX ix_ncp_comprobante_compra       ON produccion.nota_credito_proveedor (id_comprobante_compra);
CREATE INDEX ix_movimiento_comprobante_compra     ON produccion.movimiento_inventario (id_comprobante_compra);
CREATE INDEX ix_lote_variante               ON produccion.lote (id_variante);
CREATE INDEX ix_movimiento_fecha            ON produccion.movimiento_inventario (mov_fechahora);
CREATE INDEX ix_movimiento_comprobante_venta          ON produccion.movimiento_inventario (id_comprobante_venta);
CREATE INDEX ix_movimiento_orden_compra     ON produccion.movimiento_inventario (id_orden_compra);
CREATE INDEX ix_detalle_mov_movimiento      ON produccion.detalle_movimiento (id_movimiento);
CREATE INDEX ix_detalle_mov_lote            ON produccion.detalle_movimiento (id_lote);
CREATE INDEX ix_detalle_mov_detalle_pedido  ON produccion.detalle_movimiento (id_detalle_pedido);
CREATE INDEX ix_detalle_mov_detalle_oc      ON produccion.detalle_movimiento (id_detalle_orden_compra);
CREATE INDEX ix_detalle_mov_detalle_nc      ON produccion.detalle_movimiento (id_detalle_nota_credito);
CREATE INDEX ix_cxc_pedido                  ON produccion.cuenta_por_cobrar (id_pedido);
CREATE INDEX ix_abono_cuenta_por_cobrar     ON produccion.abono_cliente (id_cuenta_por_cobrar);
CREATE INDEX ix_abono_nota_credito          ON produccion.abono_cliente (id_nota_credito);
CREATE INDEX ix_lote_origen                 ON produccion.lote (id_lote_origen);
CREATE INDEX ix_oferta_producto             ON produccion.oferta (id_producto, ofe_desde);
CREATE INDEX ix_detalle_pedido_oferta       ON produccion.detalle_pedido (id_oferta);
CREATE INDEX ix_log_evento_fecha            ON produccion.log_evento (lev_fechahora);
CREATE INDEX ix_log_evento_usuario          ON produccion.log_evento (id_usuario);
CREATE INDEX ix_auditoria_registro          ON produccion.auditoria (aud_tabla, aud_id_registro);
CREATE INDEX ix_auditoria_fecha             ON produccion.auditoria (aud_fechahora);
CREATE INDEX ix_log_evento_web_fecha        ON ecommerce.log_evento_web (lew_fechahora);
CREATE INDEX ix_log_evento_web_cuenta       ON ecommerce.log_evento_web (id_cuenta_web);
CREATE INDEX ix_carrito_cliente             ON ecommerce.carrito (id_cliente);
