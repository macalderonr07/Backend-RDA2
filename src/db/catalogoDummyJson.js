// src/db/catalogoDummyJson.js
// Obtiene un catalogo REAL de productos (nombre, descripcion, pvp, stock e
// imagen) desde la API publica de DummyJSON: https://dummyjson.com/docs/products
// Asi cada imagen corresponde de verdad al producto (la foto de "Apple Airpods"
// es de unos AirPods), cosa que no se logra pegando una imagen aleatoria a un
// nombre sintetico.
const URL_CATALOGO =
    "https://dummyjson.com/products?limit=0&select=title,description,category,price,stock,thumbnail";
const TIMEOUT_MS = 10_000;

// DummyJSON usa slugs en ingles; los traducimos a las categorias en espanol
// que ya usa la API (y que filtra el indice idx_productos_categoria).
const CATEGORIAS = {
    beauty: "Belleza",
    fragrances: "Belleza",
    "skin-care": "Belleza",
    furniture: "Hogar",
    "home-decoration": "Hogar",
    "kitchen-accessories": "Hogar",
    groceries: "Alimentos",
    laptops: "Electronica",
    smartphones: "Electronica",
    tablets: "Electronica",
    "mobile-accessories": "Electronica",
    "mens-shirts": "Ropa",
    "mens-shoes": "Ropa",
    "womens-dresses": "Ropa",
    "womens-shoes": "Ropa",
    tops: "Ropa",
    "mens-watches": "Accesorios",
    "womens-watches": "Accesorios",
    "womens-bags": "Accesorios",
    "womens-jewellery": "Accesorios",
    sunglasses: "Accesorios",
    "sports-accessories": "Deportes",
    motorcycle: "Vehiculos",
    vehicle: "Vehiculos",
};

// Devuelve la URL normalizada (new URL escapa espacios/acentos) o null si no
// es http/https valida.
function urlHttpONull(valor) {
    try {
        const url = new URL(valor);
        return url.protocol === "https:" || url.protocol === "http:" ? url.href : null;
    } catch {
        return null;
    }
}

// La respuesta viene de un tercero: se valida cada campo en vez de confiar
// en ella, y se descarta lo que no cumpla las restricciones de la tabla.
function normalizar(p) {
    if (typeof p?.title !== "string" || !p.title.trim()) return null;
    if (!Number.isFinite(p.price) || p.price < 0) return null;

    const imagen = typeof p.thumbnail === "string" ? urlHttpONull(p.thumbnail) : null;
    return {
        nombre: p.title.trim().slice(0, 140), // deja lugar al sufijo " #NNNN"
        descripcion: typeof p.description === "string" ? p.description.slice(0, 2000) : null,
        categoria: CATEGORIAS[p.category] ?? "Otros",
        pvp: Number(p.price.toFixed(2)),
        stock: Number.isInteger(p.stock) && p.stock >= 0 ? p.stock : 0,
        url_imagen: imagen && imagen.length <= 500 ? imagen : null,
    };
}

/**
 * Descarga el catalogo real y lo expande a `cantidad` filas. DummyJSON trae
 * ~194 productos; para llegar a 1000 se repiten con un numero de serie en el
 * nombre (igual que el generador sintetico) y la MISMA imagen del original.
 */
export async function obtenerCatalogoReal(cantidad = 1000) {
    const respuesta = await fetch(URL_CATALOGO, { signal: AbortSignal.timeout(TIMEOUT_MS) });
    if (!respuesta.ok) {
        throw new Error(`DummyJSON respondio HTTP ${respuesta.status}`);
    }
    const cuerpo = await respuesta.json();
    const base = (Array.isArray(cuerpo?.products) ? cuerpo.products : []).map(normalizar).filter(Boolean);
    if (base.length === 0) {
        throw new Error("DummyJSON no devolvio productos validos");
    }

    return Array.from({ length: cantidad }, (_, i) => {
        const p = base[i % base.length];
        return { ...p, nombre: `${p.nombre} #${i + 1}` };
    });
}
