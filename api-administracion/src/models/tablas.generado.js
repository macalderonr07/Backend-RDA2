// src/models/tablas.generado.js — GENERADO por scripts/generar-modelos.mjs (no editar a mano)
// Un modelo de Sequelize por tabla del esquema PRODUCCION, con tipos, nulos y
// claves leidos del diccionario de datos de Oracle. Las asociaciones estan en
// src/models/index.js.
import { DataTypes } from "sequelize";

/** Define todos los modelos sobre la instancia de Sequelize y los devuelve por nombre. */
export function definirTablas(sequelize) {
    const m = {};

    m.AbonoCliente = sequelize.define(
        "AbonoCliente",
        {
            idAbonoCliente: { type: DataTypes.INTEGER, field: "ID_ABONO_CLIENTE", primaryKey: true, autoIncrement: true },
            idCuentaPorCobrar: { type: DataTypes.INTEGER, field: "ID_CUENTA_POR_COBRAR", allowNull: false },
            idMetodoPago: { type: DataTypes.INTEGER, field: "ID_METODO_PAGO" },
            idNotaCredito: { type: DataTypes.INTEGER, field: "ID_NOTA_CREDITO" },
            monto: { type: DataTypes.DECIMAL(12, 2), field: "ABO_MONTO", get() { const v = this.getDataValue("monto"); return v == null ? null : Number(v); }, allowNull: false },
            fechahora: { type: DataTypes.DATE, field: "ABO_FECHAHORA" },
            referencia: { type: DataTypes.STRING(60), field: "ABO_REFERENCIA" },
            idUsuarioRegistra: { type: DataTypes.INTEGER, field: "ID_USUARIO_REGISTRA", allowNull: false },
        },
        { tableName: "ABONO_CLIENTE" }
    );

    m.Atributo = sequelize.define(
        "Atributo",
        {
            idAtributo: { type: DataTypes.INTEGER, field: "ID_ATRIBUTO", primaryKey: true, autoIncrement: true },
            nombre: { type: DataTypes.STRING(40), field: "ATR_NOMBRE", allowNull: false },
            tipoDato: { type: DataTypes.STRING(6), field: "ATR_TIPO_DATO" },
        },
        { tableName: "ATRIBUTO" }
    );

    m.Auditoria = sequelize.define(
        "Auditoria",
        {
            idAuditoria: { type: DataTypes.INTEGER, field: "ID_AUDITORIA", primaryKey: true, autoIncrement: true },
            fechahora: { type: DataTypes.DATE, field: "AUD_FECHAHORA" },
            tabla: { type: DataTypes.STRING(60), field: "AUD_TABLA", allowNull: false },
            operacion: { type: DataTypes.CHAR(1), field: "AUD_OPERACION", allowNull: false },
            idRegistro: { type: DataTypes.STRING(100), field: "AUD_ID_REGISTRO", allowNull: false },
            valoresAnteriores: { type: DataTypes.TEXT, field: "AUD_VALORES_ANTERIORES" },
            valoresNuevos: { type: DataTypes.TEXT, field: "AUD_VALORES_NUEVOS" },
            idUsuario: { type: DataTypes.INTEGER, field: "ID_USUARIO" },
            usuarioBd: { type: DataTypes.STRING(60), field: "AUD_USUARIO_BD" },
        },
        { tableName: "AUDITORIA" }
    );

    m.CanalVenta = sequelize.define(
        "CanalVenta",
        {
            idCanalVenta: { type: DataTypes.STRING(3), field: "ID_CANAL_VENTA", primaryKey: true, allowNull: false },
            nombre: { type: DataTypes.STRING(40), field: "CAV_NOMBRE", allowNull: false },
        },
        { tableName: "CANAL_VENTA" }
    );

    m.Categoria = sequelize.define(
        "Categoria",
        {
            idCategoria: { type: DataTypes.INTEGER, field: "ID_CATEGORIA", primaryKey: true, autoIncrement: true },
            idCategoriaPadre: { type: DataTypes.INTEGER, field: "ID_CATEGORIA_PADRE" },
            codigo: { type: DataTypes.STRING(20), field: "CAT_CODIGO", allowNull: false },
            nombre: { type: DataTypes.STRING(80), field: "CAT_NOMBRE", allowNull: false },
            activa: { type: DataTypes.INTEGER, field: "CAT_ACTIVA" },
        },
        { tableName: "CATEGORIA" }
    );

    m.CategoriaAtributo = sequelize.define(
        "CategoriaAtributo",
        {
            idCategoria: { type: DataTypes.INTEGER, field: "ID_CATEGORIA", primaryKey: true, allowNull: false },
            idAtributo: { type: DataTypes.INTEGER, field: "ID_ATRIBUTO", primaryKey: true, allowNull: false },
        },
        { tableName: "CATEGORIA_ATRIBUTO" }
    );

    m.Ciudad = sequelize.define(
        "Ciudad",
        {
            idCiudad: { type: DataTypes.INTEGER, field: "ID_CIUDAD", primaryKey: true, autoIncrement: true },
            idProvincia: { type: DataTypes.INTEGER, field: "ID_PROVINCIA", allowNull: false },
            nombre: { type: DataTypes.STRING(60), field: "CIU_NOMBRE", allowNull: false },
        },
        { tableName: "CIUDAD" }
    );

    m.Cliente = sequelize.define(
        "Cliente",
        {
            idCliente: { type: DataTypes.INTEGER, field: "ID_CLIENTE", primaryKey: true, autoIncrement: true },
            nombres: { type: DataTypes.STRING(100), field: "CLI_NOMBRES", allowNull: false },
            apellidos: { type: DataTypes.STRING(100), field: "CLI_APELLIDOS" },
            correo: { type: DataTypes.STRING(120), field: "CLI_CORREO" },
            fechaRegistro: { type: DataTypes.DATE, field: "CLI_FECHA_REGISTRO" },
            limiteCredito: { type: DataTypes.DECIMAL(12, 2), field: "CLI_LIMITE_CREDITO", get() { const v = this.getDataValue("limiteCredito"); return v == null ? null : Number(v); } },
        },
        { tableName: "CLIENTE" }
    );

    m.Combo = sequelize.define(
        "Combo",
        {
            idCombo: { type: DataTypes.INTEGER, field: "ID_COMBO", primaryKey: true, autoIncrement: true },
            codigo: { type: DataTypes.STRING(20), field: "CMB_CODIGO", allowNull: false },
            nombre: { type: DataTypes.STRING(120), field: "CMB_NOMBRE", allowNull: false },
            descripcion: { type: DataTypes.STRING(300), field: "CMB_DESCRIPCION" },
            publicado: { type: DataTypes.INTEGER, field: "CMB_PUBLICADO" },
            fechaCreacion: { type: DataTypes.DATE, field: "CMB_FECHA_CREACION" },
        },
        { tableName: "COMBO" }
    );

    m.ComboComponente = sequelize.define(
        "ComboComponente",
        {
            idCombo: { type: DataTypes.INTEGER, field: "ID_COMBO", primaryKey: true, allowNull: false },
            idProducto: { type: DataTypes.INTEGER, field: "ID_PRODUCTO", primaryKey: true, allowNull: false },
            presentacion: { type: DataTypes.STRING(40), field: "CCO_PRESENTACION", allowNull: false },
            cantidad: { type: DataTypes.DECIMAL(12, 3), field: "CCO_CANTIDAD", get() { const v = this.getDataValue("cantidad"); return v == null ? null : Number(v); }, allowNull: false },
        },
        { tableName: "COMBO_COMPONENTE" }
    );

    m.ComprobanteCompra = sequelize.define(
        "ComprobanteCompra",
        {
            idComprobanteCompra: { type: DataTypes.INTEGER, field: "ID_COMPROBANTE_COMPRA", primaryKey: true, autoIncrement: true },
            idProveedor: { type: DataTypes.INTEGER, field: "ID_PROVEEDOR", allowNull: false },
            idTipoComprobante: { type: DataTypes.CHAR(2), field: "ID_TIPO_COMPROBANTE" },
            numero: { type: DataTypes.STRING(17), field: "CCO_NUMERO", allowNull: false },
            claveAcceso: { type: DataTypes.CHAR(49), field: "CCO_CLAVE_ACCESO" },
            fechaEmision: { type: DataTypes.DATE, field: "CCO_FECHA_EMISION", allowNull: false },
            fechaVencimiento: { type: DataTypes.DATE, field: "CCO_FECHA_VENCIMIENTO", allowNull: false },
            subtotal0: { type: DataTypes.DECIMAL(12, 2), field: "CCO_SUBTOTAL_0", get() { const v = this.getDataValue("subtotal0"); return v == null ? null : Number(v); } },
            subtotalGravado: { type: DataTypes.DECIMAL(12, 2), field: "CCO_SUBTOTAL_GRAVADO", get() { const v = this.getDataValue("subtotalGravado"); return v == null ? null : Number(v); } },
            iva: { type: DataTypes.DECIMAL(12, 2), field: "CCO_IVA", get() { const v = this.getDataValue("iva"); return v == null ? null : Number(v); } },
            idUsuarioRegistra: { type: DataTypes.INTEGER, field: "ID_USUARIO_REGISTRA", allowNull: false },
        },
        { tableName: "COMPROBANTE_COMPRA" }
    );

    m.ComprobanteVenta = sequelize.define(
        "ComprobanteVenta",
        {
            idComprobanteVenta: { type: DataTypes.INTEGER, field: "ID_COMPROBANTE_VENTA", primaryKey: true, autoIncrement: true },
            idTipoComprobante: { type: DataTypes.CHAR(2), field: "ID_TIPO_COMPROBANTE" },
            idPedido: { type: DataTypes.INTEGER, field: "ID_PEDIDO", allowNull: false },
            idDatosFacturacion: { type: DataTypes.INTEGER, field: "ID_DATOS_FACTURACION" },
            idPuntoEmision: { type: DataTypes.INTEGER, field: "ID_PUNTO_EMISION", allowNull: false },
            secuencial: { type: DataTypes.INTEGER, field: "CVE_SECUENCIAL", allowNull: false },
            fechahora: { type: DataTypes.DATE, field: "CVE_FECHAHORA" },
            idUsuarioEmite: { type: DataTypes.INTEGER, field: "ID_USUARIO_EMITE", allowNull: false },
            claveAcceso: { type: DataTypes.CHAR(49), field: "CVE_CLAVE_ACCESO" },
            fechaAutorizacion: { type: DataTypes.DATE, field: "CVE_FECHA_AUTORIZACION" },
            estado: { type: DataTypes.STRING(10), field: "CVE_ESTADO" },
        },
        { tableName: "COMPROBANTE_VENTA" }
    );

    m.CuentaPorCobrar = sequelize.define(
        "CuentaPorCobrar",
        {
            idCuentaPorCobrar: { type: DataTypes.INTEGER, field: "ID_CUENTA_POR_COBRAR", primaryKey: true, autoIncrement: true },
            idPedido: { type: DataTypes.INTEGER, field: "ID_PEDIDO", allowNull: false },
            tipo: { type: DataTypes.STRING(7), field: "CXC_TIPO", allowNull: false },
            monto: { type: DataTypes.DECIMAL(12, 2), field: "CXC_MONTO", get() { const v = this.getDataValue("monto"); return v == null ? null : Number(v); }, allowNull: false },
            concepto: { type: DataTypes.STRING(150), field: "CXC_CONCEPTO", allowNull: false },
            fechahora: { type: DataTypes.DATE, field: "CXC_FECHAHORA" },
            fechaVencimiento: { type: DataTypes.DATE, field: "CXC_FECHA_VENCIMIENTO", allowNull: false },
            idMetodoEntrega: { type: DataTypes.INTEGER, field: "ID_METODO_ENTREGA" },
            idMotivoAvance: { type: DataTypes.INTEGER, field: "ID_MOTIVO_AVANCE" },
            idUsuarioAutoriza: { type: DataTypes.INTEGER, field: "ID_USUARIO_AUTORIZA", allowNull: false },
        },
        { tableName: "CUENTA_POR_COBRAR" }
    );

    m.DatosFacturacion = sequelize.define(
        "DatosFacturacion",
        {
            idDatosFacturacion: { type: DataTypes.INTEGER, field: "ID_DATOS_FACTURACION", primaryKey: true, autoIncrement: true },
            idCliente: { type: DataTypes.INTEGER, field: "ID_CLIENTE", allowNull: false },
            idTipoIdentificacion: { type: DataTypes.CHAR(2), field: "ID_TIPO_IDENTIFICACION", allowNull: false },
            identificacion: { type: DataTypes.STRING(20), field: "DFA_IDENTIFICACION", allowNull: false },
            razonSocial: { type: DataTypes.STRING(150), field: "DFA_RAZON_SOCIAL", allowNull: false },
            correo: { type: DataTypes.STRING(120), field: "DFA_CORREO" },
            idDireccion: { type: DataTypes.INTEGER, field: "ID_DIRECCION" },
            activo: { type: DataTypes.INTEGER, field: "DFA_ACTIVO" },
            idSector: { type: DataTypes.INTEGER, field: "ID_SECTOR" },
        },
        { tableName: "DATOS_FACTURACION" }
    );

    m.DescuentoVolumen = sequelize.define(
        "DescuentoVolumen",
        {
            idDescuentoVolumen: { type: DataTypes.INTEGER, field: "ID_DESCUENTO_VOLUMEN", primaryKey: true, autoIncrement: true },
            idProducto: { type: DataTypes.INTEGER, field: "ID_PRODUCTO", allowNull: false },
            cantidadMinima: { type: DataTypes.DECIMAL(12, 3), field: "DVO_CANTIDAD_MINIMA", get() { const v = this.getDataValue("cantidadMinima"); return v == null ? null : Number(v); }, allowNull: false },
            porcentaje: { type: DataTypes.DECIMAL(5, 2), field: "DVO_PORCENTAJE", get() { const v = this.getDataValue("porcentaje"); return v == null ? null : Number(v); }, allowNull: false },
            activo: { type: DataTypes.INTEGER, field: "DVO_ACTIVO" },
            fechaCreacion: { type: DataTypes.DATE, field: "DVO_FECHA_CREACION" },
            idUsuario: { type: DataTypes.INTEGER, field: "ID_USUARIO", allowNull: false },
        },
        { tableName: "DESCUENTO_VOLUMEN" }
    );

    m.DetalleMovimiento = sequelize.define(
        "DetalleMovimiento",
        {
            idDetalleMovimiento: { type: DataTypes.INTEGER, field: "ID_DETALLE_MOVIMIENTO", primaryKey: true, autoIncrement: true },
            idMovimiento: { type: DataTypes.INTEGER, field: "ID_MOVIMIENTO", allowNull: false },
            idLote: { type: DataTypes.INTEGER, field: "ID_LOTE", allowNull: false },
            cantidad: { type: DataTypes.DECIMAL(12, 3), field: "DMO_CANTIDAD", get() { const v = this.getDataValue("cantidad"); return v == null ? null : Number(v); }, allowNull: false },
            idDetalleOrdenCompra: { type: DataTypes.INTEGER, field: "ID_DETALLE_ORDEN_COMPRA" },
            idDetallePedido: { type: DataTypes.INTEGER, field: "ID_DETALLE_PEDIDO" },
            idDetalleNotaCredito: { type: DataTypes.INTEGER, field: "ID_DETALLE_NOTA_CREDITO" },
        },
        { tableName: "DETALLE_MOVIMIENTO" }
    );

    m.DetalleNotaCredito = sequelize.define(
        "DetalleNotaCredito",
        {
            idDetalleNotaCredito: { type: DataTypes.INTEGER, field: "ID_DETALLE_NOTA_CREDITO", primaryKey: true, autoIncrement: true },
            idNotaCredito: { type: DataTypes.INTEGER, field: "ID_NOTA_CREDITO", allowNull: false },
            idDetallePedido: { type: DataTypes.INTEGER, field: "ID_DETALLE_PEDIDO", allowNull: false },
            cantidad: { type: DataTypes.DECIMAL(12, 3), field: "DNC_CANTIDAD", get() { const v = this.getDataValue("cantidad"); return v == null ? null : Number(v); }, allowNull: false },
            reingresaStock: { type: DataTypes.INTEGER, field: "DNC_REINGRESA_STOCK" },
        },
        { tableName: "DETALLE_NOTA_CREDITO" }
    );

    m.DetalleOrdenCompra = sequelize.define(
        "DetalleOrdenCompra",
        {
            idDetalleOrdenCompra: { type: DataTypes.INTEGER, field: "ID_DETALLE_ORDEN_COMPRA", primaryKey: true, autoIncrement: true },
            idOrdenCompra: { type: DataTypes.INTEGER, field: "ID_ORDEN_COMPRA", allowNull: false },
            idVariante: { type: DataTypes.INTEGER, field: "ID_VARIANTE", allowNull: false },
            cantidad: { type: DataTypes.DECIMAL(12, 3), field: "DCO_CANTIDAD", get() { const v = this.getDataValue("cantidad"); return v == null ? null : Number(v); }, allowNull: false },
            costoUnitario: { type: DataTypes.DECIMAL(12, 4), field: "DCO_COSTO_UNITARIO", get() { const v = this.getDataValue("costoUnitario"); return v == null ? null : Number(v); }, allowNull: false },
        },
        { tableName: "DETALLE_ORDEN_COMPRA" }
    );

    m.DetallePedido = sequelize.define(
        "DetallePedido",
        {
            idDetallePedido: { type: DataTypes.INTEGER, field: "ID_DETALLE_PEDIDO", primaryKey: true, autoIncrement: true },
            idPedido: { type: DataTypes.INTEGER, field: "ID_PEDIDO", allowNull: false },
            idPresentacion: { type: DataTypes.INTEGER, field: "ID_PRESENTACION", allowNull: false },
            cantidad: { type: DataTypes.DECIMAL(12, 3), field: "DPE_CANTIDAD", get() { const v = this.getDataValue("cantidad"); return v == null ? null : Number(v); }, allowNull: false },
            precioUnitario: { type: DataTypes.DECIMAL(12, 2), field: "DPE_PRECIO_UNITARIO", get() { const v = this.getDataValue("precioUnitario"); return v == null ? null : Number(v); }, allowNull: false },
            descuento: { type: DataTypes.DECIMAL(12, 2), field: "DPE_DESCUENTO", get() { const v = this.getDataValue("descuento"); return v == null ? null : Number(v); } },
            idTarifaIva: { type: DataTypes.STRING(2), field: "ID_TARIFA_IVA", allowNull: false },
            idUsuarioDescuento: { type: DataTypes.INTEGER, field: "ID_USUARIO_DESCUENTO" },
            idOferta: { type: DataTypes.INTEGER, field: "ID_OFERTA" },
            idDescuentoVolumen: { type: DataTypes.INTEGER, field: "ID_DESCUENTO_VOLUMEN" },
            idLoteReservado: { type: DataTypes.INTEGER, field: "ID_LOTE_RESERVADO" },
        },
        { tableName: "DETALLE_PEDIDO" }
    );

    m.Direccion = sequelize.define(
        "Direccion",
        {
            idDireccion: { type: DataTypes.INTEGER, field: "ID_DIRECCION", primaryKey: true, autoIncrement: true },
            idCliente: { type: DataTypes.INTEGER, field: "ID_CLIENTE" },
            idCiudad: { type: DataTypes.INTEGER, field: "ID_CIUDAD", allowNull: false },
            callePrincipal: { type: DataTypes.STRING(120), field: "DIR_CALLE_PRINCIPAL", allowNull: false },
            numero: { type: DataTypes.STRING(15), field: "DIR_NUMERO" },
            calleSecundaria: { type: DataTypes.STRING(120), field: "DIR_CALLE_SECUNDARIA" },
            referencia: { type: DataTypes.STRING(200), field: "DIR_REFERENCIA" },
            activa: { type: DataTypes.INTEGER, field: "DIR_ACTIVA" },
            idSector: { type: DataTypes.INTEGER, field: "ID_SECTOR" },
        },
        { tableName: "DIRECCION" }
    );

    m.Empleado = sequelize.define(
        "Empleado",
        {
            idUsuario: { type: DataTypes.INTEGER, field: "ID_USUARIO", primaryKey: true, allowNull: false },
            idTipoIdentificacion: { type: DataTypes.CHAR(2), field: "ID_TIPO_IDENTIFICACION", allowNull: false },
            identificacion: { type: DataTypes.STRING(20), field: "EPL_IDENTIFICACION", allowNull: false },
            nombres: { type: DataTypes.STRING(80), field: "EPL_NOMBRES", allowNull: false },
            apellidos: { type: DataTypes.STRING(80), field: "EPL_APELLIDOS", allowNull: false },
            fechaIngreso: { type: DataTypes.DATE, field: "EPL_FECHA_INGRESO" },
        },
        { tableName: "EMPLEADO" }
    );

    m.Empresa = sequelize.define(
        "Empresa",
        {
            idEmpresa: { type: DataTypes.INTEGER, field: "ID_EMPRESA", primaryKey: true },
            ruc: { type: DataTypes.CHAR(13), field: "EMP_RUC", allowNull: false },
            razonSocial: { type: DataTypes.STRING(150), field: "EMP_RAZON_SOCIAL", allowNull: false },
            nombreComercial: { type: DataTypes.STRING(100), field: "EMP_NOMBRE_COMERCIAL", allowNull: false },
            eslogan: { type: DataTypes.STRING(150), field: "EMP_ESLOGAN" },
            correo: { type: DataTypes.STRING(120), field: "EMP_CORREO", allowNull: false },
            telefono: { type: DataTypes.STRING(15), field: "EMP_TELEFONO" },
            idDireccionMatriz: { type: DataTypes.INTEGER, field: "ID_DIRECCION_MATRIZ", allowNull: false },
            diasDevolucion: { type: DataTypes.INTEGER, field: "EMP_DIAS_DEVOLUCION" },
            ambienteSri: { type: DataTypes.CHAR(1), field: "EMP_AMBIENTE_SRI" },
            maxConsumidorFinal: { type: DataTypes.DECIMAL(12, 2), field: "EMP_MAX_CONSUMIDOR_FINAL", get() { const v = this.getDataValue("maxConsumidorFinal"); return v == null ? null : Number(v); } },
        },
        { tableName: "EMPRESA" }
    );

    m.Envio = sequelize.define(
        "Envio",
        {
            idEnvio: { type: DataTypes.INTEGER, field: "ID_ENVIO", primaryKey: true, autoIncrement: true },
            idPedido: { type: DataTypes.INTEGER, field: "ID_PEDIDO", allowNull: false },
            idDireccion: { type: DataTypes.INTEGER, field: "ID_DIRECCION", allowNull: false },
            idTransportista: { type: DataTypes.INTEGER, field: "ID_TRANSPORTISTA" },
            guia: { type: DataTypes.STRING(40), field: "ENV_GUIA" },
            costo: { type: DataTypes.DECIMAL(12, 2), field: "ENV_COSTO", get() { const v = this.getDataValue("costo"); return v == null ? null : Number(v); } },
            idTarifaIva: { type: DataTypes.STRING(2), field: "ID_TARIFA_IVA", allowNull: false },
        },
        { tableName: "ENVIO" }
    );

    m.EstadoPedido = sequelize.define(
        "EstadoPedido",
        {
            idEstadoPedido: { type: DataTypes.STRING(3), field: "ID_ESTADO_PEDIDO", primaryKey: true, allowNull: false },
            nombre: { type: DataTypes.STRING(30), field: "ESP_NOMBRE", allowNull: false },
            orden: { type: DataTypes.INTEGER, field: "ESP_ORDEN", allowNull: false },
        },
        { tableName: "ESTADO_PEDIDO" }
    );

    m.HistorialEstadoPedido = sequelize.define(
        "HistorialEstadoPedido",
        {
            idHistorialEstado: { type: DataTypes.INTEGER, field: "ID_HISTORIAL_ESTADO", primaryKey: true, autoIncrement: true },
            idPedido: { type: DataTypes.INTEGER, field: "ID_PEDIDO", allowNull: false },
            idEstadoPedido: { type: DataTypes.STRING(3), field: "ID_ESTADO_PEDIDO", allowNull: false },
            fechahora: { type: DataTypes.DATE, field: "HEP_FECHAHORA" },
            idUsuario: { type: DataTypes.INTEGER, field: "ID_USUARIO" },
            observacion: { type: DataTypes.STRING(200), field: "HEP_OBSERVACION" },
        },
        { tableName: "HISTORIAL_ESTADO_PEDIDO" }
    );

    m.HistorialPrecio = sequelize.define(
        "HistorialPrecio",
        {
            idHistorialPrecio: { type: DataTypes.INTEGER, field: "ID_HISTORIAL_PRECIO", primaryKey: true, autoIncrement: true },
            idPresentacion: { type: DataTypes.INTEGER, field: "ID_PRESENTACION", allowNull: false },
            precio: { type: DataTypes.DECIMAL(12, 2), field: "HPR_PRECIO", get() { const v = this.getDataValue("precio"); return v == null ? null : Number(v); }, allowNull: false },
            vigenteDesde: { type: DataTypes.DATE, field: "HPR_VIGENTE_DESDE" },
            idUsuario: { type: DataTypes.INTEGER, field: "ID_USUARIO", allowNull: false },
        },
        { tableName: "HISTORIAL_PRECIO" }
    );

    m.LogEvento = sequelize.define(
        "LogEvento",
        {
            idLogEvento: { type: DataTypes.INTEGER, field: "ID_LOG_EVENTO", primaryKey: true, autoIncrement: true },
            fechahora: { type: DataTypes.DATE, field: "LEV_FECHAHORA" },
            nivel: { type: DataTypes.STRING(5), field: "LEV_NIVEL", allowNull: false },
            origen: { type: DataTypes.STRING(12), field: "LEV_ORIGEN", allowNull: false },
            evento: { type: DataTypes.STRING(40), field: "LEV_EVENTO", allowNull: false },
            mensaje: { type: DataTypes.STRING(500), field: "LEV_MENSAJE", allowNull: false },
            idUsuario: { type: DataTypes.INTEGER, field: "ID_USUARIO" },
            ip: { type: DataTypes.STRING(45), field: "LEV_IP" },
            detalle: { type: DataTypes.TEXT, field: "LEV_DETALLE" },
        },
        { tableName: "LOG_EVENTO" }
    );

    m.Lote = sequelize.define(
        "Lote",
        {
            idLote: { type: DataTypes.INTEGER, field: "ID_LOTE", primaryKey: true, autoIncrement: true },
            idVariante: { type: DataTypes.INTEGER, field: "ID_VARIANTE", allowNull: false },
            costoUnitario: { type: DataTypes.DECIMAL(12, 4), field: "LOT_COSTO_UNITARIO", get() { const v = this.getDataValue("costoUnitario"); return v == null ? null : Number(v); }, allowNull: false },
            fechaVencimiento: { type: DataTypes.DATE, field: "LOT_FECHA_VENCIMIENTO" },
            codigoProveedor: { type: DataTypes.STRING(30), field: "LOT_CODIGO_PROVEEDOR" },
            idLoteOrigen: { type: DataTypes.INTEGER, field: "ID_LOTE_ORIGEN" },
        },
        { tableName: "LOTE" }
    );

    m.Marca = sequelize.define(
        "Marca",
        {
            idMarca: { type: DataTypes.INTEGER, field: "ID_MARCA", primaryKey: true, autoIncrement: true },
            nombre: { type: DataTypes.STRING(60), field: "MAR_NOMBRE", allowNull: false },
            activa: { type: DataTypes.INTEGER, field: "MAR_ACTIVA" },
        },
        { tableName: "MARCA" }
    );

    m.MetodoPago = sequelize.define(
        "MetodoPago",
        {
            idMetodoPago: { type: DataTypes.INTEGER, field: "ID_METODO_PAGO", primaryKey: true, autoIncrement: true },
            nombre: { type: DataTypes.STRING(40), field: "MPA_NOMBRE", allowNull: false },
            codigoSri: { type: DataTypes.CHAR(2), field: "MPA_CODIGO_SRI", allowNull: false },
        },
        { tableName: "METODO_PAGO" }
    );

    m.MotivoAvance = sequelize.define(
        "MotivoAvance",
        {
            idMotivoAvance: { type: DataTypes.INTEGER, field: "ID_MOTIVO_AVANCE", primaryKey: true, autoIncrement: true },
            nombre: { type: DataTypes.STRING(60), field: "MAV_NOMBRE", allowNull: false },
        },
        { tableName: "MOTIVO_AVANCE" }
    );

    m.MotivoDevolucion = sequelize.define(
        "MotivoDevolucion",
        {
            idMotivoDevolucion: { type: DataTypes.INTEGER, field: "ID_MOTIVO_DEVOLUCION", primaryKey: true, autoIncrement: true },
            nombre: { type: DataTypes.STRING(60), field: "MDE_NOMBRE", allowNull: false },
        },
        { tableName: "MOTIVO_DEVOLUCION" }
    );

    m.MovimientoInventario = sequelize.define(
        "MovimientoInventario",
        {
            idMovimiento: { type: DataTypes.INTEGER, field: "ID_MOVIMIENTO", primaryKey: true, autoIncrement: true },
            idTipoMovimiento: { type: DataTypes.CHAR(3), field: "ID_TIPO_MOVIMIENTO", allowNull: false },
            fechahora: { type: DataTypes.DATE, field: "MOV_FECHAHORA" },
            idUsuario: { type: DataTypes.INTEGER, field: "ID_USUARIO", allowNull: false },
            motivo: { type: DataTypes.STRING(200), field: "MOV_MOTIVO" },
            idOrdenCompra: { type: DataTypes.INTEGER, field: "ID_ORDEN_COMPRA" },
            idComprobanteCompra: { type: DataTypes.INTEGER, field: "ID_COMPROBANTE_COMPRA" },
            idComprobanteVenta: { type: DataTypes.INTEGER, field: "ID_COMPROBANTE_VENTA" },
            idNotaCredito: { type: DataTypes.INTEGER, field: "ID_NOTA_CREDITO" },
        },
        { tableName: "MOVIMIENTO_INVENTARIO" }
    );

    m.NotaCredito = sequelize.define(
        "NotaCredito",
        {
            idNotaCredito: { type: DataTypes.INTEGER, field: "ID_NOTA_CREDITO", primaryKey: true, autoIncrement: true },
            idComprobanteVenta: { type: DataTypes.INTEGER, field: "ID_COMPROBANTE_VENTA", allowNull: false },
            idPuntoEmision: { type: DataTypes.INTEGER, field: "ID_PUNTO_EMISION", allowNull: false },
            secuencial: { type: DataTypes.INTEGER, field: "NCR_SECUENCIAL", allowNull: false },
            fechahora: { type: DataTypes.DATE, field: "NCR_FECHAHORA" },
            idMotivoDevolucion: { type: DataTypes.INTEGER, field: "ID_MOTIVO_DEVOLUCION", allowNull: false },
            idUsuarioAutoriza: { type: DataTypes.INTEGER, field: "ID_USUARIO_AUTORIZA", allowNull: false },
            observacion: { type: DataTypes.STRING(250), field: "NCR_OBSERVACION" },
            claveAcceso: { type: DataTypes.CHAR(49), field: "NCR_CLAVE_ACCESO" },
            fechaAutorizacion: { type: DataTypes.DATE, field: "NCR_FECHA_AUTORIZACION" },
            estado: { type: DataTypes.STRING(10), field: "NCR_ESTADO" },
        },
        { tableName: "NOTA_CREDITO" }
    );

    m.NotaCreditoProveedor = sequelize.define(
        "NotaCreditoProveedor",
        {
            idNotaCreditoProveedor: { type: DataTypes.INTEGER, field: "ID_NOTA_CREDITO_PROVEEDOR", primaryKey: true, autoIncrement: true },
            idComprobanteCompra: { type: DataTypes.INTEGER, field: "ID_COMPROBANTE_COMPRA", allowNull: false },
            numero: { type: DataTypes.STRING(17), field: "NCP_NUMERO", allowNull: false },
            claveAcceso: { type: DataTypes.CHAR(49), field: "NCP_CLAVE_ACCESO" },
            fechaEmision: { type: DataTypes.DATE, field: "NCP_FECHA_EMISION", allowNull: false },
            subtotal0: { type: DataTypes.DECIMAL(12, 2), field: "NCP_SUBTOTAL_0", get() { const v = this.getDataValue("subtotal0"); return v == null ? null : Number(v); } },
            subtotalGravado: { type: DataTypes.DECIMAL(12, 2), field: "NCP_SUBTOTAL_GRAVADO", get() { const v = this.getDataValue("subtotalGravado"); return v == null ? null : Number(v); } },
            iva: { type: DataTypes.DECIMAL(12, 2), field: "NCP_IVA", get() { const v = this.getDataValue("iva"); return v == null ? null : Number(v); } },
            motivo: { type: DataTypes.STRING(200), field: "NCP_MOTIVO", allowNull: false },
            idUsuarioRegistra: { type: DataTypes.INTEGER, field: "ID_USUARIO_REGISTRA", allowNull: false },
        },
        { tableName: "NOTA_CREDITO_PROVEEDOR" }
    );

    m.Oferta = sequelize.define(
        "Oferta",
        {
            idOferta: { type: DataTypes.INTEGER, field: "ID_OFERTA", primaryKey: true, autoIncrement: true },
            idProducto: { type: DataTypes.INTEGER, field: "ID_PRODUCTO", allowNull: false },
            porcentaje: { type: DataTypes.DECIMAL(5, 2), field: "OFE_PORCENTAJE", get() { const v = this.getDataValue("porcentaje"); return v == null ? null : Number(v); }, allowNull: false },
            descripcion: { type: DataTypes.STRING(100), field: "OFE_DESCRIPCION" },
            desde: { type: DataTypes.DATE, field: "OFE_DESDE" },
            hasta: { type: DataTypes.DATE, field: "OFE_HASTA" },
            activa: { type: DataTypes.INTEGER, field: "OFE_ACTIVA" },
            idUsuarioRegistra: { type: DataTypes.INTEGER, field: "ID_USUARIO_REGISTRA", allowNull: false },
            fechaRegistro: { type: DataTypes.DATE, field: "OFE_FECHA_REGISTRO" },
        },
        { tableName: "OFERTA" }
    );

    m.OrdenCompra = sequelize.define(
        "OrdenCompra",
        {
            idOrdenCompra: { type: DataTypes.INTEGER, field: "ID_ORDEN_COMPRA", primaryKey: true, autoIncrement: true },
            idProveedor: { type: DataTypes.INTEGER, field: "ID_PROVEEDOR", allowNull: false },
            idUsuarioCrea: { type: DataTypes.INTEGER, field: "ID_USUARIO_CREA", allowNull: false },
            fecha: { type: DataTypes.DATE, field: "OC_FECHA" },
            fechaEntregaEsperada: { type: DataTypes.DATE, field: "OC_FECHA_ENTREGA_ESPERADA" },
            estado: { type: DataTypes.STRING(8), field: "OC_ESTADO" },
            observacion: { type: DataTypes.STRING(250), field: "OC_OBSERVACION" },
        },
        { tableName: "ORDEN_COMPRA" }
    );

    m.Pago = sequelize.define(
        "Pago",
        {
            idPago: { type: DataTypes.INTEGER, field: "ID_PAGO", primaryKey: true, autoIncrement: true },
            idPedido: { type: DataTypes.INTEGER, field: "ID_PEDIDO", allowNull: false },
            idMetodoPago: { type: DataTypes.INTEGER, field: "ID_METODO_PAGO", allowNull: false },
            monto: { type: DataTypes.DECIMAL(12, 2), field: "PAG_MONTO", get() { const v = this.getDataValue("monto"); return v == null ? null : Number(v); }, allowNull: false },
            fechahora: { type: DataTypes.DATE, field: "PAG_FECHAHORA" },
            referencia: { type: DataTypes.STRING(60), field: "PAG_REFERENCIA" },
            estado: { type: DataTypes.STRING(9), field: "PAG_ESTADO" },
            idUsuarioRegistra: { type: DataTypes.INTEGER, field: "ID_USUARIO_REGISTRA", allowNull: false },
        },
        { tableName: "PAGO" }
    );

    m.PagoProveedor = sequelize.define(
        "PagoProveedor",
        {
            idPagoProveedor: { type: DataTypes.INTEGER, field: "ID_PAGO_PROVEEDOR", primaryKey: true, autoIncrement: true },
            idComprobanteCompra: { type: DataTypes.INTEGER, field: "ID_COMPROBANTE_COMPRA", allowNull: false },
            idMetodoPago: { type: DataTypes.INTEGER, field: "ID_METODO_PAGO", allowNull: false },
            monto: { type: DataTypes.DECIMAL(12, 2), field: "PPR_MONTO", get() { const v = this.getDataValue("monto"); return v == null ? null : Number(v); }, allowNull: false },
            fecha: { type: DataTypes.DATE, field: "PPR_FECHA" },
            referencia: { type: DataTypes.STRING(60), field: "PPR_REFERENCIA" },
            idUsuarioRegistra: { type: DataTypes.INTEGER, field: "ID_USUARIO_REGISTRA", allowNull: false },
        },
        { tableName: "PAGO_PROVEEDOR" }
    );

    m.Pedido = sequelize.define(
        "Pedido",
        {
            idPedido: { type: DataTypes.INTEGER, field: "ID_PEDIDO", primaryKey: true, autoIncrement: true },
            idCliente: { type: DataTypes.INTEGER, field: "ID_CLIENTE", allowNull: false },
            idCanalVenta: { type: DataTypes.STRING(3), field: "ID_CANAL_VENTA", allowNull: false },
            idEmpleadoVendedor: { type: DataTypes.INTEGER, field: "ID_EMPLEADO_VENDEDOR" },
            fechahora: { type: DataTypes.DATE, field: "PED_FECHAHORA" },
            observacion: { type: DataTypes.STRING(250), field: "PED_OBSERVACION" },
        },
        { tableName: "PEDIDO" }
    );

    m.Permiso = sequelize.define(
        "Permiso",
        {
            idPermiso: { type: DataTypes.INTEGER, field: "ID_PERMISO", primaryKey: true, autoIncrement: true },
            codigo: { type: DataTypes.STRING(30), field: "PER_CODIGO", allowNull: false },
            descripcion: { type: DataTypes.STRING(150), field: "PER_DESCRIPCION", allowNull: false },
        },
        { tableName: "PERMISO" }
    );

    m.Presentacion = sequelize.define(
        "Presentacion",
        {
            idPresentacion: { type: DataTypes.INTEGER, field: "ID_PRESENTACION", primaryKey: true, autoIncrement: true },
            idVariante: { type: DataTypes.INTEGER, field: "ID_VARIANTE", allowNull: false },
            descripcion: { type: DataTypes.STRING(40), field: "PRE_DESCRIPCION", allowNull: false },
            factor: { type: DataTypes.DECIMAL(12, 3), field: "PRE_FACTOR", get() { const v = this.getDataValue("factor"); return v == null ? null : Number(v); }, allowNull: false },
            cantidadMinima: { type: DataTypes.DECIMAL(12, 3), field: "PRE_CANTIDAD_MINIMA", get() { const v = this.getDataValue("cantidadMinima"); return v == null ? null : Number(v); } },
            activa: { type: DataTypes.INTEGER, field: "PRE_ACTIVA" },
            incremento: { type: DataTypes.DECIMAL(12, 3), field: "PRE_INCREMENTO", get() { const v = this.getDataValue("incremento"); return v == null ? null : Number(v); } },
            corteDe: { type: DataTypes.DECIMAL(12, 3), field: "PRE_CORTE_DE", get() { const v = this.getDataValue("corteDe"); return v == null ? null : Number(v); } },
        },
        { tableName: "PRESENTACION" }
    );

    m.Producto = sequelize.define(
        "Producto",
        {
            idProducto: { type: DataTypes.INTEGER, field: "ID_PRODUCTO", primaryKey: true, autoIncrement: true },
            idCategoria: { type: DataTypes.INTEGER, field: "ID_CATEGORIA", allowNull: false },
            idUnidadMedida: { type: DataTypes.STRING(4), field: "ID_UNIDAD_MEDIDA", allowNull: false },
            idTarifaIva: { type: DataTypes.STRING(2), field: "ID_TARIFA_IVA", allowNull: false },
            codigo: { type: DataTypes.STRING(20), field: "PRD_CODIGO", allowNull: false },
            nombre: { type: DataTypes.STRING(150), field: "PRD_NOMBRE", allowNull: false },
            descripcion: { type: DataTypes.TEXT, field: "PRD_DESCRIPCION" },
            uso: { type: DataTypes.STRING(200), field: "PRD_USO" },
            imagenUrl: { type: DataTypes.STRING(500), field: "PRD_IMAGEN_URL" },
            publicado: { type: DataTypes.INTEGER, field: "PRD_PUBLICADO" },
            ventaPorPieza: { type: DataTypes.INTEGER, field: "PRD_VENTA_POR_PIEZA" },
            fechaCreacion: { type: DataTypes.DATE, field: "PRD_FECHA_CREACION" },
            idMarca: { type: DataTypes.INTEGER, field: "ID_MARCA" },
            cortesEstandar: { type: DataTypes.INTEGER, field: "PRD_CORTES_ESTANDAR" },
            precioPorVariante: { type: DataTypes.INTEGER, field: "PRD_PRECIO_POR_VARIANTE" },
            compraDescripcion: { type: DataTypes.STRING(40), field: "PRD_COMPRA_DESCRIPCION" },
            compraFactor: { type: DataTypes.DECIMAL(12, 3), field: "PRD_COMPRA_FACTOR", get() { const v = this.getDataValue("compraFactor"); return v == null ? null : Number(v); } },
        },
        { tableName: "PRODUCTO" }
    );

    m.ProductoProveedor = sequelize.define(
        "ProductoProveedor",
        {
            idProducto: { type: DataTypes.INTEGER, field: "ID_PRODUCTO", primaryKey: true, allowNull: false },
            idProveedor: { type: DataTypes.INTEGER, field: "ID_PROVEEDOR", primaryKey: true, allowNull: false },
            codigoProveedor: { type: DataTypes.STRING(40), field: "PPV_CODIGO_PROVEEDOR" },
            fechaRegistro: { type: DataTypes.DATE, field: "PPV_FECHA_REGISTRO" },
        },
        { tableName: "PRODUCTO_PROVEEDOR" }
    );

    m.Proveedor = sequelize.define(
        "Proveedor",
        {
            idProveedor: { type: DataTypes.INTEGER, field: "ID_PROVEEDOR", primaryKey: true, autoIncrement: true },
            idTipoIdentificacion: { type: DataTypes.CHAR(2), field: "ID_TIPO_IDENTIFICACION", allowNull: false },
            identificacion: { type: DataTypes.STRING(20), field: "PRV_IDENTIFICACION", allowNull: false },
            razonSocial: { type: DataTypes.STRING(150), field: "PRV_RAZON_SOCIAL", allowNull: false },
            nombreComercial: { type: DataTypes.STRING(100), field: "PRV_NOMBRE_COMERCIAL" },
            correo: { type: DataTypes.STRING(120), field: "PRV_CORREO" },
            telefono: { type: DataTypes.STRING(15), field: "PRV_TELEFONO" },
            activo: { type: DataTypes.INTEGER, field: "PRV_ACTIVO" },
        },
        { tableName: "PROVEEDOR" }
    );

    m.Provincia = sequelize.define(
        "Provincia",
        {
            idProvincia: { type: DataTypes.INTEGER, field: "ID_PROVINCIA", primaryKey: true, autoIncrement: true },
            nombre: { type: DataTypes.STRING(40), field: "PVC_NOMBRE", allowNull: false },
        },
        { tableName: "PROVINCIA" }
    );

    m.PuntoEmision = sequelize.define(
        "PuntoEmision",
        {
            idPuntoEmision: { type: DataTypes.INTEGER, field: "ID_PUNTO_EMISION", primaryKey: true, autoIncrement: true },
            establecimiento: { type: DataTypes.CHAR(3), field: "PEM_ESTABLECIMIENTO", allowNull: false },
            punto: { type: DataTypes.CHAR(3), field: "PEM_PUNTO", allowNull: false },
            descripcion: { type: DataTypes.STRING(60), field: "PEM_DESCRIPCION", allowNull: false },
            activo: { type: DataTypes.INTEGER, field: "PEM_ACTIVO" },
        },
        { tableName: "PUNTO_EMISION" }
    );

    m.Reembolso = sequelize.define(
        "Reembolso",
        {
            idReembolso: { type: DataTypes.INTEGER, field: "ID_REEMBOLSO", primaryKey: true, autoIncrement: true },
            idNotaCredito: { type: DataTypes.INTEGER, field: "ID_NOTA_CREDITO", allowNull: false },
            idMetodoPago: { type: DataTypes.INTEGER, field: "ID_METODO_PAGO", allowNull: false },
            monto: { type: DataTypes.DECIMAL(12, 2), field: "REE_MONTO", get() { const v = this.getDataValue("monto"); return v == null ? null : Number(v); }, allowNull: false },
            fechahora: { type: DataTypes.DATE, field: "REE_FECHAHORA" },
            referencia: { type: DataTypes.STRING(60), field: "REE_REFERENCIA" },
            idUsuarioRegistra: { type: DataTypes.INTEGER, field: "ID_USUARIO_REGISTRA", allowNull: false },
        },
        { tableName: "REEMBOLSO" }
    );

    m.Rol = sequelize.define(
        "Rol",
        {
            idRol: { type: DataTypes.INTEGER, field: "ID_ROL", primaryKey: true, autoIncrement: true },
            codigo: { type: DataTypes.STRING(20), field: "ROL_CODIGO", allowNull: false },
            nombre: { type: DataTypes.STRING(60), field: "ROL_NOMBRE", allowNull: false },
        },
        { tableName: "ROL" }
    );

    m.RolPermiso = sequelize.define(
        "RolPermiso",
        {
            idRol: { type: DataTypes.INTEGER, field: "ID_ROL", primaryKey: true, allowNull: false },
            idPermiso: { type: DataTypes.INTEGER, field: "ID_PERMISO", primaryKey: true, allowNull: false },
        },
        { tableName: "ROL_PERMISO" }
    );

    m.Sector = sequelize.define(
        "Sector",
        {
            idSector: { type: DataTypes.INTEGER, field: "ID_SECTOR", primaryKey: true, autoIncrement: true },
            idCiudad: { type: DataTypes.INTEGER, field: "ID_CIUDAD", allowNull: false },
            nombre: { type: DataTypes.STRING(80), field: "SEC_NOMBRE", allowNull: false },
            activo: { type: DataTypes.INTEGER, field: "SEC_ACTIVO" },
        },
        { tableName: "SECTOR" }
    );

    m.TarifaIva = sequelize.define(
        "TarifaIva",
        {
            idTarifaIva: { type: DataTypes.STRING(2), field: "ID_TARIFA_IVA", primaryKey: true, allowNull: false },
            porcentaje: { type: DataTypes.DECIMAL(5, 2), field: "TIV_PORCENTAJE", get() { const v = this.getDataValue("porcentaje"); return v == null ? null : Number(v); }, allowNull: false },
            descripcion: { type: DataTypes.STRING(40), field: "TIV_DESCRIPCION", allowNull: false },
            vigente: { type: DataTypes.INTEGER, field: "TIV_VIGENTE" },
        },
        { tableName: "TARIFA_IVA" }
    );

    m.Telefono = sequelize.define(
        "Telefono",
        {
            idTelefono: { type: DataTypes.INTEGER, field: "ID_TELEFONO", primaryKey: true, autoIncrement: true },
            idCliente: { type: DataTypes.INTEGER, field: "ID_CLIENTE", allowNull: false },
            numero: { type: DataTypes.STRING(15), field: "TEL_NUMERO", allowNull: false },
            tipo: { type: DataTypes.STRING(5), field: "TEL_TIPO" },
        },
        { tableName: "TELEFONO" }
    );

    m.TipoComprobante = sequelize.define(
        "TipoComprobante",
        {
            idTipoComprobante: { type: DataTypes.CHAR(2), field: "ID_TIPO_COMPROBANTE", primaryKey: true, allowNull: false },
            nombre: { type: DataTypes.STRING(50), field: "TCO_NOMBRE", allowNull: false },
            enVenta: { type: DataTypes.INTEGER, field: "TCO_EN_VENTA" },
            enCompra: { type: DataTypes.INTEGER, field: "TCO_EN_COMPRA" },
            desglosaIva: { type: DataTypes.INTEGER, field: "TCO_DESGLOSA_IVA" },
            electronicoSri: { type: DataTypes.INTEGER, field: "TCO_ELECTRONICO_SRI" },
        },
        { tableName: "TIPO_COMPROBANTE" }
    );

    m.TipoIdentificacion = sequelize.define(
        "TipoIdentificacion",
        {
            idTipoIdentificacion: { type: DataTypes.CHAR(2), field: "ID_TIPO_IDENTIFICACION", primaryKey: true, allowNull: false },
            nombre: { type: DataTypes.STRING(40), field: "TID_NOMBRE", allowNull: false },
        },
        { tableName: "TIPO_IDENTIFICACION" }
    );

    m.TipoMovimiento = sequelize.define(
        "TipoMovimiento",
        {
            idTipoMovimiento: { type: DataTypes.CHAR(3), field: "ID_TIPO_MOVIMIENTO", primaryKey: true, allowNull: false },
            nombre: { type: DataTypes.STRING(40), field: "TMV_NOMBRE", allowNull: false },
            signo: { type: DataTypes.INTEGER, field: "TMV_SIGNO", allowNull: false },
        },
        { tableName: "TIPO_MOVIMIENTO" }
    );

    m.Transportista = sequelize.define(
        "Transportista",
        {
            idTransportista: { type: DataTypes.INTEGER, field: "ID_TRANSPORTISTA", primaryKey: true, autoIncrement: true },
            nombre: { type: DataTypes.STRING(60), field: "TRA_NOMBRE", allowNull: false },
            telefono: { type: DataTypes.STRING(15), field: "TRA_TELEFONO" },
            urlRastreo: { type: DataTypes.STRING(200), field: "TRA_URL_RASTREO" },
        },
        { tableName: "TRANSPORTISTA" }
    );

    m.UnidadMedida = sequelize.define(
        "UnidadMedida",
        {
            idUnidadMedida: { type: DataTypes.STRING(4), field: "ID_UNIDAD_MEDIDA", primaryKey: true, allowNull: false },
            nombre: { type: DataTypes.STRING(30), field: "UMD_NOMBRE", allowNull: false },
        },
        { tableName: "UNIDAD_MEDIDA" }
    );

    m.Usuario = sequelize.define(
        "Usuario",
        {
            idUsuario: { type: DataTypes.INTEGER, field: "ID_USUARIO", primaryKey: true, autoIncrement: true },
            correo: { type: DataTypes.STRING(120), field: "USU_CORREO", allowNull: false },
            hashClave: { type: DataTypes.STRING(255), field: "USU_HASH_CLAVE", allowNull: false },
            activo: { type: DataTypes.INTEGER, field: "USU_ACTIVO" },
            creado: { type: DataTypes.DATE, field: "USU_CREADO" },
            ultimoAcceso: { type: DataTypes.DATE, field: "USU_ULTIMO_ACCESO" },
        },
        { tableName: "USUARIO" }
    );

    m.UsuarioRol = sequelize.define(
        "UsuarioRol",
        {
            idUsuario: { type: DataTypes.INTEGER, field: "ID_USUARIO", primaryKey: true, allowNull: false },
            idRol: { type: DataTypes.INTEGER, field: "ID_ROL", primaryKey: true, allowNull: false },
        },
        { tableName: "USUARIO_ROL" }
    );

    m.ValorAtributo = sequelize.define(
        "ValorAtributo",
        {
            idValorAtributo: { type: DataTypes.INTEGER, field: "ID_VALOR_ATRIBUTO", primaryKey: true, autoIncrement: true },
            idAtributo: { type: DataTypes.INTEGER, field: "ID_ATRIBUTO", allowNull: false },
            valor: { type: DataTypes.STRING(60), field: "VAL_VALOR", allowNull: false },
        },
        { tableName: "VALOR_ATRIBUTO" }
    );

    m.Variante = sequelize.define(
        "Variante",
        {
            idVariante: { type: DataTypes.INTEGER, field: "ID_VARIANTE", primaryKey: true, autoIncrement: true },
            idProducto: { type: DataTypes.INTEGER, field: "ID_PRODUCTO", allowNull: false },
            sku: { type: DataTypes.STRING(30), field: "VAR_SKU", allowNull: false },
            stockMinimo: { type: DataTypes.DECIMAL(12, 3), field: "VAR_STOCK_MINIMO", get() { const v = this.getDataValue("stockMinimo"); return v == null ? null : Number(v); } },
            activa: { type: DataTypes.INTEGER, field: "VAR_ACTIVA" },
        },
        { tableName: "VARIANTE" }
    );

    m.VarianteValor = sequelize.define(
        "VarianteValor",
        {
            idVariante: { type: DataTypes.INTEGER, field: "ID_VARIANTE", primaryKey: true, allowNull: false },
            idAtributo: { type: DataTypes.INTEGER, field: "ID_ATRIBUTO", primaryKey: true, allowNull: false },
            idValorAtributo: { type: DataTypes.INTEGER, field: "ID_VALOR_ATRIBUTO", allowNull: false },
        },
        { tableName: "VARIANTE_VALOR" }
    );

    return m;
}
