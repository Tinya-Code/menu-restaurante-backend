
-- ══════════════════════════════════════════════════════════════════════════════
--  06_views.sql
--  Vistas preconstruidas para consultas frecuentes de la aplicación.
--  Ejecutar después de 05_functions.sql.
--
--  Vistas disponibles:
--    · v_restaurants_overview → resumen de restaurantes con plan y suscripción
--    · v_plan_usage           → consumo de recursos por sucursal vs límites del plan
--    · v_branch_settings      → configuración directa de cada sucursal activa
--    · v_user_permissions     → permisos globales y locales de cada usuario
--    · v_visit_history        → historial de visitas de comensales ordenado desc
--    · v_menu_full            → menú desnormalizado para reporting cross-restaurante
--    · v_combos_full          → combos con sus productos y cantidades expandidos
--    · v_active_promotions    → solo las promociones actualmente vigentes
-- ══════════════════════════════════════════════════════════════════════════════


-- ── v_restaurants_overview ────────────────────────────────────────────────────
-- Vista de resumen para el listado de restaurantes en el backoffice.
-- Combina datos del restaurante, su owner, el plan activo y la suscripción
-- corriente. Incluye el conteo de sucursales activas para mostrar el consumo
-- del límite max_branches. Un restaurante sin plan asignado aparece con los
-- campos de plan en NULL.
CREATE OR REPLACE VIEW v_restaurants_overview AS
SELECT
  r.id             AS restaurant_id,
  r.name           AS restaurant_name,
  r.slug,
  r.owner_id,
  u.email          AS owner_email,
  u.active_context AS owner_context,
  r.is_active,
  p.name           AS plan_name,
  p.price          AS plan_price,
  p.billing_cycle,
  p.max_branches,
  p.max_products,
  p.max_banners,
  p.max_combos,
  p.max_promotions,
  s.status         AS subscription_status,
  s.started_at     AS subscription_started,
  s.expires_at     AS subscription_expires,
  s.downgrade_at,
  s.previous_plan_id,
  COUNT(b.id)      AS branch_count
FROM restaurants r
JOIN users u ON u.id = r.owner_id
LEFT JOIN plans p ON p.id = r.plan_id
LEFT JOIN subscriptions s
  ON s.restaurant_id = r.id AND s.status = 'active'
LEFT JOIN branches b
  ON b.restaurant_id = r.id AND b.is_active = true
GROUP BY
  r.id, u.email, u.active_context,
  p.name, p.price, p.billing_cycle,
  p.max_branches, p.max_products,
  p.max_banners, p.max_combos, p.max_promotions,
  s.status, s.started_at, s.expires_at, s.downgrade_at, s.previous_plan_id;


-- ── v_plan_usage ──────────────────────────────────────────────────────────────
-- Consumo de recursos por sucursal comparado con los límites del plan activo.
-- Una fila por cada sucursal activa del restaurante.
-- used_* → conteo actual del recurso; max_* → límite del plan (NULL = ilimitado).
-- El conteo de productos usa branch_id directo (sin joins) gracias a la
-- desnormalización controlada en products.
CREATE OR REPLACE VIEW v_plan_usage AS
SELECT
  r.id    AS restaurant_id,
  r.name  AS restaurant_name,
  b.id    AS branch_id,
  b.name  AS branch_name,
  b.is_main,
  p.name  AS plan_name,
  p.price AS plan_price,
  p.billing_cycle,

  p.max_banners,
  (SELECT COUNT(*) FROM banners    WHERE branch_id = b.id)      AS used_banners,

  p.max_combos,
  (SELECT COUNT(*) FROM combos     WHERE branch_id = b.id)      AS used_combos,

  p.max_promotions,
  (SELECT COUNT(*) FROM promotions WHERE branch_id = b.id)      AS used_promotions,

  p.max_products,
  (SELECT COUNT(*) FROM products   WHERE branch_id = b.id)      AS used_products,

  p.max_categories,
  (SELECT COUNT(*)
   FROM categories c
   JOIN menus m ON m.id = c.menu_id
   WHERE m.branch_id = b.id)                                    AS used_categories,

  p.max_branches,
  (SELECT COUNT(*)
   FROM branches
   WHERE restaurant_id = r.id AND is_active = true)             AS used_branches

FROM restaurants r
JOIN branches b   ON b.restaurant_id = r.id AND b.is_active = true
LEFT JOIN plans p ON p.id = r.plan_id;


-- ── v_branch_settings ─────────────────────────────────────────────────────────
-- Configuración directa de cada sucursal activa.
-- branch_settings es la fuente de verdad: no hereda ni fusiona con ningún padre.
-- Esta vista es conveniente para obtener configuración + metadatos de la
-- sucursal y el restaurante en una sola consulta.
CREATE OR REPLACE VIEW v_branch_settings AS
SELECT
  b.id              AS branch_id,
  b.name            AS branch_name,
  b.is_main,
  b.restaurant_id,
  r.name            AS restaurant_name,
  bs.whatsapp_config,
  bs.display_config,
  bs.order_config,
  bs.business_config,
  bs.logo_url,
  bs.logo_cloudinary_id,
  bs.description,
  bs.schedule,
  bs.updated_at     AS settings_updated_at
FROM branches b
JOIN restaurants r      ON r.id  = b.restaurant_id
JOIN branch_settings bs ON bs.branch_id = b.id
WHERE b.is_active = true;


-- ── v_user_permissions ────────────────────────────────────────────────────────
-- Vista unificada de permisos de todos los usuarios del sistema.
-- Combina dos tipos de permiso en un único conjunto de resultados:
--   scope='global' → roles de plataforma (super_admin, developer, support);
--                    restaurant_id = NULL porque aplican a todo el sistema
--   scope='local'  → roles dentro de un restaurante específico (owner, admin, staff)
-- Útil para auditorías de acceso o verificaciones masivas de permisos en el backoffice.
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
-- Historial de visitas de comensales a sucursales, ordenado del más reciente
-- al más antiguo. Incluye datos del usuario (si no es anónimo), la sucursal
-- visitada y el restaurante al que pertenece.
-- Útil para analytics y reportes de tráfico en el backoffice.
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
LEFT JOIN users u  ON u.id = rv.user_id
JOIN branches b    ON b.id = rv.branch_id
JOIN restaurants r ON r.id = b.restaurant_id
ORDER BY rv.visited_at DESC;


-- ── v_menu_full ───────────────────────────────────────────────────────────────
-- Vista desnormalizada del menú completo de todos los restaurantes.
-- Aplana la jerarquía restaurant → branch → menu → category → product
-- en una fila por producto. Solo incluye registros activos y productos disponibles.
-- Útil para búsquedas, exportaciones y reportes de productos cross-restaurante.
-- branch_id en products coincide siempre con el branch_id de la fila
-- (garantizado por trg_set_product_branch_id al momento del INSERT).
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
  p.branch_id     AS product_branch_id,
  p.name          AS product_name,
  p.description   AS product_description,
  p.price,
  p.image_url,
  p.cloudinary_id AS product_cloudinary_id,
  p.is_available,
  p.is_recommended,
  p.created_at    AS product_created_at
FROM restaurants r
JOIN branches b          ON b.restaurant_id = r.id  AND b.is_active = true
JOIN menus m             ON m.branch_id = b.id       AND m.is_active = true
JOIN categories c        ON c.menu_id = m.id         AND c.is_active = true
LEFT JOIN category_types ct ON ct.id = c.type_id
LEFT JOIN products p     ON p.category_id = c.id     AND p.is_available = true
WHERE r.is_active = true
ORDER BY r.id, b.is_main DESC, m.display_order, c.display_order, p.created_at;


-- ── v_combos_full ─────────────────────────────────────────────────────────────
-- Vista expandida de combos con sus productos y cantidades.
-- Una fila por cada producto dentro de cada combo.
-- Útil para renderizar la sección de combos en la interfaz pública o para
-- analytics de popularidad de productos en combos.
CREATE OR REPLACE VIEW v_combos_full AS
SELECT
  co.id            AS combo_id,
  co.branch_id,
  co.name          AS combo_name,
  co.description   AS combo_description,
  co.price         AS combo_price,
  co.image_url     AS combo_image_url,
  co.cloudinary_id AS combo_cloudinary_id,
  co.is_active,
  p.id             AS product_id,
  p.branch_id      AS product_branch_id,
  p.name           AS product_name,
  p.price          AS product_unit_price,
  cp.quantity
FROM combos co
JOIN combo_products cp ON cp.combo_id  = co.id
JOIN products p        ON p.id         = cp.product_id;


-- ── v_active_promotions ───────────────────────────────────────────────────────
-- Promociones actualmente vigentes en todas las sucursales.
-- Una promoción está vigente si: is_active = true y now() ∈ [start_date, end_date]
-- (extremo NULL en cualquier dirección significa abierto en esa dirección).
-- Incluye datos del restaurante y la sucursal para facilitar el filtrado por contexto.
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