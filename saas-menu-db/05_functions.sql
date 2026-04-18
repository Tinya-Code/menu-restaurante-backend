-- ══════════════════════════════════════════════════════════════════════════════
--  05_functions.sql
--  Funciones de utilidad de la aplicación.
--
--  Funciones incluidas:
--    · get_effective_settings()  → config fusionada restaurant + branch
--    · get_branch_data()         → JSON completo de una sucursal para la app
--    · user_has_access()         → verificación de permisos
--    · fn_transfer_ownership()   → transferir restaurante a otro usuario
--    · fn_change_plan()          → cambiar plan con historial de downgrade
--    · fn_register_visit()       → registrar visita de comensal
--
--  Ejecutar después de 04_triggers_bootstrap.sql.
-- ══════════════════════════════════════════════════════════════════════════════


-- ── Configuración efectiva de una sucursal ────────────────────────────────────
-- Fusiona restaurant_settings con branch_settings.
-- Los campos de branch_settings sobreescriben los de restaurant_settings
-- usando el operador || de JSONB (merge superficial por campo).
-- TEXT: branch tiene precedencia si no es NULL (COALESCE).
--
-- Uso: SELECT * FROM get_effective_settings('branch-uuid');
CREATE OR REPLACE FUNCTION get_effective_settings(p_branch_id UUID)
RETURNS TABLE (
  whatsapp_config JSONB,
  display_config  JSONB,
  order_config    JSONB,
  business_config JSONB,
  logo_url        TEXT,
  description     TEXT,
  schedule        JSONB
)
LANGUAGE sql STABLE AS $$
  SELECT
    rs.whatsapp_config || bs.whatsapp_config  AS whatsapp_config,
    rs.display_config  || bs.display_config   AS display_config,
    rs.order_config    || bs.order_config     AS order_config,
    rs.business_config || bs.business_config  AS business_config,
    COALESCE(bs.logo_url,    rs.logo_url)     AS logo_url,
    COALESCE(bs.description, rs.description)  AS description,
    bs.schedule
  FROM branches b
  JOIN restaurant_settings rs ON rs.restaurant_id = b.restaurant_id
  JOIN branch_settings      bs ON bs.branch_id    = b.id
  WHERE b.id = p_branch_id;
$$;


-- ── JSON completo de una sucursal (para la app cliente) ───────────────────────
-- Devuelve un JSONB con toda la información necesaria para renderizar la sucursal:
-- branch, restaurant, settings (fusionadas), template, banners, combos,
-- promociones vigentes y menús (con categorías y productos).
--
-- Uso: SELECT get_branch_data('branch-uuid');
CREATE OR REPLACE FUNCTION get_branch_data(p_branch_id UUID)
RETURNS JSONB LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'branch',     to_jsonb(b),
    'restaurant', to_jsonb(r),
    'settings',   (SELECT to_jsonb(s) FROM get_effective_settings(b.id) s),
    'template',   to_jsonb(t),

    'banners', (
      SELECT jsonb_agg(
        jsonb_build_object(
          'id',            bn.id,
          'image_url',     bn.image_url,
          'link_url',      bn.link_url,
          'description',   bn.description,
          'display_order', bn.display_order
        ) ORDER BY bn.display_order
      )
      FROM banners bn
      WHERE bn.branch_id = b.id AND bn.is_active = true
    ),

    'combos', (
      SELECT jsonb_agg(
        jsonb_build_object(
          'id',          co.id,
          'name',        co.name,
          'description', co.description,
          'price',       co.price,
          'image_url',   co.image_url,
          'products', (
            SELECT jsonb_agg(jsonb_build_object(
              'product_id', cp.product_id,
              'name',       p.name,
              'quantity',   cp.quantity,
              'price',      p.price
            ))
            FROM combo_products cp
            JOIN products p ON p.id = cp.product_id
            WHERE cp.combo_id = co.id
          )
        ) ORDER BY co.display_order
      )
      FROM combos co
      WHERE co.branch_id = b.id AND co.is_active = true
    ),

    'promotions', (
      SELECT jsonb_agg(jsonb_build_object(
        'id',             pr.id,
        'name',           pr.name,
        'description',    pr.description,
        'discount_type',  pr.discount_type,
        'discount_value', pr.discount_value,
        'applies_to',     pr.applies_to,
        'target_id',      pr.target_id,
        'start_date',     pr.start_date,
        'end_date',       pr.end_date
      ))
      FROM promotions pr
      WHERE pr.branch_id = b.id
        AND pr.is_active = true
        AND (pr.start_date IS NULL OR pr.start_date <= now())
        AND (pr.end_date   IS NULL OR pr.end_date   >= now())
    ),

    'menus', (
      SELECT jsonb_agg(
        jsonb_build_object(
          'menu', to_jsonb(m),
          'categories', (
            SELECT jsonb_agg(
              jsonb_build_object(
                'category', to_jsonb(c),
                'type',     ct.name,
                'products', (
                  SELECT jsonb_agg(to_jsonb(p) ORDER BY p.display_order)
                  FROM products p
                  WHERE p.category_id = c.id AND p.is_available = true
                )
              ) ORDER BY c.display_order
            )
            FROM categories c
            LEFT JOIN category_types ct ON ct.id = c.type_id
            WHERE c.menu_id = m.id AND c.is_active = true
          )
        ) ORDER BY m.display_order
      )
      FROM menus m
      WHERE m.branch_id = b.id AND m.is_active = true
    )
  )
  FROM branches b
  JOIN restaurants r ON r.id = b.restaurant_id
  LEFT JOIN templates t ON t.id = b.template_id
  WHERE b.id = p_branch_id;
$$;


-- ── Verificar acceso de un usuario a un restaurante ───────────────────────────
-- Combina roles globales (super_admin tiene acceso a todo) y roles locales.
--
-- Uso: SELECT user_has_access('user-uuid', 'restaurant-uuid', ARRAY['owner','admin']);
CREATE OR REPLACE FUNCTION user_has_access(
  p_user_id       UUID,
  p_restaurant_id UUID,
  p_roles         TEXT[]
)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    -- super_admin: acceso global sin importar el restaurante
    SELECT 1
    FROM user_global_roles ugr
    JOIN global_roles gr ON gr.id = ugr.role_id
    WHERE ugr.user_id = p_user_id AND gr.name = 'super_admin'

    UNION ALL

    -- Rol local en el restaurante específico
    SELECT 1
    FROM restaurant_members rm
    WHERE rm.user_id       = p_user_id
      AND rm.restaurant_id = p_restaurant_id
      AND rm.role          = ANY(p_roles)
      AND rm.is_active     = true
  );
$$;


-- ── Transferir ownership de un restaurante ────────────────────────────────────
-- Realiza el cambio en una sola transacción:
--   1. Actualiza restaurants.owner_id al nuevo owner.
--   2. Degrada al ex-owner a 'admin' en restaurant_members.
--   3. Promueve al nuevo owner a 'owner' (INSERT o UPDATE).
--   4. Actualiza el active_context del nuevo owner a 'owner'.
--
-- Uso: SELECT fn_transfer_ownership('restaurant-uuid', 'new-owner-uuid');
CREATE OR REPLACE FUNCTION fn_transfer_ownership(
  p_restaurant_id UUID,
  p_new_owner_id  UUID
)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
  v_old_owner_id UUID;
BEGIN
  SELECT owner_id INTO v_old_owner_id
  FROM restaurants WHERE id = p_restaurant_id;

  IF v_old_owner_id IS NULL THEN
    RAISE EXCEPTION 'Restaurante no encontrado: %', p_restaurant_id;
  END IF;

  IF v_old_owner_id = p_new_owner_id THEN
    RAISE EXCEPTION 'El nuevo owner es el mismo que el actual.';
  END IF;

  UPDATE restaurants SET owner_id = p_new_owner_id WHERE id = p_restaurant_id;

  UPDATE restaurant_members
  SET role = 'admin'
  WHERE user_id = v_old_owner_id AND restaurant_id = p_restaurant_id;

  INSERT INTO restaurant_members (user_id, restaurant_id, role)
  VALUES (p_new_owner_id, p_restaurant_id, 'owner')
  ON CONFLICT (user_id, restaurant_id)
  DO UPDATE SET role = 'owner', is_active = true;

  UPDATE users SET active_context = 'owner'
  WHERE id = p_new_owner_id AND active_context = 'visitor';
END;
$$;


-- ── Cambiar plan de un restaurante ────────────────────────────────────────────
-- Registra el cambio en subscriptions con previous_plan_id y downgrade_at.
-- Si el nuevo plan tiene menor precio → es un downgrade → se registra downgrade_at.
-- La política sobre qué hacer con recursos excedentes se maneja en la app.
--
-- Uso: SELECT fn_change_plan('restaurant-uuid', 'new-plan-uuid');
CREATE OR REPLACE FUNCTION fn_change_plan(
  p_restaurant_id UUID,
  p_new_plan_id   UUID
)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
  v_current_plan_id    UUID;
  v_current_plan_price NUMERIC;
  v_new_plan_price     NUMERIC;
  v_is_downgrade       BOOLEAN;
BEGIN
  SELECT plan_id INTO v_current_plan_id
  FROM restaurants WHERE id = p_restaurant_id;

  SELECT price INTO v_current_plan_price FROM plans WHERE id = v_current_plan_id;
  SELECT price INTO v_new_plan_price     FROM plans WHERE id = p_new_plan_id;

  v_is_downgrade := v_new_plan_price < v_current_plan_price;

  -- Expirar suscripción activa o trial actual
  UPDATE subscriptions
  SET status = 'expired', updated_at = now()
  WHERE restaurant_id = p_restaurant_id
    AND status IN ('active', 'trial');

  -- Crear nueva suscripción con historial del plan anterior
  INSERT INTO subscriptions (
    restaurant_id,
    plan_id,
    previous_plan_id,
    status,
    expires_at,
    downgrade_at
  ) VALUES (
    p_restaurant_id,
    p_new_plan_id,
    v_current_plan_id,
    'active',
    NULL,
    CASE WHEN v_is_downgrade THEN now() ELSE NULL END
  );

  -- Actualizar el plan activo del restaurante
  UPDATE restaurants SET plan_id = p_new_plan_id WHERE id = p_restaurant_id;
END;
$$;


-- ── Registrar visita de un comensal ───────────────────────────────────────────
-- Inserta un registro en restaurant_visits y retorna el UUID generado.
-- p_user_id puede ser NULL para visitas anónimas.
-- p_user_location: GEOGRAPHY(Point, 4326) o NULL.
-- p_distance_meters: calculado previamente en la app, o NULL.
--
-- Uso:
--   SELECT fn_register_visit(
--     'user-uuid', 'branch-uuid', 'checkin',
--     ST_Point(-77.03, -12.04)::geography, 150.5,
--     '{"device": "mobile"}'
--   );
CREATE OR REPLACE FUNCTION fn_register_visit(
  p_user_id         UUID      DEFAULT NULL,
  p_branch_id       UUID,
  p_visit_type      TEXT      DEFAULT 'view',
  p_user_location   GEOGRAPHY DEFAULT NULL,
  p_distance_meters NUMERIC   DEFAULT NULL,
  p_metadata        JSONB     DEFAULT '{}'
)
RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE
  v_visit_id UUID;
BEGIN
  INSERT INTO restaurant_visits (
    user_id, branch_id, visit_type,
    user_location, distance_meters, metadata
  ) VALUES (
    p_user_id, p_branch_id, p_visit_type,
    p_user_location, p_distance_meters, p_metadata
  )
  RETURNING id INTO v_visit_id;

  RETURN v_visit_id;
END;
$$;
