-- ══════════════════════════════════════════════════════════════════════════════
--  02_indexes.sql
--  Índices de todas las tablas.
--  Ejecutar después de 01_tables.sql.
-- ══════════════════════════════════════════════════════════════════════════════


-- ── users ─────────────────────────────────────────────────────────────────────
CREATE UNIQUE INDEX idx_users_email_lower   ON users (LOWER(email));
CREATE INDEX idx_users_firebase_uid         ON users (firebase_uid)    WHERE firebase_uid IS NOT NULL;
CREATE INDEX idx_users_phone                ON users (phone)           WHERE phone IS NOT NULL;
CREATE INDEX idx_users_active_context       ON users (active_context);
CREATE INDEX idx_users_created_at           ON users (created_at);

-- ── user_global_roles ─────────────────────────────────────────────────────────
CREATE INDEX idx_user_global_roles_user_id  ON user_global_roles (user_id);
CREATE INDEX idx_user_global_roles_role_id  ON user_global_roles (role_id);

-- ── plans ─────────────────────────────────────────────────────────────────────
CREATE INDEX idx_plans_is_active            ON plans (is_active);
CREATE INDEX idx_plans_created_at           ON plans (created_at);

-- ── templates ─────────────────────────────────────────────────────────────────
CREATE INDEX idx_templates_plan_id          ON templates (plan_id);
CREATE INDEX idx_templates_is_active        ON templates (is_active);
CREATE INDEX idx_templates_slug             ON templates (slug);

-- ── restaurants ───────────────────────────────────────────────────────────────
CREATE INDEX idx_restaurants_owner_id       ON restaurants (owner_id);
CREATE INDEX idx_restaurants_plan_id        ON restaurants (plan_id);
CREATE INDEX idx_restaurants_slug           ON restaurants (slug);
CREATE INDEX idx_restaurants_is_active      ON restaurants (is_active);
CREATE INDEX idx_restaurants_created_at     ON restaurants (created_at);
-- Búsqueda por nombre con trigramas
CREATE INDEX idx_restaurants_name           ON restaurants USING GIN (name gin_trgm_ops);

-- ── restaurant_settings ───────────────────────────────────────────────────────
CREATE INDEX idx_restaurant_settings_wa     ON restaurant_settings USING GIN (whatsapp_config);
CREATE INDEX idx_restaurant_settings_disp   ON restaurant_settings USING GIN (display_config);

-- ── restaurant_members ────────────────────────────────────────────────────────
CREATE INDEX idx_restaurant_members_user    ON restaurant_members (user_id);
CREATE INDEX idx_restaurant_members_rest    ON restaurant_members (restaurant_id);
CREATE INDEX idx_restaurant_members_role    ON restaurant_members (role);
-- Consulta frecuente: restaurantes donde el user tiene rol de gestión
CREATE INDEX idx_restaurant_members_mgr     ON restaurant_members (user_id, role)
  WHERE role IN ('owner', 'admin');

-- ── restaurant_tags ───────────────────────────────────────────────────────────
CREATE INDEX idx_restaurant_tags_tag_id     ON restaurant_tags (tag_id);

-- ── subscriptions ─────────────────────────────────────────────────────────────
CREATE INDEX idx_subscriptions_restaurant   ON subscriptions (restaurant_id);
CREATE INDEX idx_subscriptions_plan         ON subscriptions (plan_id);
CREATE INDEX idx_subscriptions_prev_plan    ON subscriptions (previous_plan_id) WHERE previous_plan_id IS NOT NULL;
CREATE INDEX idx_subscriptions_status       ON subscriptions (status);
CREATE INDEX idx_subscriptions_expires      ON subscriptions (expires_at)       WHERE expires_at IS NOT NULL;
CREATE INDEX idx_subscriptions_downgrade    ON subscriptions (downgrade_at)     WHERE downgrade_at IS NOT NULL;

-- ── branches ──────────────────────────────────────────────────────────────────
CREATE INDEX idx_branches_restaurant_id     ON branches (restaurant_id);
CREATE INDEX idx_branches_template_id       ON branches (template_id)           WHERE template_id IS NOT NULL;
CREATE INDEX idx_branches_is_active         ON branches (is_active);
CREATE INDEX idx_branches_is_main           ON branches (restaurant_id)         WHERE is_main = true;
-- Búsqueda geoespacial de sucursales cercanas
CREATE INDEX idx_branches_location          ON branches USING GIST (location)   WHERE location IS NOT NULL;

-- ── branch_settings ───────────────────────────────────────────────────────────
CREATE INDEX idx_branch_settings_wa         ON branch_settings USING GIN (whatsapp_config);
CREATE INDEX idx_branch_settings_schedule   ON branch_settings USING GIN (schedule);

-- ── menus ─────────────────────────────────────────────────────────────────────
CREATE INDEX idx_menus_branch_id            ON menus (branch_id);
CREATE INDEX idx_menus_is_active            ON menus (is_active);
CREATE INDEX idx_menus_display_order        ON menus (branch_id, display_order);

-- ── categories ────────────────────────────────────────────────────────────────
CREATE INDEX idx_categories_menu_id         ON categories (menu_id);
CREATE INDEX idx_categories_type_id         ON categories (type_id)             WHERE type_id IS NOT NULL;
CREATE INDEX idx_categories_name            ON categories USING GIN (name gin_trgm_ops);
CREATE INDEX idx_categories_is_active       ON categories (is_active);
CREATE INDEX idx_categories_display_order   ON categories (menu_id, display_order);

-- ── products ──────────────────────────────────────────────────────────────────
CREATE INDEX idx_products_category_id       ON products (category_id);
CREATE INDEX idx_products_name              ON products USING GIN (name gin_trgm_ops);
CREATE INDEX idx_products_description       ON products USING GIN (description gin_trgm_ops) WHERE description IS NOT NULL;
CREATE INDEX idx_products_is_available      ON products (is_available);
CREATE INDEX idx_products_display_order     ON products (category_id, display_order);
CREATE INDEX idx_products_price             ON products (price);
CREATE INDEX idx_products_created_at        ON products (created_at);

-- ── banners ───────────────────────────────────────────────────────────────────
CREATE INDEX idx_banners_branch_id          ON banners (branch_id);
CREATE INDEX idx_banners_is_active          ON banners (is_active);
CREATE INDEX idx_banners_display_order      ON banners (branch_id, display_order);

-- ── combos ────────────────────────────────────────────────────────────────────
CREATE INDEX idx_combos_branch_id           ON combos (branch_id);
CREATE INDEX idx_combos_is_active           ON combos (is_active);
CREATE INDEX idx_combos_display_order       ON combos (branch_id, display_order);

-- ── combo_products ────────────────────────────────────────────────────────────
CREATE INDEX idx_combo_products_combo       ON combo_products (combo_id);
CREATE INDEX idx_combo_products_product     ON combo_products (product_id);

-- ── promotions ────────────────────────────────────────────────────────────────
CREATE INDEX idx_promotions_branch_id       ON promotions (branch_id);
CREATE INDEX idx_promotions_is_active       ON promotions (is_active);
CREATE INDEX idx_promotions_applies_to      ON promotions (applies_to, target_id);
CREATE INDEX idx_promotions_dates           ON promotions (start_date, end_date)
  WHERE start_date IS NOT NULL OR end_date IS NOT NULL;

-- ── restaurant_visits ─────────────────────────────────────────────────────────
CREATE INDEX idx_visits_user_id             ON restaurant_visits (user_id)      WHERE user_id IS NOT NULL;
CREATE INDEX idx_visits_branch_id           ON restaurant_visits (branch_id);
CREATE INDEX idx_visits_visit_type          ON restaurant_visits (visit_type);
CREATE INDEX idx_visits_visited_at          ON restaurant_visits (visited_at);
-- Búsqueda por ubicación del usuario
CREATE INDEX idx_visits_user_location       ON restaurant_visits USING GIST (user_location) WHERE user_location IS NOT NULL;
-- Historial de un usuario por sucursal (más reciente primero)
CREATE INDEX idx_visits_user_branch         ON restaurant_visits (user_id, branch_id, visited_at DESC)
  WHERE user_id IS NOT NULL;
