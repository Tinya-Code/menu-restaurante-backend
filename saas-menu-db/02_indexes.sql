
-- ══════════════════════════════════════════════════════════════════════════════
--  02_indexes.sql
--  Índices de rendimiento para todas las tablas del sistema.
--  Ejecutar después de 01_tables.sql.
--
--  Estrategia:
--    · B-tree   → columnas de filtrado, ordenamiento y joins frecuentes
--    · GIN      → campos JSONB y búsqueda de texto por trigramas (pg_trgm)
--    · GIST     → columnas GEOGRAPHY para búsquedas espaciales (ST_Distance)
--    · Parciales (WHERE) → reducen el tamaño del índice filtrando solo las
--                          filas relevantes (activos, no nulos, etc.)
-- ══════════════════════════════════════════════════════════════════════════════


-- ── users ─────────────────────────────────────────────────────────────────────
-- idx_users_email_lower   → login por email case-insensitive
-- idx_users_firebase_uid  → lookup de autenticación entrante desde Firebase
-- idx_users_phone         → búsqueda por teléfono (solo filas que tienen uno)
-- idx_users_active_context → segregar owners de visitors en el dashboard
CREATE UNIQUE INDEX idx_users_email_lower    ON users (LOWER(email));
CREATE INDEX        idx_users_firebase_uid   ON users (firebase_uid) WHERE firebase_uid IS NOT NULL;
CREATE INDEX        idx_users_phone          ON users (phone)        WHERE phone IS NOT NULL;
CREATE INDEX        idx_users_active_context ON users (active_context);
CREATE INDEX        idx_users_created_at     ON users (created_at);

-- ── user_global_roles ─────────────────────────────────────────────────────────
-- Soporte para consultas en ambas direcciones: roles de un usuario y usuarios
-- con un rol determinado.
CREATE INDEX idx_user_global_roles_user ON user_global_roles (user_id);
CREATE INDEX idx_user_global_roles_role ON user_global_roles (role_id);

-- ── plans ─────────────────────────────────────────────────────────────────────
CREATE INDEX idx_plans_is_active ON plans (is_active);
CREATE INDEX idx_plans_price     ON plans (price);

-- ── templates ─────────────────────────────────────────────────────────────────
CREATE INDEX idx_templates_plan_id   ON templates (plan_id);
CREATE INDEX idx_templates_is_active ON templates (is_active);
CREATE INDEX idx_templates_slug      ON templates (slug);

-- ── restaurants ───────────────────────────────────────────────────────────────
-- idx_restaurants_name → búsqueda difusa por nombre usando trigramas (pg_trgm)
CREATE INDEX idx_restaurants_owner_id   ON restaurants (owner_id);
CREATE INDEX idx_restaurants_plan_id    ON restaurants (plan_id);
CREATE INDEX idx_restaurants_slug       ON restaurants (slug);
CREATE INDEX idx_restaurants_is_active  ON restaurants (is_active);
CREATE INDEX idx_restaurants_created_at ON restaurants (created_at);
CREATE INDEX idx_restaurants_name       ON restaurants USING GIN (name gin_trgm_ops);

-- ── restaurant_members ────────────────────────────────────────────────────────
-- idx_restaurant_members_mgr → consulta rápida de managers (owner/admin)
--                              de un restaurante específico
CREATE INDEX idx_restaurant_members_user ON restaurant_members (user_id);
CREATE INDEX idx_restaurant_members_rest ON restaurant_members (restaurant_id);
CREATE INDEX idx_restaurant_members_role ON restaurant_members (role);
CREATE INDEX idx_restaurant_members_mgr  ON restaurant_members (user_id, role)
  WHERE role IN ('owner', 'admin');

-- ── restaurant_tags ───────────────────────────────────────────────────────────
-- Permite recuperar todos los restaurantes con un tag dado sin full scan.
CREATE INDEX idx_restaurant_tags_tag ON restaurant_tags (tag_id);

-- ── subscriptions ─────────────────────────────────────────────────────────────
-- idx_subscriptions_expires  → job de expiración de planes mensuales vencidos
-- idx_subscriptions_downgrade → auditoría de downgrades históricos
CREATE INDEX idx_subscriptions_restaurant ON subscriptions (restaurant_id);
CREATE INDEX idx_subscriptions_plan       ON subscriptions (plan_id);
CREATE INDEX idx_subscriptions_prev_plan  ON subscriptions (previous_plan_id) WHERE previous_plan_id IS NOT NULL;
CREATE INDEX idx_subscriptions_status     ON subscriptions (status);
CREATE INDEX idx_subscriptions_expires    ON subscriptions (expires_at)   WHERE expires_at IS NOT NULL;
CREATE INDEX idx_subscriptions_downgrade  ON subscriptions (downgrade_at) WHERE downgrade_at IS NOT NULL;

-- ── branches ──────────────────────────────────────────────────────────────────
-- idx_branches_is_main    → localizar la sucursal principal de un restaurante
-- idx_branches_location   → búsquedas geoespaciales de sucursales cercanas
CREATE INDEX idx_branches_restaurant_id ON branches (restaurant_id);
CREATE INDEX idx_branches_template_id   ON branches (template_id)         WHERE template_id IS NOT NULL;
CREATE INDEX idx_branches_is_active     ON branches (is_active);
CREATE INDEX idx_branches_is_main       ON branches (restaurant_id)       WHERE is_main = true;
CREATE INDEX idx_branches_location      ON branches USING GIST (location) WHERE location IS NOT NULL;

-- ── branch_settings ───────────────────────────────────────────────────────────
-- Índices GIN sobre campos JSONB para consultas de configuración frecuentes.
CREATE INDEX idx_branch_settings_wa       ON branch_settings USING GIN (whatsapp_config);
CREATE INDEX idx_branch_settings_order    ON branch_settings USING GIN (order_config);
CREATE INDEX idx_branch_settings_schedule ON branch_settings USING GIN (schedule);
CREATE INDEX idx_branch_settings_display  ON branch_settings USING GIN (display_config);

-- ── menus ─────────────────────────────────────────────────────────────────────
-- idx_menus_display_order → renderizar menús en el orden correcto dentro de
--                           una sucursal sin sort post-hoc
CREATE INDEX idx_menus_branch_id     ON menus (branch_id);
CREATE INDEX idx_menus_is_active     ON menus (is_active);
CREATE INDEX idx_menus_display_order ON menus (branch_id, display_order);

-- ── categories ────────────────────────────────────────────────────────────────
-- idx_categories_name          → búsqueda difusa por nombre (pg_trgm)
-- idx_categories_display_order → renderizar categorías en orden dentro del menú
CREATE INDEX idx_categories_menu_id       ON categories (menu_id);
CREATE INDEX idx_categories_type_id       ON categories (type_id)       WHERE type_id IS NOT NULL;
CREATE INDEX idx_categories_name          ON categories USING GIN (name gin_trgm_ops);
CREATE INDEX idx_categories_is_active     ON categories (is_active);
CREATE INDEX idx_categories_display_order ON categories (menu_id, display_order);

-- ── products ──────────────────────────────────────────────────────────────────
-- idx_products_name          → búsqueda difusa por nombre (pg_trgm)
-- idx_products_description   → búsqueda en descripción (solo filas con texto)
-- idx_products_is_recommended → listar destacados sin full scan
-- idx_products_branch_avail  → todos los productos disponibles de una sucursal;
--                              evita recorrer la jerarquía menu → category
CREATE INDEX idx_products_branch_id      ON products (branch_id);
CREATE INDEX idx_products_category_id    ON products (category_id);
CREATE INDEX idx_products_name           ON products USING GIN (name gin_trgm_ops);
CREATE INDEX idx_products_description    ON products USING GIN (description gin_trgm_ops) WHERE description IS NOT NULL;
CREATE INDEX idx_products_is_available   ON products (is_available);
CREATE INDEX idx_products_is_recommended ON products (is_recommended) WHERE is_recommended = true;
CREATE INDEX idx_products_price          ON products (price);
CREATE INDEX idx_products_created_at     ON products (created_at);
CREATE INDEX idx_products_branch_avail   ON products (branch_id, is_available);

-- ── banners ───────────────────────────────────────────────────────────────────
-- idx_banners_display_order → renderizar banners en orden correcto en la sucursal
CREATE INDEX idx_banners_branch_id     ON banners (branch_id);
CREATE INDEX idx_banners_is_active     ON banners (is_active);
CREATE INDEX idx_banners_display_order ON banners (branch_id, display_order);

-- ── combos ────────────────────────────────────────────────────────────────────
-- idx_combos_display_order → renderizar combos en orden correcto en la sucursal
CREATE INDEX idx_combos_branch_id     ON combos (branch_id);
CREATE INDEX idx_combos_is_active     ON combos (is_active);
CREATE INDEX idx_combos_display_order ON combos (branch_id, display_order);

-- ── combo_products ────────────────────────────────────────────────────────────
-- Soporte para joins en ambas direcciones: productos de un combo y combos
-- que contienen un producto dado.
CREATE INDEX idx_combo_products_combo   ON combo_products (combo_id);
CREATE INDEX idx_combo_products_product ON combo_products (product_id);

-- ── promotions ────────────────────────────────────────────────────────────────
-- idx_promotions_applies_to → filtrar promociones por tipo de recurso y target
-- idx_promotions_dates      → consultar promociones con rango de fechas definido
CREATE INDEX idx_promotions_branch_id  ON promotions (branch_id);
CREATE INDEX idx_promotions_is_active  ON promotions (is_active);
CREATE INDEX idx_promotions_applies_to ON promotions (applies_to, target_id);
CREATE INDEX idx_promotions_dates      ON promotions (start_date, end_date)
  WHERE start_date IS NOT NULL OR end_date IS NOT NULL;

-- ── restaurant_visits ─────────────────────────────────────────────────────────
-- idx_visits_user_location → búsquedas espaciales de visitas de usuarios cercanos
-- idx_visits_user_branch   → historial de visitas de un usuario a una sucursal,
--                            ordenado del más reciente al más antiguo
CREATE INDEX idx_visits_user_id       ON restaurant_visits (user_id)     WHERE user_id IS NOT NULL;
CREATE INDEX idx_visits_branch_id     ON restaurant_visits (branch_id);
CREATE INDEX idx_visits_visit_type    ON restaurant_visits (visit_type);
CREATE INDEX idx_visits_visited_at    ON restaurant_visits (visited_at);
CREATE INDEX idx_visits_user_location ON restaurant_visits USING GIST (user_location) WHERE user_location IS NOT NULL;
CREATE INDEX idx_visits_user_branch   ON restaurant_visits (user_id, branch_id, visited_at DESC)
  WHERE user_id IS NOT NULL;

