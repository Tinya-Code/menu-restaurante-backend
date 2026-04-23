

-- ══════════════════════════════════════════════════════════════════════════════
--  05_functions.sql
--  Funciones de utilidad expuestas para uso desde la aplicación.
--  Ejecutar después de 04_triggers_bootstrap.sql.
--
--  Funciones disponibles:
--    · get_branch_settings   → configuración directa de una sucursal
--    · get_branch_data       → payload JSONB completo de una sucursal para el cliente
--    · user_has_access       → verifica permisos de un usuario sobre un restaurante
--    · fn_transfer_ownership → transfiere el ownership de un restaurante atómicamente
--    · fn_change_plan        → cambia el plan con registro de historial de suscripciones
--    · fn_renew_subscription → extiende la suscripción mensual 30 días más
--    · fn_register_visit     → registra una interacción de un comensal con una sucursal
--    · get_plan_usage        → consumo de recursos por sucursal vs límites del plan
-- ══════════════════════════════════════════════════════════════════════════════


-- ── get_branch_settings ───────────────────────────────────────────────────────
-- Retorna la configuración completa de una sucursal desde branch_settings,
-- que es la única fuente de verdad. No realiza fusión con ninguna tabla padre.
-- Uso típico: cargar la configuración de una sucursal en el dashboard del owner.
--
-- Ejemplo: SELECT * FROM get_branch_settings('branch-uuid');
CREATE OR REPLACE FUNCTION get_branch_settings(p_branch_id UUID)
RETURNS TABLE (
  whatsapp_config    JSONB,
  display_config     JSONB,
  order_config       JSONB,
  business_config    JSONB,
  logo_url           TEXT,
  logo_cloudinary_id TEXT,
  description        TEXT,
  schedule           JSONB
)
LANGUAGE sql STABLE AS $$
  SELECT
    bs.whatsapp_config,
    bs.display_config,
    bs.order_config,
    bs.business_config,
    bs.logo_url,
    bs.logo_cloudinary_id,
    bs.description,
    bs.schedule
  FROM branch_settings bs
  WHERE bs.branch_id = p_branch_id;
$$;


-- ── get_branch_data ───────────────────────────────────────────────────────────
-- Retorna un JSONB completo con toda la información necesaria para renderizar
-- la interfaz pública de una sucursal en el cliente.
-- Incluye: datos de branch, restaurante, configuración, template,
-- banners activos, combos activos con sus productos, promociones vigentes
-- y menús completos (categorías con productos disponibles).
-- Solo se incluyen registros activos/disponibles; orientado a la vista del comensal.
--
-- Ejemplo: SELECT get_branch_data('branch-uuid');
CREATE OR REPLACE FUNCTION get_branch_data(p_branch_id UUID)
RETURNS JSONB LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'branch',     to_jsonb(b),
    'restaurant', to_jsonb(r),
    'settings',   (SELECT to_jsonb(s) FROM get_branch_settings(b.id) s),
    'template',   to_jsonb(t),

    'banners', (
      SELECT jsonb_agg(
        jsonb_build_object(
          'id',            bn.id,
          'image_url',     bn.image_url,
          'cloudinary_id', bn.cloudinary_id,
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
          'id',            co.id,
          'name',          co.name,
          'description',   co.description,
          'price',         co.price,
          'image_url',     co.image_url,
          'cloudinary_id', co.cloudinary_id,
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
        AND pr.is_active  = true
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
                  SELECT jsonb_agg(
                    jsonb_build_object(
                      'id',             p.id,
                      'branch_id',      p.branch_id,
                      'name',           p.name,
                      'description',    p.description,
                      'price',          p.price,
                      'image_url',      p.image_url,
                      'cloudinary_id',  p.cloudinary_id,
                      'is_available',   p.is_available,
                      'is_recommended', p.is_recommended
                    ) ORDER BY p.created_at
                  )
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


-- ── user_has_access ───────────────────────────────────────────────────────────
-- Verifica si un usuario tiene acceso a un restaurante con al menos uno de
-- los roles especificados. Combina dos fuentes de autorización:
--   1. Roles globales: un super_admin tiene acceso a TODOS los restaurantes.
--   2. Roles locales:  el usuario debe estar en restaurant_members con un rol
--      incluido en p_roles y con is_active = true.
-- Retorna TRUE si tiene acceso, FALSE si no.
--
-- Ejemplo: SELECT user_has_access('user-uuid', 'restaurant-uuid', ARRAY['owner','admin']);
CREATE OR REPLACE FUNCTION user_has_access(
  p_user_id       UUID,
  p_restaurant_id UUID,
  p_roles         TEXT[]
)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1
    FROM user_global_roles ugr
    JOIN global_roles gr ON gr.id = ugr.role_id
    WHERE ugr.user_id = p_user_id AND gr.name = 'super_admin'

    UNION ALL

    SELECT 1
    FROM restaurant_members rm
    WHERE rm.user_id       = p_user_id
      AND rm.restaurant_id = p_restaurant_id
      AND rm.role          = ANY(p_roles)
      AND rm.is_active     = true
  );
$$;


-- ── fn_transfer_ownership ─────────────────────────────────────────────────────
-- Transfiere el ownership de un restaurante a otro usuario de forma atómica:
--   1. Actualiza restaurants.owner_id al nuevo propietario.
--   2. Degrada al ex-owner a rol 'admin' en restaurant_members.
--   3. Registra al nuevo owner como 'owner' (INSERT o UPDATE si ya era miembro).
--   4. Actualiza active_context del nuevo owner a 'owner' si era 'visitor'.
-- Lanza excepción si el restaurante no existe o si el nuevo owner es el mismo actual.
--
-- Ejemplo: SELECT fn_transfer_ownership('restaurant-uuid', 'new-owner-uuid');
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


-- ── fn_change_plan ────────────────────────────────────────────────────────────
-- Cambia el plan de suscripción de un restaurante registrando el historial completo:
--   1. Expira la suscripción activa actual (status = 'expired').
--   2. Crea una nueva suscripción activa con el nuevo plan.
--      · billing_cycle 'forever' → expires_at = NULL
--      · billing_cycle 'monthly' → expires_at = now() + 30 días
--   3. Registra previous_plan_id para auditoría y trazabilidad.
--   4. Si es un downgrade (precio menor al actual), registra downgrade_at = now().
--   5. Actualiza restaurants.plan_id al nuevo plan.
--
-- La gestión de recursos que superen los nuevos límites tras el downgrade
-- (ej: tener más productos de los permitidos en el nuevo plan) se delega a la app.
--
-- Ejemplo: SELECT fn_change_plan('restaurant-uuid', 'new-plan-uuid');
CREATE OR REPLACE FUNCTION fn_change_plan(
  p_restaurant_id UUID,
  p_new_plan_id   UUID
)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
  v_current_plan_id    UUID;
  v_current_plan_price NUMERIC;
  v_new_plan_price     NUMERIC;
  v_new_billing_cycle  TEXT;
  v_is_downgrade       BOOLEAN;
  v_expires_at         TIMESTAMPTZ;
BEGIN
  SELECT plan_id INTO v_current_plan_id
  FROM restaurants WHERE id = p_restaurant_id;

  SELECT price INTO v_current_plan_price FROM plans WHERE id = v_current_plan_id;
  SELECT price, billing_cycle
    INTO v_new_plan_price, v_new_billing_cycle
    FROM plans WHERE id = p_new_plan_id;

  v_is_downgrade := v_new_plan_price < v_current_plan_price;

  v_expires_at := CASE
    WHEN v_new_billing_cycle = 'forever' THEN NULL
    ELSE now() + INTERVAL '30 days'
  END;

  UPDATE subscriptions
  SET status = 'expired', updated_at = now()
  WHERE restaurant_id = p_restaurant_id AND status = 'active';

  INSERT INTO subscriptions (
    restaurant_id, plan_id, previous_plan_id, status, expires_at, downgrade_at
  ) VALUES (
    p_restaurant_id,
    p_new_plan_id,
    v_current_plan_id,
    'active',
    v_expires_at,
    CASE WHEN v_is_downgrade THEN now() ELSE NULL END
  );

  UPDATE restaurants SET plan_id = p_new_plan_id WHERE id = p_restaurant_id;
END;
$$;


-- ── fn_renew_subscription ─────────────────────────────────────────────────────
-- Renueva la suscripción mensual activa de un restaurante por 30 días adicionales.
-- Solo aplica a planes con billing_cycle = 'monthly'. El plan Free ('forever')
-- no requiere renovación y lanza excepción si se intenta renovar.
-- Extiende expires_at desde el valor actual (no desde now()), preservando los
-- días restantes en renovaciones anticipadas.
-- Lanza excepción si no existe suscripción activa para el restaurante.
--
-- Ejemplo: SELECT fn_renew_subscription('restaurant-uuid');
CREATE OR REPLACE FUNCTION fn_renew_subscription(p_restaurant_id UUID)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
  v_billing_cycle TEXT;
  v_expires_at    TIMESTAMPTZ;
BEGIN
  SELECT p.billing_cycle, s.expires_at
    INTO v_billing_cycle, v_expires_at
  FROM subscriptions s
  JOIN plans p ON p.id = s.plan_id
  WHERE s.restaurant_id = p_restaurant_id AND s.status = 'active'
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró una suscripción activa para el restaurante: %', p_restaurant_id;
  END IF;

  IF v_billing_cycle = 'forever' THEN
    RAISE EXCEPTION 'El plan Free es permanente y no requiere renovación.';
  END IF;

  -- Extender desde el vencimiento actual; si ya venció, extender desde now()
  UPDATE subscriptions
  SET
    expires_at = GREATEST(v_expires_at, now()) + INTERVAL '30 days',
    status     = 'active',
    updated_at = now()
  WHERE restaurant_id = p_restaurant_id AND status IN ('active', 'expired');
END;
$$;


-- ── fn_register_visit ─────────────────────────────────────────────────────────
-- Registra una interacción de un comensal con una sucursal específica.
-- p_user_id = NULL para visitantes anónimos (usuarios no registrados).
-- p_metadata puede incluir información contextual: dispositivo, fuente de
-- tráfico (qr_code, direct_link, search, etc.) u otros datos de analytics.
-- Retorna el UUID de la visita registrada.
--
-- Ejemplo:
--   SELECT fn_register_visit(
--     'user-uuid', 'branch-uuid', 'checkin',
--     ST_Point(-77.03, -12.04)::geography, 150.5,
--     '{"device": "mobile", "source": "qr_code"}'
--   );
CREATE OR REPLACE FUNCTION fn_register_visit(
  p_branch_id       UUID,
  p_user_id         UUID      DEFAULT NULL,
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
    branch_id, user_id, visit_type,
    user_location, distance_meters, metadata
  ) VALUES (
    p_branch_id, p_user_id, p_visit_type,
    p_user_location, p_distance_meters, p_metadata
  )
  RETURNING id INTO v_visit_id;

  RETURN v_visit_id;
END;
$$;


-- ── get_plan_usage ────────────────────────────────────────────────────────────
-- Retorna una fila por cada sucursal activa del restaurante con el consumo
-- actual de recursos versus los límites del plan activo.
-- Diseñada para alimentar barras de progreso o indicadores en el dashboard.
-- NULL en max_* indica que el recurso es ilimitado en el plan activo.
-- Gracias a branch_id en products, el conteo de productos es un COUNT directo
-- sin joins adicionales, a diferencia de las demás métricas.
--
-- Ejemplo: SELECT * FROM get_plan_usage('restaurant-uuid');
CREATE OR REPLACE FUNCTION get_plan_usage(p_restaurant_id UUID)
RETURNS TABLE (
  branch_id        UUID,
  branch_name      TEXT,
  is_main          BOOLEAN,
  plan_name        TEXT,
  used_products    BIGINT,
  max_products     INTEGER,
  used_categories  BIGINT,
  max_categories   INTEGER,
  used_banners     BIGINT,
  max_banners      INTEGER,
  used_combos      BIGINT,
  max_combos       INTEGER,
  used_promotions  BIGINT,
  max_promotions   INTEGER,
  used_branches    BIGINT,
  max_branches     INTEGER
)
LANGUAGE sql STABLE AS $$
  SELECT
    b.id              AS branch_id,
    b.name            AS branch_name,
    b.is_main,
    p.name            AS plan_name,

    (SELECT COUNT(*) FROM products    WHERE branch_id = b.id)   AS used_products,
    p.max_products,

    (SELECT COUNT(*)
     FROM categories c
     JOIN menus m ON m.id = c.menu_id
     WHERE m.branch_id = b.id)                                  AS used_categories,
    p.max_categories,

    (SELECT COUNT(*) FROM banners     WHERE branch_id = b.id)   AS used_banners,
    p.max_banners,

    (SELECT COUNT(*) FROM combos      WHERE branch_id = b.id)   AS used_combos,
    p.max_combos,

    (SELECT COUNT(*) FROM promotions  WHERE branch_id = b.id)   AS used_promotions,
    p.max_promotions,

    (SELECT COUNT(*)
     FROM branches
     WHERE restaurant_id = p_restaurant_id AND is_active = true) AS used_branches,
    p.max_branches

  FROM branches b
  LEFT JOIN plans p ON p.id = (
    SELECT plan_id FROM restaurants WHERE id = p_restaurant_id
  )
  WHERE b.restaurant_id = p_restaurant_id AND b.is_active = true;
$$;
