-- ══════════════════════════════════════════════════════════════════════════════
--  00_extensions.sql
--  Extensiones de PostgreSQL requeridas por el sistema.
--  Ejecutar PRIMERO, antes que cualquier otro archivo SQL.
--
--  Extensiones:
--    · pg_trgm    → búsqueda difusa por trigramas; habilita índices GIN sobre
--                   columnas de texto para LIKE/ILIKE y similitud (similarity())
--    · postgis    → tipo GEOGRAPHY y funciones espaciales (ST_Distance, etc.)
--    · btree_gist → permite EXCLUDE USING btree, necesario para la constraint
--                   de unicidad condicional de la sucursal principal en branches
-- ══════════════════════════════════════════════════════════════════════════════

CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS btree_gist;


-- ── fn_set_updated_at ─────────────────────────────────────────────────────────
-- Trigger BEFORE UPDATE reutilizable que estampa now() en updated_at.
-- Se adjunta como trigger en todas las tablas que exponen ese campo.
CREATE OR REPLACE FUNCTION fn_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

