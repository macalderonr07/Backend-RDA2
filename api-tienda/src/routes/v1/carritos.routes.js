// src/routes/v1/carritos.routes.js
// Montado en /api/v1/carritos. Las lineas son un sub-recurso del carrito:
//   POST   /                              crea un carrito vacio (201 + token)
//   GET    /:token                        carrito con lineas, precios y total
//   DELETE /:token                        elimina el carrito (204)
//   POST   /:token/items                  agrega o suma una linea (201)
//   PUT    /:token/items                  reemplaza todas las lineas (200)
//   PATCH  /:token/items/:idPresentacion  cambia la cantidad (200)
//   DELETE /:token/items/:idPresentacion  quita una linea (204)
//   POST   /:token/combos                 agrega un combo {codigo, color, cantidad} como sus lineas (201)
// Checkout (el pedido nace del carrito, por eso es sub-recurso del token):
//   POST   /:token/cliente                identifica al cliente invitado (200)
//   POST   /:token/pedido                 confirma el carrito como pedido WEB (201)
//   GET    /:token/pedido                 estado y total actuales del pedido (200)
import { Router } from "express";
import { reglasNuevoCombo } from "../../middlewares/validarCombo.js";
import {
    agregar,
    agregarCombo,
    cambiarCantidad,
    crear,
    eliminar,
    obtener,
    quitarItem,
    reemplazar,
} from "../../controllers/carritos.controller.js";
import { confirmar, identificar, obtenerPedido } from "../../controllers/pedidos.controller.js";
import { manejarValidacion } from "../../middlewares/validacion.js";
import {
    reglasCantidad,
    reglasIdPresentacionParam,
    reglasNuevoItem,
    reglasPedidoNuevo,
    reglasReemplazoItems,
    reglasToken,
} from "../../middlewares/validarCarrito.js";
import { camposPersona } from "../../middlewares/validarCliente.js";

const router = Router();

router.post("/", crear);
router.get("/:token", reglasToken, manejarValidacion, obtener);
router.delete("/:token", reglasToken, manejarValidacion, eliminar);

router.post("/:token/items", reglasToken, reglasNuevoItem, manejarValidacion, agregar);
router.put("/:token/items", reglasToken, reglasReemplazoItems, manejarValidacion, reemplazar);
router.patch(
    "/:token/items/:idPresentacion",
    reglasToken,
    reglasIdPresentacionParam,
    reglasCantidad,
    manejarValidacion,
    cambiarCantidad
);
router.delete("/:token/items/:idPresentacion", reglasToken, reglasIdPresentacionParam, manejarValidacion, quitarItem);
router.post("/:token/combos", reglasToken, reglasNuevoCombo, manejarValidacion, agregarCombo);

router.post("/:token/cliente", reglasToken, camposPersona, manejarValidacion, identificar);
router.post("/:token/pedido", reglasToken, reglasPedidoNuevo, manejarValidacion, confirmar);
router.get("/:token/pedido", reglasToken, manejarValidacion, obtenerPedido);

export default router;
