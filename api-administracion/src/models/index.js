// src/models/index.js
// Capa ORM: los modelos de Sequelize (generados del diccionario de datos, ver
// tablas.generado.js) y sus ASOCIACIONES, que son lo que da significado al
// modelo y se escriben a mano. Solo los Repository (src/repositories) usan
// estos modelos: ni controladores ni rutas los conocen (ARQUITECTURA.md 1.2).
import { sequelize } from "../config/db.js";
import { definirTablas } from "./tablas.generado.js";

export const m = definirTablas(sequelize);

// ---- Geografia y empresa
m.Provincia.hasMany(m.Ciudad, { foreignKey: "idProvincia", as: "ciudades" });
m.Ciudad.belongsTo(m.Provincia, { foreignKey: "idProvincia", as: "provincia" });
m.Direccion.belongsTo(m.Ciudad, { foreignKey: "idCiudad", as: "ciudad" });
m.Empresa.belongsTo(m.Direccion, { foreignKey: "idDireccionMatriz", as: "direccionMatriz" });

// ---- Seguridad: usuarios, roles y permisos (los permisos los exige la base)
m.Usuario.belongsToMany(m.Rol, { through: m.UsuarioRol, foreignKey: "idUsuario", otherKey: "idRol", as: "roles" });
m.Rol.belongsToMany(m.Usuario, { through: m.UsuarioRol, foreignKey: "idRol", otherKey: "idUsuario", as: "usuarios" });
m.Rol.belongsToMany(m.Permiso, { through: m.RolPermiso, foreignKey: "idRol", otherKey: "idPermiso", as: "permisos" });
m.Permiso.belongsToMany(m.Rol, { through: m.RolPermiso, foreignKey: "idPermiso", otherKey: "idRol", as: "roles" });

// ---- Talento humano: el empleado ES un usuario (misma clave)
m.Usuario.hasOne(m.Empleado, { foreignKey: "idUsuario", as: "empleado" });
m.Empleado.belongsTo(m.Usuario, { foreignKey: "idUsuario", as: "usuario" });
m.Empleado.belongsTo(m.TipoIdentificacion, { foreignKey: "idTipoIdentificacion", as: "tipoIdentificacion" });

// ---- Catalogo de productos
m.Categoria.belongsTo(m.Categoria, { foreignKey: "idCategoriaPadre", as: "padre" });
m.Categoria.hasMany(m.Categoria, { foreignKey: "idCategoriaPadre", as: "hijas" });
m.Categoria.belongsToMany(m.Atributo, {
    through: m.CategoriaAtributo,
    foreignKey: "idCategoria",
    otherKey: "idAtributo",
    as: "atributos",
});
m.Atributo.hasMany(m.ValorAtributo, { foreignKey: "idAtributo", as: "valores" });
m.ValorAtributo.belongsTo(m.Atributo, { foreignKey: "idAtributo", as: "atributo" });

m.Producto.belongsTo(m.Categoria, { foreignKey: "idCategoria", as: "categoria" });
m.Producto.belongsTo(m.UnidadMedida, { foreignKey: "idUnidadMedida", as: "unidad" });
m.Producto.belongsTo(m.TarifaIva, { foreignKey: "idTarifaIva", as: "tarifaIva" });
m.Producto.belongsTo(m.Marca, { foreignKey: "idMarca", as: "marca" });
m.Producto.hasMany(m.Variante, { foreignKey: "idProducto", as: "variantes" });
m.Variante.belongsTo(m.Producto, { foreignKey: "idProducto", as: "producto" });
m.Variante.hasMany(m.Presentacion, { foreignKey: "idVariante", as: "presentaciones" });
m.Variante.hasMany(m.VarianteValor, { foreignKey: "idVariante", as: "valores" });
m.VarianteValor.belongsTo(m.ValorAtributo, { foreignKey: "idValorAtributo", as: "valor" });
m.VarianteValor.belongsTo(m.Atributo, { foreignKey: "idAtributo", as: "atributo" });
m.Presentacion.belongsTo(m.Variante, { foreignKey: "idVariante", as: "variante" });
m.Presentacion.hasMany(m.HistorialPrecio, { foreignKey: "idPresentacion", as: "precios" });

m.Oferta.belongsTo(m.Producto, { foreignKey: "idProducto", as: "producto" });
m.DescuentoVolumen.belongsTo(m.Producto, { foreignKey: "idProducto", as: "producto" });
m.Combo.hasMany(m.ComboComponente, { foreignKey: "idCombo", as: "componentes" });
m.ComboComponente.belongsTo(m.Producto, { foreignKey: "idProducto", as: "producto" });

// ---- Compras
m.Proveedor.belongsTo(m.TipoIdentificacion, { foreignKey: "idTipoIdentificacion", as: "tipoIdentificacion" });
m.OrdenCompra.belongsTo(m.Proveedor, { foreignKey: "idProveedor", as: "proveedor" });
m.OrdenCompra.hasMany(m.DetalleOrdenCompra, { foreignKey: "idOrdenCompra", as: "detalle" });
m.DetalleOrdenCompra.belongsTo(m.Variante, { foreignKey: "idVariante", as: "variante" });
m.ComprobanteCompra.belongsTo(m.Proveedor, { foreignKey: "idProveedor", as: "proveedor" });

// ---- Ventas y clientes
m.Cliente.hasMany(m.Telefono, { foreignKey: "idCliente", as: "telefonos" });
m.Cliente.hasMany(m.Direccion, { foreignKey: "idCliente", as: "direcciones" });
m.Cliente.hasMany(m.DatosFacturacion, { foreignKey: "idCliente", as: "datosFacturacion" });
m.DatosFacturacion.belongsTo(m.TipoIdentificacion, { foreignKey: "idTipoIdentificacion", as: "tipoIdentificacion" });
m.Pedido.belongsTo(m.Cliente, { foreignKey: "idCliente", as: "cliente" });
m.Pedido.belongsTo(m.CanalVenta, { foreignKey: "idCanalVenta", as: "canal" });
m.Pedido.hasMany(m.DetallePedido, { foreignKey: "idPedido", as: "lineas" });
m.Pedido.hasMany(m.Pago, { foreignKey: "idPedido", as: "pagos" });
m.Pedido.hasMany(m.HistorialEstadoPedido, { foreignKey: "idPedido", as: "historial" });
m.DetallePedido.belongsTo(m.Presentacion, { foreignKey: "idPresentacion", as: "presentacion" });
m.Pago.belongsTo(m.MetodoPago, { foreignKey: "idMetodoPago", as: "metodo" });
m.HistorialEstadoPedido.belongsTo(m.EstadoPedido, { foreignKey: "idEstadoPedido", as: "estado" });

// ---- Inventario
m.Lote.belongsTo(m.Variante, { foreignKey: "idVariante", as: "variante" });
m.MovimientoInventario.belongsTo(m.TipoMovimiento, { foreignKey: "idTipoMovimiento", as: "tipo" });
m.MovimientoInventario.hasMany(m.DetalleMovimiento, { foreignKey: "idMovimiento", as: "detalle" });
