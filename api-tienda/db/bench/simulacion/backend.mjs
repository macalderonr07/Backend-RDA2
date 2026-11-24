// backend.mjs — backend de prueba (node:http, como la API real pero minimo).
// Las mismas dos consultas de la tienda (ficha de producto y pagina de una
// categoria) por tres caminos:
//   /anterior/...    Oracle con la vista de stock de antes de la migracion 16
//   /optimizada/...  Oracle con la vista optimizada + indices
//   /cache/...       Redis (copia de lectura); si falta, Oracle optimizada
import { createServer } from "node:http";
import { categoriaCache, categoriaOracle, oracle, productoCache, productoOracle, redis } from "./comun.mjs";

await oracle();
await redis();

const responder = (res, estado, cuerpo) => {
    const json = JSON.stringify(cuerpo);
    res.writeHead(estado, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(json) });
    res.end(json);
};

createServer(async (req, res) => {
    const partes = new URL(req.url, "http://x").pathname.split("/").filter(Boolean);
    const [camino, recurso, valor, pagina = "1"] = partes;
    try {
        if (recurso === "producto") {
            if (camino === "cache") {
                const { doc } = await productoCache(valor);
                return doc ? responder(res, 200, doc) : responder(res, 404, { error: "no existe" });
            }
            const doc = await productoOracle(camino, valor);
            return doc ? responder(res, 200, doc) : responder(res, 404, { error: "no existe" });
        }
        if (recurso === "categoria") {
            const docs = camino === "cache" ? await categoriaCache(Number(valor), Number(pagina)) : await categoriaOracle(camino, Number(valor), Number(pagina));
            return responder(res, 200, docs);
        }
        responder(res, 404, { error: "ruta" });
    } catch (e) {
        responder(res, 500, { error: e.message });
    }
}).listen(Number(process.env.PUERTO ?? 7070), () => console.log(`backend de simulacion en :${process.env.PUERTO ?? 7070}`));
