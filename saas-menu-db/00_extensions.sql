-- ══════════════════════════════════════════════════════════════════════════════
--  00_extensions.sql
--  Extensiones de PostgreSQL y función utilitaria global.
--  Ejecutar PRIMERO antes que cualquier otro archivo.
-- ══════════════════════════════════════════════════════════════════════════════

CREATE EXTENSION IF NOT EXISTS pg_trgm;   -- Búsqueda de texto por trigramas (GIN)
CREATE EXTENSION IF NOT EXISTS postgis;   -- Tipos y funciones geoespaciales
CREATE EXTENSION IF NOT EXISTS btree_gist; -- Necesario para EXCLUDE en branches


-- ── Función global: updated_at automático ─────────────────────────────────────
-- Usada por todos los triggers de actualización de timestamp.
CREATE OR REPLACE FUNCTION fn_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;
