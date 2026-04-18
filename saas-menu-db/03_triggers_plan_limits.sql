-- ══════════════════════════════════════════════════════════════════════════════
--  03_triggers_plan_limits.sql
--  Funciones de verificación de límites de plan y triggers BEFORE INSERT
--  que los aplican a nivel de base de datos.
--
--  Doble seguro: la app también debe verificar antes de insertar.
--  Si el límite se supera igual, la DB rechaza el INSERT con un mensaje claro.
--
--  Recursos controlados:
--    · banners    (max_banners del plan)
--    · combos     (max_combos del plan)
--    · promotions (max_promotions del plan)
--    · branches   (max_branches del plan, por restaurante)
--
--  Ejecutar después de 01_tables.sql.
-- ══════════════════════════════════════════════════════════════════════════════


-- ── Función: límite de recursos por sucursal ──────────────────────────────────
-- Retorna TRUE si aún se puede crear el recurso dado en la branch.
-- p_resource: 'banners' | 'combos' | 'promotions' | 'products' | 'categories'
-- Para branches usar restaurant_within_branch_limit() más abajo.
--
-- Uso: SELECT branch_within_plan_limit('branch-uuid', 'combos');
CREATE OR REPLACE FUNCTION branch_within_plan_limit(
  p_branch_id UUID,
  p_resource  TEXT
)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_plan_limit    INTEGER;
  v_current_count INTEGER;
  v_restaurant_id UUID;
BEGIN
  SELECT b.restaurant_id INTO v_restaurant_id
  FROM branches b WHERE b.id = p_branch_id;

  -- Obtener el límite del plan del restaurante
  EXECUTE format(
    'SELECT p.max_%I FROM plans p
     JOIN restaurants r ON r.plan_id = p.id
     WHERE r.id = $1',
    p_resource
  ) INTO v_plan_limit USING v_restaurant_id;

  -- NULL = plan sin límite para este recurso
  IF v_plan_limit IS NULL THEN
    RETURN true;
  END IF;

  -- Contar recursos actuales en la branch
  EXECUTE format(
    'SELECT COUNT(*) FROM %I WHERE branch_id = $1',
    p_resource
  ) INTO v_current_count USING p_branch_id;

  RETURN v_current_count < v_plan_limit;
END;
$$;


-- ── Función: límite de sucursales por restaurante ─────────────────────────────
-- Uso: SELECT restaurant_within_branch_limit('restaurant-uuid');
CREATE OR REPLACE FUNCTION restaurant_within_branch_limit(p_restaurant_id UUID)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_plan_limit    INTEGER;
  v_current_count INTEGER;
BEGIN
  SELECT p.max_branches INTO v_plan_limit
  FROM plans p
  JOIN restaurants r ON r.plan_id = p.id
  WHERE r.id = p_restaurant_id;

  IF v_plan_limit IS NULL THEN RETURN true; END IF;

  SELECT COUNT(*) INTO v_current_count
  FROM branches
  WHERE restaurant_id = p_restaurant_id AND is_active = true;

  RETURN v_current_count < v_plan_limit;
END;
$$;


-- ── Trigger: límite de banners ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_check_banner_limit()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NOT branch_within_plan_limit(NEW.branch_id, 'banners') THEN
    RAISE EXCEPTION 'PLAN_LIMIT_EXCEEDED: Has alcanzado el límite de banners de tu plan actual. Actualiza tu plan para añadir más.';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_banner_limit
  BEFORE INSERT ON banners
  FOR EACH ROW EXECUTE FUNCTION fn_check_banner_limit();


-- ── Trigger: límite de combos ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_check_combo_limit()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NOT branch_within_plan_limit(NEW.branch_id, 'combos') THEN
    RAISE EXCEPTION 'PLAN_LIMIT_EXCEEDED: Has alcanzado el límite de combos de tu plan actual. Actualiza tu plan para añadir más.';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_combo_limit
  BEFORE INSERT ON combos
  FOR EACH ROW EXECUTE FUNCTION fn_check_combo_limit();


-- ── Trigger: límite de promociones ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_check_promotion_limit()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NOT branch_within_plan_limit(NEW.branch_id, 'promotions') THEN
    RAISE EXCEPTION 'PLAN_LIMIT_EXCEEDED: Has alcanzado el límite de promociones de tu plan actual. Actualiza tu plan para añadir más.';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_promotion_limit
  BEFORE INSERT ON promotions
  FOR EACH ROW EXECUTE FUNCTION fn_check_promotion_limit();


-- ── Trigger: límite de sucursales ─────────────────────────────────────────────
-- NOTA: este trigger también se dispara cuando fn_bootstrap_restaurant crea
-- la sucursal principal. No es un falso positivo porque el conteo se hace
-- ANTES del INSERT actual (0 branches existentes → 0 < max_branches → pasa).
CREATE OR REPLACE FUNCTION fn_check_branch_limit()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NOT restaurant_within_branch_limit(NEW.restaurant_id) THEN
    RAISE EXCEPTION 'PLAN_LIMIT_EXCEEDED: Has alcanzado el límite de sucursales de tu plan actual. Actualiza tu plan para añadir más.';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_branch_limit
  BEFORE INSERT ON branches
  FOR EACH ROW EXECUTE FUNCTION fn_check_branch_limit();
