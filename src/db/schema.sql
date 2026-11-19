-- src/db/schema.sql
-- Tabla productos: PK serial, restricciones de dominio a nivel de BD
-- (pvp/stock no negativos) como segunda linea de defensa ademas de la
-- validacion en la capa HTTP.
CREATE TABLE IF NOT EXISTS productos (
    id SERIAL PRIMARY KEY,
    nombre VARCHAR(150) NOT NULL,
    descripcion TEXT,
    categoria VARCHAR(80) NOT NULL,
    pvp NUMERIC(10, 2) NOT NULL CHECK (pvp >= 0),
    stock INTEGER NOT NULL DEFAULT 0 CHECK (stock >= 0),
    creado_en TIMESTAMPTZ NOT NULL DEFAULT now(),
    actualizado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_productos_categoria ON productos (categoria);

-- url_imagen: URL publica de la imagen del producto (VARCHAR, no se guarda el
-- binario en la BD). Se agrega con ALTER ... IF NOT EXISTS para que el script
-- sea idempotente y migre tambien bases creadas antes de esta columna.
-- El CHECK limita el esquema a http/https (bloquea javascript:, data:, etc.)
-- como segunda barrera ademas de la validacion en la capa HTTP.
ALTER TABLE productos ADD COLUMN IF NOT EXISTS url_imagen VARCHAR(500);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'productos_url_imagen_check'
    ) THEN
        ALTER TABLE productos
            ADD CONSTRAINT productos_url_imagen_check CHECK (url_imagen ~* '^https?://');
    END IF;
END $$;
