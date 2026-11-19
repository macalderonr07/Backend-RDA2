// src/server.js
// Punto de entrada: levanta el servidor HTTP en el puerto configurado.
import { app } from "./app.js";

const PORT = process.env.PORT || 5050;

app.listen(PORT, () => {
    console.log(`API de Productos escuchando en http://localhost:${PORT}`);
});
