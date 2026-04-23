

-- ══════════════════════════════════════════════════════════════════════════════
--  03_triggers_plan_limits.sql
--  Funciones de verificación de límites de plan y triggers BEFORE INSERT.
--  Ejecutar después de 01_tables.sql.
--
--  Todos los límites se aplican POR SUCURSAL, excepto max_branches que aplica
--  POR RESTAURANTE. Esto significa que si un plan permite 100 productos, cada
--  sucursal puede tener hasta 100 productos de forma independiente.
--
--  Recursos controlados:
--    · branches    → máx. por restaurante (max_branches del plan)
--    · products    → máx. por sucursal    (max_products del plan)
--    · categories  → máx. por sucursal    (max_categories del plan)
--    · banners     → máx. por sucursal    (max_banners del plan)
--    · combos      → máx. por sucursal    (max_combos del plan)
--    · promotions  → máx. por sucursal    (max_promotions del plan)
--
--  Doble seguro: la aplicación DEBE verificar límites antes del INSERT para
--  dar feedback inmediato al usuario. Si la app omite esa verificación, la BD
--  rechaza el INSERT con una excepción prefijada con 'PLAN_LIMIT_EXCEEDED:'
--  para que la app pueda capturarla e interpretarla apropiadamente.
-- ══════════════════════════════════════════════════════════════════════════════


-- ── fn_get_branch_from_menu ───────────────────────────────────────────────────
-- Resuelve el branch_id a partir de un menu_id.
-- Usada por el trigger de categories para identificar la sucursal del menú
-- donde se creará la categoría.
CREATE OR REPLACE FUNCTION fn_get_branch_from_menu(p_menu_id UUID)
RETURNS UUID LANGUAGE sql STABLE AS $$
  SELECT branch_id FROM menus WHERE id = p_menu_id;
$$;


-- ══════════════════════════════════════════════════════════════════════════════
-- FUNCIONES DE VERIFICACIÓN DE LÍMITES
-- Retornan TRUE si hay capacidad disponible; FALSE si se alcanzó el límite.
-- NULL en el campo de límite del plan significa recurso ilimitado → TRUE.
-- ══════════════════════════════════════════════════════════════════════════════


-- ── restaurant_within_branch_limit ────────────────────────────────────────────
-- Verifica si el restaurante puede crear una sucursal adicional sin superar
-- el límite de su plan. Cuenta solo sucursales activas (is_active = true).
-- Ejemplo: SELECT restaurant_within_branch_limit('restaurant-uuid');
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


-- ── branch_within_banner_limit ────────────────────────────────────────────────
-- Verifica si la sucursal puede agregar un banner sin superar el límite del plan.
-- Ejemplo: SELECT branch_within_banner_limit('branch-uuid');
CREATE OR REPLACE FUNCTION branch_within_banner_limit(p_branch_id UUID)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_plan_limit    INTEGER;
  v_current_count INTEGER;
BEGIN
  SELECT p.max_banners INTO v_plan_limit
  FROM plans p
  JOIN restaurants r ON r.plan_id = p.id
  JOIN branches b    ON b.restaurant_id = r.id
  WHERE b.id = p_branch_id;

  IF v_plan_limit IS NULL THEN RETURN true; END IF;

  SELECT COUNT(*) INTO v_current_count
  FROM banners WHERE branch_id = p_branch_id;

  RETURN v_current_count < v_plan_limit;
END;
$$;


-- ── branch_within_combo_limit ─────────────────────────────────────────────────
-- Verifica si la sucursal puede crear un combo sin superar el límite del plan.
-- Ejemplo: SELECT branch_within_combo_limit('branch-uuid');
CREATE OR REPLACE FUNCTION branch_within_combo_limit(p_branch_id UUID)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_plan_limit    INTEGER;
  v_current_count INTEGER;
BEGIN
  SELECT p.max_combos INTO v_plan_limit
  FROM plans p
  JOIN restaurants r ON r.plan_id = p.id
  JOIN branches b    ON b.restaurant_id = r.id
  WHERE b.id = p_branch_id;

  IF v_plan_limit IS NULL THEN RETURN true; END IF;

  SELECT COUNT(*) INTO v_current_count
  FROM combos WHERE branch_id = p_branch_id;

  RETURN v_current_count < v_plan_limit;
END;
$$;


-- ── branch_within_promotion_limit ─────────────────────────────────────────────
-- Verifica si la sucursal puede crear una promoción sin superar el límite del plan.
-- Ejemplo: SELECT branch_within_promotion_limit('branch-uuid');
CREATE OR REPLACE FUNCTION branch_within_promotion_limit(p_branch_id UUID)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_plan_limit    INTEGER;
  v_current_count INTEGER;
BEGIN
  SELECT p.max_promotions INTO v_plan_limit
  FROM plans p
  JOIN restaurants r ON r.plan_id = p.id
  JOIN branches b    ON b.restaurant_id = r.id
  WHERE b.id = p_branch_id;

  IF v_plan_limit IS NULL THEN RETURN true; END IF;

  SELECT COUNT(*) INTO v_current_count
  FROM promotions WHERE branch_id = p_branch_id;

  RETURN v_current_count < v_plan_limit;
END;
$$;


-- ── branch_within_product_limit ───────────────────────────────────────────────
-- Verifica si la sucursal puede agregar un producto sin superar el límite del plan.
-- Cuenta todos los productos de la sucursal mediante branch_id directo en products,
-- gracias a la desnormalización de branch_id en esa tabla.
-- Ejemplo: SELECT branch_within_product_limit('branch-uuid');
CREATE OR REPLACE FUNCTION branch_within_product_limit(p_branch_id UUID)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_plan_limit    INTEGER;
  v_current_count INTEGER;
BEGIN
  SELECT p.max_products INTO v_plan_limit
  FROM plans p
  JOIN restaurants r ON r.plan_id = p.id
  JOIN branches b    ON b.restaurant_id = r.id
  WHERE b.id = p_branch_id;

  IF v_plan_limit IS NULL THEN RETURN true; END IF;

  SELECT COUNT(*) INTO v_current_count
  FROM products WHERE branch_id = p_branch_id;

  RETURN v_current_count < v_plan_limit;
END;
$$;


-- ── branch_within_category_limit ──────────────────────────────────────────────
-- Verifica si la sucursal puede crear una categoría sin superar el límite del plan.
-- Cuenta todas las categorías de todos los menús de la sucursal (una sucursal
-- puede tener varios menús, el límite aplica sobre el total de categorías).
-- Ejemplo: SELECT branch_within_category_limit('branch-uuid');
CREATE OR REPLACE FUNCTION branch_within_category_limit(p_branch_id UUID)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_plan_limit    INTEGER;
  v_current_count INTEGER;
BEGIN
  SELECT p.max_categories INTO v_plan_limit
  FROM plans p
  JOIN restaurants r ON r.plan_id = p.id
  JOIN branches b    ON b.restaurant_id = r.id
  WHERE b.id = p_branch_id;

  IF v_plan_limit IS NULL THEN RETURN true; END IF;

  SELECT COUNT(*) INTO v_current_count
  FROM categories c
  JOIN menus m ON m.id = c.menu_id
  WHERE m.branch_id = p_branch_id;

  RETURN v_current_count < v_plan_limit;
END;
$$;


-- ══════════════════════════════════════════════════════════════════════════════
-- TRIGGERS DE CONTROL DE LÍMITES
-- Se ejecutan BEFORE INSERT en cada tabla controlada.
-- Al superar el límite lanzan EXCEPTION con prefijo 'PLAN_LIMIT_EXCEEDED:'
-- para que la aplicación pueda capturarlo y mostrar un mensaje apropiado.
-- ══════════════════════════════════════════════════════════════════════════════


-- ── trg_check_branch_limit ────────────────────────────────────────────────────
-- Impide crear una sucursal si el restaurante alcanzó el máximo de su plan.
-- La primera sucursal (bootstrap) siempre pasa porque el conteo es 0 antes
-- de cualquier INSERT en branches.
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


-- ── trg_check_banner_limit ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_check_banner_limit()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NOT branch_within_banner_limit(NEW.branch_id) THEN
    RAISE EXCEPTION 'PLAN_LIMIT_EXCEEDED: Has alcanzado el límite de banners de tu plan actual. Actualiza tu plan para añadir más.';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_banner_limit
  BEFORE INSERT ON banners
  FOR EACH ROW EXECUTE FUNCTION fn_check_banner_limit();


-- ── trg_check_combo_limit ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_check_combo_limit()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NOT branch_within_combo_limit(NEW.branch_id) THEN
    RAISE EXCEPTION 'PLAN_LIMIT_EXCEEDED: Has alcanzado el límite de combos de tu plan actual. Actualiza tu plan para añadir más.';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_combo_limit
  BEFORE INSERT ON combos
  FOR EACH ROW EXECUTE FUNCTION fn_check_combo_limit();


-- ── trg_check_promotion_limit ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_check_promotion_limit()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NOT branch_within_promotion_limit(NEW.branch_id) THEN
    RAISE EXCEPTION 'PLAN_LIMIT_EXCEEDED: Has alcanzado el límite de promociones de tu plan actual. Actualiza tu plan para añadir más.';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_promotion_limit
  BEFORE INSERT ON promotions
  FOR EACH ROW EXECUTE FUNCTION fn_check_promotion_limit();


-- ── trg_check_product_limit ───────────────────────────────────────────────────
-- El branch_id llega directamente en NEW, así que no necesita resolución
-- por jerarquía. Gracias a la desnormalización de branch_id en products,
-- este trigger es más simple y eficiente que la versión anterior.
CREATE OR REPLACE FUNCTION fn_check_product_limit()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NOT branch_within_product_limit(NEW.branch_id) THEN
    RAISE EXCEPTION 'PLAN_LIMIT_EXCEEDED: Has alcanzado el límite de productos de tu plan actual. Actualiza tu plan para añadir más.';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_product_limit
  BEFORE INSERT ON products
  FOR EACH ROW EXECUTE FUNCTION fn_check_product_limit();


-- ── trg_check_category_limit ──────────────────────────────────────────────────
-- Resuelve el branch_id a partir de NEW.menu_id usando fn_get_branch_from_menu.
CREATE OR REPLACE FUNCTION fn_check_category_limit()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_branch_id UUID;
BEGIN
  v_branch_id := fn_get_branch_from_menu(NEW.menu_id);

  IF v_branch_id IS NULL THEN
    RAISE EXCEPTION 'No se pudo determinar la sucursal de la categoría (menu_id inválido).';
  END IF;

  IF NOT branch_within_category_limit(v_branch_id) THEN
    RAISE EXCEPTION 'PLAN_LIMIT_EXCEEDED: Has alcanzado el límite de categorías de tu plan actual. Actualiza tu plan para añadir más.';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_category_limit
  BEFORE INSERT ON categories
  FOR EACH ROW EXECUTE FUNCTION fn_check_category_limit();


-- ── trg_set_product_branch_id ─────────────────────────────────────────────────
-- Garantiza la consistencia del campo desnormalizado branch_id en products.
-- Al insertar un producto, resuelve la sucursal correcta recorriendo la cadena
-- category → menu → branch y la estampa en NEW.branch_id, independientemente
-- del valor que haya enviado la aplicación.
-- De esta forma branch_id en products es siempre coherente con category_id,
-- sin depender de que la app calcule y envíe el branch_id correcto.
CREATE OR REPLACE FUNCTION fn_set_product_branch_id()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  SELECT m.branch_id INTO NEW.branch_id
  FROM categories c
  JOIN menus m ON m.id = c.menu_id
  WHERE c.id = NEW.category_id;

  IF NEW.branch_id IS NULL THEN
    RAISE EXCEPTION 'No se pudo resolver la sucursal para el producto (category_id inválido o sin menú asociado).';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_set_product_branch_id
  BEFORE INSERT ON products
  FOR EACH ROW EXECUTE FUNCTION fn_set_product_branch_id();

