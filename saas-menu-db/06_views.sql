-- ══════════════════════════════════════════════════════════════════════════════
--  06_views.sql
--  Vistas de la aplicación.
--
--  Vistas incluidas:
--    · v_restaurants_overview  → resumen de restaurantes con plan y suscripción
--    · v_plan_usage            → uso de recursos vs límites del plan por sucursal
--    · v_user_permissions      → permisos globales y locales de cada usuario
--    · v_visit_history         → historial de visitas de comensales
--    · v_menu_full             → menú completo desnormalizado (reporting)
--    · v_combos_full           → combos con sus productos detallados
--    · v_active_promotions     → promociones vigentes filtradas por fecha
--
--  Ejecutar después de 05_functions.sql.
-- ══════════════════════════════════════════════════════════════════════════════


-- ── v_restaurants_overview ────────────────────────────────────────────────────
-- Resumen de restaurantes con plan activo, suscripción y conteo de sucursales.
-- Incluye contexto activo del owner y datos de downgrade si aplica.
CREATE OR REPLACE VIEW v_restaurants_overview AS
SELECT
  r.id              AS restaurant_id,
  r.name            AS restaurant_name,
  r.slug,
  r.owner_id,
  u.email           AS owner_email,
  u.active_context  AS owner_context,
  r.is_active,
  p.name            AS plan_name,
  p.max_branches,
  p.max_products,
  p.max_banners,
  p.max_combos,
  p.max_promotions,
  s.status          AS subscription_status,
  s.expires_at      AS subscription_expires,
  s.downgrade_at,
  s.previous_plan_id,
  COUNT(b.id)       AS branch_count
FROM restaurants r
JOIN users u ON u.id = r.owner_id
LEFT JOIN plans p ON p.id = r.plan_id
LEFT JOIN subscriptions s
  ON s.restaurant_id = r.id AND s.status IN ('active', 'trial')
LEFT JOIN branches b
  ON b.restaurant_id = r.id AND b.is_active = true
GROUP BY
  r.id, u.email, u.active_context, p.name,
  p.max_branches, p.max_products, p.max_banners, p.max_combos, p.max_promotions,
  s.status, s.expires_at, s.downgrade_at, s.previous_plan_id;


-- ── v_plan_usage ──────────────────────────────────────────────────────────────
-- Uso actual de recursos vs límites del plan, por sucursal.
-- Útil para el dashboard de administración y para mostrar barras de progreso
-- en la UI del dueño ("2 de 5 banners usados").
CREATE OR REPLACE VIEW v_plan_usage AS
SELECT
  r.id    AS restaurant_id,
  r.name  AS restaurant_name,
  b.id    AS branch_id,
  b.name  AS branch_name,
  b.is_main,
  p.name  AS plan_name,

  p.max_banners,
  (SELECT COUNT(*) FROM banners WHERE branch_id = b.id)    AS used_banners,

  p.max_combos,
  (SELECT COUNT(*) FROM combos WHERE branch_id = b.id)     AS used_combos,

  p.max_promotions,
  (SELECT COUNT(*) FROM promotions WHERE branch_id = b.id) AS used_promotions,

  p.max_products,
  (SELECT COUNT(*)
   FROM products pr
   JOIN categories c ON c.id = pr.category_id
   JOIN menus m       ON m.id = c.menu_id
   WHERE m.branch_id = b.id)                               AS used_products,

  p.max_categories,
  (SELECT COUNT(*)
   FROM categories c
   JOIN menus m ON m.id = c.menu_id
   WHERE m.branch_id = b.id)                               AS used_categories,

  p.max_branches,
  (SELECT COUNT(*)
   FROM branches
   WHERE restaurant_id = r.id AND is_active = true)        AS used_branches

FROM restaurants r
JOIN branches b   ON b.restaurant_id = r.id AND b.is_active = true
LEFT JOIN plans p ON p.id = r.plan_id;


-- ── v_user_permissions ────────────────────────────────────────────────────────
-- Permisos globales (plataforma) y locales (restaurante) de cada usuario.
-- No incluye visitas de comensal — eso está en restaurant_visits.
-- El campo active_context indica qué interfaz está usando el usuario ahora.
CREATE OR REPLACE VIEW v_user_permissions AS
SELECT
  u.id             AS user_id,
  u.email,
  u.active_context,
  'global'         AS scope,
  NULL::UUID       AS restaurant_id,
  NULL::TEXT       AS restaurant_name,
  gr.name          AS role
FROM users u
JOIN user_global_roles ugr ON ugr.user_id = u.id
JOIN global_roles gr ON gr.id = ugr.role_id

UNION ALL

SELECT
  u.id             AS user_id,
  u.email,
  u.active_context,
  'local'          AS scope,
  r.id             AS restaurant_id,
  r.name           AS restaurant_name,
  rm.role
FROM users u
JOIN restaurant_members rm ON rm.user_id = u.id
JOIN restaurants r ON r.id = rm.restaurant_id
WHERE rm.is_active = true;


-- ── v_visit_history ───────────────────────────────────────────────────────────
-- Historial de visitas/interacciones de comensales con sucursales.
-- Ordenado por más reciente primero.
CREATE OR REPLACE VIEW v_visit_history AS
SELECT
  rv.id              AS visit_id,
  rv.user_id,
  u.email            AS user_email,
  u.display_name     AS user_name,
  rv.visit_type,
  rv.visited_at,
  rv.distance_meters,
  rv.metadata,
  b.id               AS branch_id,
  b.name             AS branch_name,
  r.id               AS restaurant_id,
  r.name             AS restaurant_name,
  r.slug             AS restaurant_slug
FROM restaurant_visits rv
LEFT JOIN users u   ON u.id  = rv.user_id
JOIN branches b     ON b.id  = rv.branch_id
JOIN restaurants r  ON r.id  = b.restaurant_id
ORDER BY rv.visited_at DESC;


-- ── v_menu_full ───────────────────────────────────────────────────────────────
-- Menú completo desnormalizado.
-- Útil para exports, reporting y herramientas de análisis externas.
CREATE OR REPLACE VIEW v_menu_full AS
SELECT
  r.id            AS restaurant_id,
  r.name          AS restaurant_name,
  r.slug          AS restaurant_slug,
  b.id            AS branch_id,
  b.name          AS branch_name,
  b.is_main,
  m.id            AS menu_id,
  m.name          AS menu_name,
  m.display_order AS menu_order,
  c.id            AS category_id,
  c.name          AS category_name,
  c.display_order AS category_order,
  ct.name         AS category_type,
  p.id            AS product_id,
  p.name          AS product_name,
  p.description   AS product_description,
  p.price,
  p.image_url,
  p.is_available,
  p.is_recommended
FROM restaurants r
JOIN branches b          ON b.restaurant_id = r.id  AND b.is_active = true
JOIN menus m             ON m.branch_id = b.id       AND m.is_active = true
JOIN categories c        ON c.menu_id = m.id         AND c.is_active = true
LEFT JOIN category_types ct ON ct.id = c.type_id
LEFT JOIN products p     ON p.category_id = c.id     AND p.is_available = true
WHERE r.is_active = true
ORDER BY r.id, b.is_main DESC, m.display_order, c.display_order;


-- ── v_combos_full ─────────────────────────────────────────────────────────────
-- Combos con sus productos detallados (desnormalizado).
CREATE OR REPLACE VIEW v_combos_full AS
SELECT
  co.id          AS combo_id,
  co.branch_id,
  co.name        AS combo_name,
  co.description AS combo_description,
  co.price       AS combo_price,
  co.image_url   AS combo_image_url,
  co.is_active,
  p.id           AS product_id,
  p.name         AS product_name,
  p.price        AS product_unit_price,
  cp.quantity
FROM combos co
JOIN combo_products cp ON cp.combo_id  = co.id
JOIN products p        ON p.id         = cp.product_id;


-- ── v_active_promotions ───────────────────────────────────────────────────────
-- Promociones vigentes en este momento (is_active=true y dentro del rango de fechas).
CREATE OR REPLACE VIEW v_active_promotions AS
SELECT
  pr.*,
  b.restaurant_id,
  r.name AS restaurant_name,
  b.name AS branch_name
FROM promotions pr
JOIN branches b    ON b.id = pr.branch_id
JOIN restaurants r ON r.id = b.restaurant_id
WHERE pr.is_active = true
  AND (pr.start_date IS NULL OR pr.start_date <= now())
  AND (pr.end_date   IS NULL OR pr.end_date   >= now());
