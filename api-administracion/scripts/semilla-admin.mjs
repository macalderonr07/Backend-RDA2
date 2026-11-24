// scripts/semilla-admin.mjs — primer usuario ADMINISTRADOR (npm run semilla)
//
// Crea (o actualiza) el usuario de ADMIN_CORREO con la clave ADMIN_CLAVE del
// .env, le asigna el rol ADMIN y su ficha de empleado (un vendedor necesita
// ser empleado para registrar ventas). La clave solo se guarda como hash
// scrypt; nunca se imprime. Se puede correr mas de una vez.
import { conUsuario, consulta, sequelize } from "../src/config/db.js";
import { m } from "../src/models/index.js";
import { crearHashClave } from "../src/utils/clave.js";
import { cedulaValida, PATRONES, regex } from "../src/utils/patrones.js";

const correo = (process.env.ADMIN_CORREO ?? "").trim().toLowerCase();
const clave = process.env.ADMIN_CLAVE ?? "";
if (!regex("correo").test(correo)) throw new Error("ADMIN_CORREO no es un correo valido");
if (!regex("clave").test(clave)) throw new Error(`ADMIN_CLAVE: ${PATRONES.clave.mensaje}`);

// Cedula de ejemplo con digito verificador valido (provincia 17, Pichincha) y
// que no tenga otro empleado (se puede sembrar mas de un administrador)
const usadas = new Set((await consulta("SELECT epl_identificacion AS i FROM produccion.empleado")).map((x) => x.i));
let cedula = null;
for (let k = 0; !cedula && k < 500; k++) {
    const base = String(171234567 + k);
    cedula = [...Array(10).keys()].map((d) => base + d).find((c) => cedulaValida(c) && !usadas.has(c)) ?? null;
}

const [sistema] = await consulta("SELECT id_usuario FROM produccion.usuario WHERE usu_correo = :c", {
    c: "sistema@comercialelite.local",
});

const resultado = await conUsuario(sistema.id_usuario, async (transaction) => {
    const hashClave = await crearHashClave(clave);
    let usuario = await m.Usuario.findOne({ where: { correo }, transaction });
    if (usuario) {
        await usuario.update({ hashClave, activo: 1 }, { transaction });
    } else {
        usuario = await m.Usuario.create({ correo, hashClave }, { transaction });
    }
    const admin = await m.Rol.findOne({ where: { codigo: "ADMIN" }, transaction });
    await m.UsuarioRol.findOrCreate({ where: { idUsuario: usuario.idUsuario, idRol: admin.idRol }, transaction });
    const [, empleadoNuevo] = await m.Empleado.findOrCreate({
        where: { idUsuario: usuario.idUsuario },
        defaults: {
            idTipoIdentificacion: "05",
            identificacion: cedula,
            nombres: "Administración",
            apellidos: "Comercial Elite",
            fechaIngreso: new Date(),
        },
        transaction,
    });
    return { idUsuario: usuario.idUsuario, empleadoNuevo };
});

console.log(`Usuario ${correo} (id ${resultado.idUsuario}) listo con rol ADMIN` +
    (resultado.empleadoNuevo ? " y ficha de empleado." : "."));
console.log("La clave es la de ADMIN_CLAVE en el .env (no se muestra).");
await sequelize.close();
