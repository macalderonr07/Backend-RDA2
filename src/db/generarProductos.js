// src/db/generarProductos.js
// Genera datos sinteticos sin depender de librerias externas (faker, etc.)
// para no atar el seed a disponibilidad de red. Es el PLAN B de init.js cuando
// la API real (catalogoDummyJson.js) no responde: estos productos no tienen
// foto real, asi que url_imagen queda en null en vez de inventar una.
const CATEGORIAS = [
    "Electronica",
    "Hogar",
    "Oficina",
    "Deportes",
    "Juguetes",
    "Ropa",
    "Alimentos",
    "Belleza",
    "Herramientas",
    "Mascotas",
];

const ADJETIVOS = [
    "Clasico",
    "Premium",
    "Compacto",
    "Profesional",
    "Portatil",
    "Ecologico",
    "Inteligente",
    "Resistente",
    "Ligero",
    "Multiuso",
];

const NOMBRES_BASE = [
    "Mouse",
    "Teclado",
    "Silla",
    "Mesa",
    "Lampara",
    "Mochila",
    "Audifonos",
    "Cuaderno",
    "Taza",
    "Botella",
    "Camiseta",
    "Zapatilla",
    "Cafetera",
    "Reloj",
    "Cargador",
    "Monitor",
    "Parlante",
    "Cepillo",
    "Correa",
    "Juego de mesa",
];

function elegir(lista, i) {
    return lista[i % lista.length];
}

/**
 * Genera `cantidad` productos deterministas (sin duplicar nombre),
 * combinando adjetivo + nombre base + categoria + numero de serie.
 */
export function generarProductos(cantidad = 1000) {
    const productos = [];
    for (let i = 0; i < cantidad; i++) {
        const adjetivo = elegir(ADJETIVOS, i);
        const base = elegir(NOMBRES_BASE, Math.floor(i / ADJETIVOS.length));
        const categoria = elegir(CATEGORIAS, i + Math.floor(i / 7));
        const nombre = `${base} ${adjetivo} #${i + 1}`;
        const pvp = Number((5 + ((i * 37) % 4950) / 100).toFixed(2));
        const stock = (i * 13) % 500;
        const descripcion = `${base} de categoria ${categoria.toLowerCase()}, estilo ${adjetivo.toLowerCase()}.`;

        productos.push({ nombre, descripcion, categoria, pvp, stock, url_imagen: null });
    }
    return productos;
}
