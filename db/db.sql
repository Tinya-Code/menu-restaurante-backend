-- ══════════════════════════════════════════════════════════════════════════════
--  SCHEMA COMPLETO — SaaS Multi-Restaurante con Sucursales
--  Versión: 4.0
--
--  Cambios respecto a v3.0:
--
--  1. LÍMITES DE PLAN enforced a nivel DB:
--     Triggers BEFORE INSERT en combos, banners, promotions y branches
--     que llaman a branch_within_plan_limit() y hacen RAISE EXCEPTION.
--
--  2. HISTORIAL DE PLAN / DOWNGRADE:
--     subscriptions ahora tiene previous_plan_id y downgrade_at.
--     Función fn_handle_plan_downgrade() para gestionar el downgrade.
--     Vista v_plan_usage para ver consumo actual vs límites.
--
--  3. SEPARACIÓN DE ROLES — restaurant_members solo roles internos:
--     owner / admin / staff  →  restaurant_members (gestión interna)
--     Un mismo user puede ser owner en restaurante A y comensal en B.
--
--  4. COMENSALES — tabla dedicada restaurant_visits:
--     Registra visitas/interacciones de usuarios externos con restaurantes.
--     Campos: user_id, branch_id, visited_at, user_location, distance_meters.
--     Un mismo user puede ser owner de su restaurante y comensal en otro.
--
--  5. CONTEXTO DE SESIÓN — users.active_context:
--     Cada usuario tiene un contexto activo: 'owner' | 'visitor'.
--     Permite al mismo usuario cambiar de interfaz sin cambiar de cuenta.
--     La app usa esto para saber qué dashboard mostrar.
--
--  Decisiones de diseño:
--
--  A. template_id vive en branches, no en restaurants.
--  B. restaurant_members = roles internos únicamente (owner/admin/staff).
--  C. restaurants.owner_id referencia directa al dueño.
--  D. Herencia de config: restaurant_settings || branch_settings (JSONB merge).
--  E. menus, banners, combos y promotions pertenecen a branches.
--  F. promotions es una regla lógica — sin imagen (usar banners para visual).
--  G. combo_products vincula combos con products + cantidad.
--  H. Los límites del plan se validan en DB (triggers) Y en app (doble seguro).
--  I. Un user puede tener contexto 'owner' y simultáneamente ser comensal
--     en otro restaurante — son flujos completamente separados.
-- ══════════════════════════════════════════════════════════════════════════════


-- ── Extensiones ───────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS btree_gist; -- Necesario para EXCLUDE en branches


-- ══════════════════════════════════════════════════════════════════════════════
--  FUNCIÓN GLOBAL: updated_at automático
-- ══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


-- ══════════════════════════════════════════════════════════════════════════════
--  TABLAS — en orden de dependencias
-- ══════════════════════════════════════════════════════════════════════════════


-- ── global_roles ──────────────────────────────────────────────────────────────
-- Roles del sistema (plataforma). Catálogo fijo, no de restaurante.
CREATE TABLE global_roles (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT        NOT NULL UNIQUE,
  description TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO global_roles (name, description) VALUES
  ('super_admin', 'Acceso total a la plataforma'),
  ('developer',   'Acceso técnico y de depuración'),
  ('support',     'Atención al cliente y resolución de incidencias');


-- ── category_types ────────────────────────────────────────────────────────────
CREATE TABLE category_types (
  id       UUID  PRIMARY KEY DEFAULT gen_random_uuid(),
  name     TEXT  NOT NULL UNIQUE,
  metadata JSONB NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(metadata) = 'object')
);


-- ── tags ──────────────────────────────────────────────────────────────────────
CREATE TABLE tags (
  id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL UNIQUE
);


-- ── plans ─────────────────────────────────────────────────────────────────────
-- Todos los max_* aplican POR SUCURSAL, no por restaurante total.
-- NULL = sin límite.
CREATE TABLE plans (
  id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  name             TEXT          NOT NULL,
  description      TEXT,
  price            NUMERIC(10,2) NOT NULL CHECK (price >= 0),
  max_branches     INTEGER       NOT NULL DEFAULT 1,
  max_products     INTEGER,
  max_categories   INTEGER,
  max_banners      INTEGER,
  max_combos       INTEGER,
  max_promotions   INTEGER,
  features         JSONB         NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(features) = 'object'),
  is_active        BOOLEAN       NOT NULL DEFAULT true,
  created_at       TIMESTAMPTZ   NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ   NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_plans_updated_at
  BEFORE UPDATE ON plans
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

INSERT INTO plans (name, description, price, max_branches, max_products, max_categories, max_banners, max_combos, max_promotions, features)
VALUES
  ('Free',
   'Plan gratuito — 1 sucursal',
   0.00, 1, 50, 10, 1, 2, 2,
   '{"whatsapp":true,"banners":true,"combos":true,"promotions":true,"analytics":false}'),

  ('Starter',
   'Plan inicial',
   24.90, 3, 200, 50, 5, 10, 10,
   '{"whatsapp":true,"banners":true,"combos":true,"promotions":true,"analytics":false}'),

  ('Pro',
   'Plan profesional',
   59.90, 5, NULL, NULL, NULL, NULL, NULL,
   '{"whatsapp":true,"banners":true,"combos":true,"promotions":true,"analytics":true}');


-- ── templates ─────────────────────────────────────────────────────────────────
-- Se asocian a planes pero se aplican por branch.
-- plan_id = NULL → disponible para todos los planes.
CREATE TABLE templates (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id     UUID        REFERENCES plans(id) ON DELETE SET NULL,
  slug        TEXT        NOT NULL UNIQUE,
  name        TEXT        NOT NULL,
  description TEXT,
  preview_url TEXT,
  config      JSONB       NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(config) = 'object'),
  is_active   BOOLEAN     NOT NULL DEFAULT true,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_templates_updated_at
  BEFORE UPDATE ON templates
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- Templates por defecto — disponibles en plan Free
INSERT INTO templates (plan_id, slug, name, description, config)
VALUES
  (
    (SELECT id FROM plans WHERE name = 'Free'),
    'polleria',
    'Pollería',
    'Template optimizado para pollerías y parrillas',
    '{"theme":"warm","primary_color":"#D97706","font":"Montserrat","layout":"grid"}'
  ),
  (
    (SELECT id FROM plans WHERE name = 'Free'),
    'chifa',
    'Chifa',
    'Template para restaurantes de comida chino-peruana',
    '{"theme":"dark","primary_color":"#DC2626","font":"Poppins","layout":"list"}'
  ),
  (
    (SELECT id FROM plans WHERE name = 'Free'),
    'cevicheria',
    'Cevichería',
    'Template para cevicherías y marisquerías',
    '{"theme":"ocean","primary_color":"#0284C7","font":"Inter","layout":"card"}'
  ),
  (
    (SELECT id FROM plans WHERE name = 'Free'),
    'comida-rapida',
    'Comida Rápida',
    'Template para fast food y comida rápida',
    '{"theme":"vibrant","primary_color":"#16A34A","font":"Nunito","layout":"grid"}'
  );


-- ── users ─────────────────────────────────────────────────────────────────────
-- Un mismo usuario puede ser dueño de su restaurante Y comensal en otro.
-- active_context determina qué interfaz muestra la app en cada sesión:
--   'owner'   → dashboard de gestión (su restaurante)
--   'visitor' → interfaz de comensal (explorar y visitar restaurantes)
-- El usuario puede cambiar de contexto en cualquier momento desde la app.
CREATE TABLE users (
  id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  firebase_uid   TEXT        UNIQUE,
  email          TEXT        NOT NULL,
  phone          TEXT,
  display_name   TEXT,
  active_context TEXT        NOT NULL DEFAULT 'visitor'
                             CHECK (active_context IN ('owner', 'visitor')),
  is_active      BOOLEAN     NOT NULL DEFAULT true,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_users_updated_at
  BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();


-- ── user_global_roles ─────────────────────────────────────────────────────────
CREATE TABLE user_global_roles (
  user_id    UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role_id    UUID        NOT NULL REFERENCES global_roles(id) ON DELETE CASCADE,
  granted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  granted_by UUID        REFERENCES users(id) ON DELETE SET NULL,
  PRIMARY KEY (user_id, role_id)
);


-- ── restaurants ───────────────────────────────────────────────────────────────
-- Entidad raíz de negocio. owner_id: referencia directa al dueño.
-- RESTRICT: no borrar el restaurante si se borra el usuario sin transferir ownership.
CREATE TABLE restaurants (
  id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name       TEXT        NOT NULL,
  slug       TEXT        NOT NULL UNIQUE,
  owner_id   UUID        NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  plan_id    UUID        REFERENCES plans(id) ON DELETE SET NULL,
  phone      TEXT,
  address    TEXT,
  location   GEOGRAPHY(Point, 4326),
  is_active  BOOLEAN     NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_restaurants_updated_at
  BEFORE UPDATE ON restaurants
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();


-- ── restaurant_settings ───────────────────────────────────────────────────────
-- Configuración GLOBAL del restaurante.
-- Las sucursales sobreescriben campos individuales en branch_settings.
--
-- Estructura de referencia JSONB:
--
-- whatsapp_config:
--   { "number": "924932128", "message_template": "Hola, me gustaría ordenar:" }
--
-- display_config:
--   { "currency": "PEN", "language": "es" }
--
-- order_config:
--   {
--     "enabled": true,
--     "delivery_fee": 5.0,
--     "pickup_enabled": true,
--     "delivery_enabled": false,
--     "payment_methods": ["cash", "card", "yape", "plin"],
--     "max_order_quantity": 15,
--     "accepts_reservations": true
--   }
--
-- business_config:
--   {
--     "social_media": {
--       "tiktok": "@restaurante_oficial",
--       "facebook": "https://facebook.com/restaurante",
--       "instagram": "@restaurante_chef"
--     },
--     "business_hours": {
--       "monday":    { "open": "09:00", "close": "22:00", "isOpen": true },
--       "tuesday":   { "open": "09:00", "close": "22:00", "isOpen": true },
--       "wednesday": { "open": "09:00", "close": "22:00", "isOpen": true },
--       "thursday":  { "open": "09:00", "close": "22:00", "isOpen": true },
--       "friday":    { "open": "09:00", "close": "23:00", "isOpen": true },
--       "saturday":  { "open": "10:00", "close": "23:00", "isOpen": true },
--       "sunday":    { "open": "10:00", "close": "18:00", "isOpen": true }
--     },
--     "delivery_zones": []
--   }
CREATE TABLE restaurant_settings (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id   UUID        NOT NULL UNIQUE REFERENCES restaurants(id) ON DELETE CASCADE,
  whatsapp_config JSONB       NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(whatsapp_config) = 'object'),
  display_config  JSONB       NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(display_config)  = 'object'),
  order_config    JSONB       NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(order_config)    = 'object'),
  business_config JSONB       NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(business_config) = 'object'),
  logo_url        TEXT,
  description     TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_restaurant_settings_updated_at
  BEFORE UPDATE ON restaurant_settings
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();


-- ── restaurant_members ────────────────────────────────────────────────────────
-- SOLO roles INTERNOS de gestión: owner / admin / staff.
-- NO incluye comensales — eso va en restaurant_visits.
-- Un mismo usuario puede ser:
--   · owner/admin/staff en restaurant_members de su restaurante
--   · comensal (registrado en restaurant_visits) en otro restaurante
--   · ambas cosas al mismo tiempo — son contextos separados
CREATE TABLE restaurant_members (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  restaurant_id UUID        NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  role          TEXT        NOT NULL DEFAULT 'staff'
                            CHECK (role IN ('owner', 'admin', 'staff')),
  is_active     BOOLEAN     NOT NULL DEFAULT true,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT unique_member_per_restaurant UNIQUE (user_id, restaurant_id)
);

CREATE TRIGGER trg_restaurant_members_updated_at
  BEFORE UPDATE ON restaurant_members
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();


-- ── restaurant_tags ───────────────────────────────────────────────────────────
CREATE TABLE restaurant_tags (
  restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  tag_id        UUID NOT NULL REFERENCES tags(id)        ON DELETE CASCADE,
  PRIMARY KEY (restaurant_id, tag_id)
);


-- ── subscriptions ─────────────────────────────────────────────────────────────
-- Historial de planes. previous_plan_id y downgrade_at permiten rastrear
-- cambios de plan y aplicar políticas de grandfathering en la app.
-- Regla: solo puede haber una suscripción activa/trial por restaurante.
CREATE TABLE subscriptions (
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id    UUID        NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  plan_id          UUID        NOT NULL REFERENCES plans(id) ON DELETE RESTRICT,
  previous_plan_id UUID        REFERENCES plans(id) ON DELETE SET NULL,
  status           TEXT        NOT NULL DEFAULT 'trial'
                               CHECK (status IN ('active', 'cancelled', 'expired', 'trial')),
  started_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at       TIMESTAMPTZ,
  cancelled_at     TIMESTAMPTZ,
  downgrade_at     TIMESTAMPTZ, -- Fecha en que se aplicó el downgrade (si aplica)
  metadata         JSONB       NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(metadata) = 'object'),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_subscriptions_updated_at
  BEFORE UPDATE ON subscriptions
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();


-- ── branches ──────────────────────────────────────────────────────────────────
-- Sucursales del restaurante.
-- template_id: apariencia visual por sucursal.
-- slug: URL amigable, único dentro del restaurante.
CREATE TABLE branches (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id UUID        NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  template_id   UUID        REFERENCES templates(id) ON DELETE SET NULL,
  name          TEXT        NOT NULL DEFAULT 'Sucursal Principal',
  slug          TEXT,
  phone         TEXT,
  address       TEXT,
  location      GEOGRAPHY(Point, 4326),
  is_main       BOOLEAN     NOT NULL DEFAULT false,
  is_active     BOOLEAN     NOT NULL DEFAULT true,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT unique_main_branch_per_restaurant
    EXCLUDE USING btree (restaurant_id WITH =) WHERE (is_main = true),
  CONSTRAINT unique_branch_slug_per_restaurant
    UNIQUE NULLS NOT DISTINCT (restaurant_id, slug)
);

CREATE TRIGGER trg_branches_updated_at
  BEFORE UPDATE ON branches
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();


-- ── branch_settings ───────────────────────────────────────────────────────────
-- Configuración LOCAL de la sucursal.
-- Modelo de herencia: efectivo = restaurant_settings || branch_settings
-- JSONB vacío ({}) = heredar del restaurante.
-- TEXT NULL = heredar del restaurante.
CREATE TABLE branch_settings (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id       UUID        NOT NULL UNIQUE REFERENCES branches(id) ON DELETE CASCADE,
  whatsapp_config JSONB       NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(whatsapp_config) = 'object'),
  display_config  JSONB       NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(display_config)  = 'object'),
  order_config    JSONB       NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(order_config)    = 'object'),
  business_config JSONB       NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(business_config) = 'object'),
  logo_url        TEXT,
  description     TEXT,
  schedule        JSONB       NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(schedule) = 'object'),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_branch_settings_updated_at
  BEFORE UPDATE ON branch_settings
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();


-- ── menus ─────────────────────────────────────────────────────────────────────
CREATE TABLE menus (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id     UUID        NOT NULL REFERENCES branches(id) ON DELETE CASCADE,
  name          TEXT        NOT NULL DEFAULT 'Menú Principal',
  description   TEXT,
  is_active     BOOLEAN     NOT NULL DEFAULT true,
  display_order INTEGER     NOT NULL DEFAULT 0,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT unique_menu_name_per_branch UNIQUE (branch_id, name)
);

CREATE TRIGGER trg_menus_updated_at
  BEFORE UPDATE ON menus
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();


-- ── categories ────────────────────────────────────────────────────────────────
CREATE TABLE categories (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  menu_id       UUID        NOT NULL REFERENCES menus(id) ON DELETE CASCADE,
  type_id       UUID        REFERENCES category_types(id) ON DELETE SET NULL,
  name          TEXT        NOT NULL,
  description   TEXT,
  display_order INTEGER     NOT NULL DEFAULT 0,
  is_active     BOOLEAN     NOT NULL DEFAULT true,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT unique_category_name_per_menu UNIQUE (menu_id, name)
);

CREATE TRIGGER trg_categories_updated_at
  BEFORE UPDATE ON categories
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();


-- ── products ──────────────────────────────────────────────────────────────────
-- image_url     → URL pública (Cloudinary CDN).
-- cloudinary_id → ID del asset en Cloudinary para borrar/actualizar.
CREATE TABLE products (
  id            UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  category_id   UUID          NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
  name          TEXT          NOT NULL,
  description   TEXT,
  price         NUMERIC(10,2) NOT NULL CHECK (price >= 0),
  image_url     TEXT,
  cloudinary_id TEXT,
  is_available  BOOLEAN       NOT NULL DEFAULT true,
  is_recommended BOOLEAN NOT NULL DEFAULT false;
  created_at    TIMESTAMPTZ   NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ   NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_products_updated_at
  BEFORE UPDATE ON products
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();


-- ── banners ───────────────────────────────────────────────────────────────────
-- Límite controlado por trigger (max_banners del plan).
CREATE TABLE banners (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id     UUID        NOT NULL REFERENCES branches(id) ON DELETE CASCADE,
  image_url     TEXT        NOT NULL,
  cloudinary_id TEXT,
  link_url      TEXT,
  description   TEXT,
  display_order INTEGER     NOT NULL DEFAULT 0,
  is_active     BOOLEAN     NOT NULL DEFAULT true,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_banners_updated_at
  BEFORE UPDATE ON banners
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();


-- ── combos ────────────────────────────────────────────────────────────────────
-- Límite controlado por trigger (max_combos del plan).
CREATE TABLE combos (
  id            UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id     UUID          NOT NULL REFERENCES branches(id) ON DELETE CASCADE,
  name          TEXT          NOT NULL,
  description   TEXT,
  price         NUMERIC(10,2) NOT NULL CHECK (price >= 0),
  image_url     TEXT,
  cloudinary_id TEXT,
  is_active     BOOLEAN       NOT NULL DEFAULT true,
  display_order INTEGER       NOT NULL DEFAULT 0,
  created_at    TIMESTAMPTZ   NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ   NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_combos_updated_at
  BEFORE UPDATE ON combos
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();


-- ── combo_products ────────────────────────────────────────────────────────────
CREATE TABLE combo_products (
  id         UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  combo_id   UUID    NOT NULL REFERENCES combos(id)   ON DELETE CASCADE,
  product_id UUID    NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  quantity   INTEGER NOT NULL DEFAULT 1 CHECK (quantity > 0),
  CONSTRAINT unique_product_per_combo UNIQUE (combo_id, product_id)
);


-- ── promotions ────────────────────────────────────────────────────────────────
-- Regla lógica de descuento. Sin imagen propia — usar banners para visual.
-- Límite controlado por trigger (max_promotions del plan).
--
-- applies_to + target_id:
--   'product'  → target_id = products.id
--   'category' → target_id = categories.id
--   'combo'    → target_id = combos.id
--   'branch'   → target_id = NULL (aplica a toda la sucursal)
CREATE TABLE promotions (
  id             UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id      UUID          NOT NULL REFERENCES branches(id) ON DELETE CASCADE,
  name           TEXT          NOT NULL,
  description    TEXT,
  discount_type  TEXT          NOT NULL CHECK (discount_type IN ('percentage', 'fixed')),
  discount_value NUMERIC(10,2) NOT NULL CHECK (discount_value > 0),
  applies_to     TEXT          NOT NULL DEFAULT 'branch'
                               CHECK (applies_to IN ('product', 'category', 'combo', 'branch')),
  target_id      UUID,
  start_date     TIMESTAMPTZ,
  end_date       TIMESTAMPTZ,
  is_active      BOOLEAN       NOT NULL DEFAULT true,
  created_at     TIMESTAMPTZ   NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ   NOT NULL DEFAULT now(),
  CONSTRAINT check_percentage_max
    CHECK (discount_type <> 'percentage' OR discount_value <= 100),
  CONSTRAINT check_date_range
    CHECK (end_date IS NULL OR start_date IS NULL OR end_date > start_date)
);

CREATE TRIGGER trg_promotions_updated_at
  BEFORE UPDATE ON promotions
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();


-- ── restaurant_visits ─────────────────────────────────────────────────────────
-- Registra interacciones de comensales con restaurantes/sucursales.
-- user_id puede ser NULL para visitas anónimas (solo ubicación).
-- Un mismo user puede tener entradas aquí para restaurantes donde él mismo
-- es owner/admin en otro contexto — esto es completamente válido.
--
-- visit_type:
--   'view'      → el usuario vio el menú del restaurante (online)
--   'checkin'   → el usuario estuvo físicamente cerca (geofence)
--   'order'     → el usuario realizó un pedido (WhatsApp u otro canal)
--   'favorite'  → el usuario marcó el restaurante como favorito
CREATE TABLE restaurant_visits (
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          UUID        REFERENCES users(id) ON DELETE SET NULL,
  branch_id        UUID        NOT NULL REFERENCES branches(id) ON DELETE CASCADE,
  visit_type       TEXT        NOT NULL DEFAULT 'view'
                               CHECK (visit_type IN ('view', 'checkin', 'order', 'favorite')),
  visited_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- Ubicación del usuario al momento de la visita (si disponible)
  user_location    GEOGRAPHY(Point, 4326),
  -- Distancia calculada al branch en metros (se puede calcular y guardar)
  distance_meters  NUMERIC(10,2),
  -- Metadata flexible: canal, dispositivo, referrer, etc.
  metadata         JSONB       NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(metadata) = 'object')
);


-- ══════════════════════════════════════════════════════════════════════════════
--  ÍNDICES
-- ══════════════════════════════════════════════════════════════════════════════

-- users
CREATE UNIQUE INDEX idx_users_email_lower    ON users (LOWER(email));
CREATE INDEX idx_users_firebase_uid          ON users (firebase_uid)     WHERE firebase_uid IS NOT NULL;
CREATE INDEX idx_users_phone                 ON users (phone)            WHERE phone IS NOT NULL;
CREATE INDEX idx_users_active_context        ON users (active_context);
CREATE INDEX idx_users_created_at            ON users (created_at);

-- user_global_roles
CREATE INDEX idx_user_global_roles_user_id   ON user_global_roles (user_id);
CREATE INDEX idx_user_global_roles_role_id   ON user_global_roles (role_id);

-- plans
CREATE INDEX idx_plans_is_active             ON plans (is_active);
CREATE INDEX idx_plans_created_at            ON plans (created_at);

-- templates
CREATE INDEX idx_templates_plan_id           ON templates (plan_id);
CREATE INDEX idx_templates_is_active         ON templates (is_active);
CREATE INDEX idx_templates_slug              ON templates (slug);

-- restaurants
CREATE INDEX idx_restaurants_owner_id        ON restaurants (owner_id);
CREATE INDEX idx_restaurants_plan_id         ON restaurants (plan_id);
CREATE INDEX idx_restaurants_slug            ON restaurants (slug);
CREATE INDEX idx_restaurants_is_active       ON restaurants (is_active);
CREATE INDEX idx_restaurants_created_at      ON restaurants (created_at);
CREATE INDEX idx_restaurants_name            ON restaurants USING GIN (name gin_trgm_ops);

-- restaurant_settings
CREATE INDEX idx_restaurant_settings_wa      ON restaurant_settings USING GIN (whatsapp_config);
CREATE INDEX idx_restaurant_settings_disp    ON restaurant_settings USING GIN (display_config);

-- restaurant_members
CREATE INDEX idx_restaurant_members_user     ON restaurant_members (user_id);
CREATE INDEX idx_restaurant_members_rest     ON restaurant_members (restaurant_id);
CREATE INDEX idx_restaurant_members_role     ON restaurant_members (role);
-- Consulta frecuente: todos los restaurantes donde el user es owner o admin
CREATE INDEX idx_restaurant_members_mgr      ON restaurant_members (user_id, role)
  WHERE role IN ('owner', 'admin');

-- restaurant_tags
CREATE INDEX idx_restaurant_tags_tag_id      ON restaurant_tags (tag_id);

-- subscriptions
CREATE INDEX idx_subscriptions_restaurant    ON subscriptions (restaurant_id);
CREATE INDEX idx_subscriptions_plan          ON subscriptions (plan_id);
CREATE INDEX idx_subscriptions_prev_plan     ON subscriptions (previous_plan_id) WHERE previous_plan_id IS NOT NULL;
CREATE INDEX idx_subscriptions_status        ON subscriptions (status);
CREATE INDEX idx_subscriptions_expires       ON subscriptions (expires_at)       WHERE expires_at IS NOT NULL;
CREATE INDEX idx_subscriptions_downgrade     ON subscriptions (downgrade_at)     WHERE downgrade_at IS NOT NULL;

-- branches
CREATE INDEX idx_branches_restaurant_id      ON branches (restaurant_id);
CREATE INDEX idx_branches_template_id        ON branches (template_id)           WHERE template_id IS NOT NULL;
CREATE INDEX idx_branches_is_active          ON branches (is_active);
CREATE INDEX idx_branches_is_main            ON branches (restaurant_id)         WHERE is_main = true;
CREATE INDEX idx_branches_location           ON branches USING GIST (location)   WHERE location IS NOT NULL;

-- branch_settings
CREATE INDEX idx_branch_settings_wa          ON branch_settings USING GIN (whatsapp_config);
CREATE INDEX idx_branch_settings_schedule    ON branch_settings USING GIN (schedule);

-- menus
CREATE INDEX idx_menus_branch_id             ON menus (branch_id);
CREATE INDEX idx_menus_is_active             ON menus (is_active);
CREATE INDEX idx_menus_display_order         ON menus (branch_id, display_order);

-- categories
CREATE INDEX idx_categories_menu_id          ON categories (menu_id);
CREATE INDEX idx_categories_type_id          ON categories (type_id)             WHERE type_id IS NOT NULL;
CREATE INDEX idx_categories_name             ON categories USING GIN (name gin_trgm_ops);
CREATE INDEX idx_categories_is_active        ON categories (is_active);
CREATE INDEX idx_categories_display_order    ON categories (menu_id, display_order);

-- products
CREATE INDEX idx_products_category_id        ON products (category_id);
CREATE INDEX idx_products_name               ON products USING GIN (name gin_trgm_ops);
CREATE INDEX idx_products_description        ON products USING GIN (description gin_trgm_ops) WHERE description IS NOT NULL;
CREATE INDEX idx_products_is_available       ON products (is_available);
CREATE INDEX idx_products_display_order      ON products (category_id, display_order);
CREATE INDEX idx_products_price              ON products (price);
CREATE INDEX idx_products_created_at         ON products (created_at);

-- banners
CREATE INDEX idx_banners_branch_id           ON banners (branch_id);
CREATE INDEX idx_banners_is_active           ON banners (is_active);
CREATE INDEX idx_banners_display_order       ON banners (branch_id, display_order);

-- combos
CREATE INDEX idx_combos_branch_id            ON combos (branch_id);
CREATE INDEX idx_combos_is_active            ON combos (is_active);
CREATE INDEX idx_combos_display_order        ON combos (branch_id, display_order);

-- combo_products
CREATE INDEX idx_combo_products_combo        ON combo_products (combo_id);
CREATE INDEX idx_combo_products_product      ON combo_products (product_id);

-- promotions
CREATE INDEX idx_promotions_branch_id        ON promotions (branch_id);
CREATE INDEX idx_promotions_is_active        ON promotions (is_active);
CREATE INDEX idx_promotions_applies_to       ON promotions (applies_to, target_id);
CREATE INDEX idx_promotions_dates            ON promotions (start_date, end_date)
  WHERE start_date IS NOT NULL OR end_date IS NOT NULL;

-- restaurant_visits
CREATE INDEX idx_visits_user_id              ON restaurant_visits (user_id)      WHERE user_id IS NOT NULL;
CREATE INDEX idx_visits_branch_id            ON restaurant_visits (branch_id);
CREATE INDEX idx_visits_visit_type           ON restaurant_visits (visit_type);
CREATE INDEX idx_visits_visited_at           ON restaurant_visits (visited_at);
-- Búsqueda de visitas cercanas por ubicación
CREATE INDEX idx_visits_user_location        ON restaurant_visits USING GIST (user_location) WHERE user_location IS NOT NULL;
-- Consulta frecuente: historial de un usuario por restaurante
CREATE INDEX idx_visits_user_branch          ON restaurant_visits (user_id, branch_id, visited_at DESC)
  WHERE user_id IS NOT NULL;


-- ══════════════════════════════════════════════════════════════════════════════
--  FUNCIÓN: Verificar límite de plan
-- ══════════════════════════════════════════════════════════════════════════════
-- Retorna true si se puede crear más del recurso dado en la branch.
-- resource: 'banners' | 'combos' | 'promotions' | 'products' | 'categories'
-- Para 'branches' usar restaurant_within_branch_limit().
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

  EXECUTE format(
    'SELECT p.max_%I FROM plans p
     JOIN restaurants r ON r.plan_id = p.id
     WHERE r.id = $1',
    p_resource
  ) INTO v_plan_limit USING v_restaurant_id;

  -- NULL = sin límite
  IF v_plan_limit IS NULL THEN
    RETURN true;
  END IF;

  EXECUTE format(
    'SELECT COUNT(*) FROM %I WHERE branch_id = $1',
    p_resource
  ) INTO v_current_count USING p_branch_id;

  RETURN v_current_count < v_plan_limit;
END;
$$;


-- ── Límite de sucursales por restaurante ──────────────────────────────────────
CREATE OR REPLACE FUNCTION restaurant_within_branch_limit(p_restaurant_id UUID)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_plan_limit    INTEGER;
  v_current_count INTEGER;
BEGIN
  SELECT p.max_branches INTO v_plan_limit
  FROM plans p JOIN restaurants r ON r.plan_id = p.id
  WHERE r.id = p_restaurant_id;

  IF v_plan_limit IS NULL THEN RETURN true; END IF;

  SELECT COUNT(*) INTO v_current_count
  FROM branches WHERE restaurant_id = p_restaurant_id AND is_active = true;

  RETURN v_current_count < v_plan_limit;
END;
$$;


-- ══════════════════════════════════════════════════════════════════════════════
--  TRIGGERS DE LÍMITE DE PLAN (enforced a nivel DB)
--  Doble seguro: la app también debe verificar antes de insertar.
-- ══════════════════════════════════════════════════════════════════════════════

-- ── Límite de banners ─────────────────────────────────────────────────────────
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


-- ── Límite de combos ──────────────────────────────────────────────────────────
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


-- ── Límite de promociones ─────────────────────────────────────────────────────
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


-- ── Límite de sucursales ──────────────────────────────────────────────────────
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


-- ══════════════════════════════════════════════════════════════════════════════
--  TRIGGERS DE CREACIÓN AUTOMÁTICA (bootstrap)
--  Cadena: restaurant INSERT → settings + branch(main) + member + subscription
--          branch INSERT     → branch_settings + menu principal
-- ══════════════════════════════════════════════════════════════════════════════

-- ── Al crear un restaurant ────────────────────────────────────────────────────
-- NOTA: el trigger de límite de branches (trg_check_branch_limit) se dispara
-- también cuando este trigger inserta la sucursal principal. Para evitar falso
-- positivo en el primer INSERT (restaurante nuevo, 0 branches), el trigger de
-- límite cuenta branches activas ANTES del INSERT actual, por lo que el primer
-- insert siempre pasa (0 < max_branches).
CREATE OR REPLACE FUNCTION fn_bootstrap_restaurant()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  -- 1. Configuración global con defaults estructurados
  INSERT INTO restaurant_settings (
    restaurant_id,
    whatsapp_config,
    display_config,
    order_config,
    business_config
  ) VALUES (
    NEW.id,
    '{"number": "", "message_template": "Hola, me gustaría ordenar:"}',
    '{"currency": "PEN", "language": "es"}',
    '{
      "enabled": true,
      "delivery_fee": 0,
      "pickup_enabled": true,
      "delivery_enabled": false,
      "payment_methods": ["cash", "yape"],
      "max_order_quantity": 15,
      "accepts_reservations": false
    }',
    '{
      "social_media": {"tiktok": "", "facebook": "", "instagram": ""},
      "business_hours": {
        "monday":    {"open": "09:00", "close": "22:00", "isOpen": true},
        "tuesday":   {"open": "09:00", "close": "22:00", "isOpen": true},
        "wednesday": {"open": "09:00", "close": "22:00", "isOpen": true},
        "thursday":  {"open": "09:00", "close": "22:00", "isOpen": true},
        "friday":    {"open": "09:00", "close": "23:00", "isOpen": true},
        "saturday":  {"open": "10:00", "close": "23:00", "isOpen": true},
        "sunday":    {"open": "10:00", "close": "18:00", "isOpen": false}
      },
      "delivery_zones": []
    }'
  );

  -- 2. Sucursal principal (dispara fn_bootstrap_branch automáticamente)
  --    NOTA: también dispara trg_check_branch_limit, pero al ser el primer
  --    branch del restaurante, el conteo es 0 y siempre pasa.
  INSERT INTO branches (restaurant_id, name, is_main)
  VALUES (NEW.id, 'Sucursal Principal', true);

  -- 3. Registrar al owner en restaurant_members
  INSERT INTO restaurant_members (user_id, restaurant_id, role)
  VALUES (NEW.owner_id, NEW.id, 'owner');

  -- 4. Cambiar contexto del owner a 'owner' si aún está en 'visitor'
  UPDATE users SET active_context = 'owner'
  WHERE id = NEW.owner_id AND active_context = 'visitor';

  -- 5. Suscripción trial si tiene plan asignado
  IF NEW.plan_id IS NOT NULL THEN
    INSERT INTO subscriptions (restaurant_id, plan_id, status, expires_at)
    VALUES (NEW.id, NEW.plan_id, 'trial', now() + INTERVAL '14 days');
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_bootstrap_restaurant
  AFTER INSERT ON restaurants
  FOR EACH ROW EXECUTE FUNCTION fn_bootstrap_restaurant();


-- ── Al crear una branch ───────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_bootstrap_branch()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO branch_settings (branch_id) VALUES (NEW.id);
  INSERT INTO menus (branch_id, name, display_order) VALUES (NEW.id, 'Menú Principal', 0);
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_bootstrap_branch
  AFTER INSERT ON branches
  FOR EACH ROW EXECUTE FUNCTION fn_bootstrap_branch();


-- ══════════════════════════════════════════════════════════════════════════════
--  FUNCIONES DE UTILIDAD
-- ══════════════════════════════════════════════════════════════════════════════


-- ── Configuración efectiva de una sucursal ────────────────────────────────────
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
    rs.whatsapp_config || bs.whatsapp_config,
    rs.display_config  || bs.display_config,
    rs.order_config    || bs.order_config,
    rs.business_config || bs.business_config,
    COALESCE(bs.logo_url,    rs.logo_url),
    COALESCE(bs.description, rs.description),
    bs.schedule
  FROM branches b
  JOIN restaurant_settings rs ON rs.restaurant_id = b.restaurant_id
  JOIN branch_settings      bs ON bs.branch_id    = b.id
  WHERE b.id = p_branch_id;
$$;


-- ── JSON completo de una sucursal (para la app cliente) ───────────────────────
-- Incluye: branch, restaurant, settings, template, banners, combos,
-- promociones vigentes y menús con categorías y productos.
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
-- Uso: SELECT user_has_access('user-uuid', 'restaurant-uuid', ARRAY['owner','admin']);
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


-- ── Transferir ownership de un restaurante ────────────────────────────────────
-- Actualiza restaurants.owner_id y restaurant_members en una transacción.
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

  -- Actualizar restaurants
  UPDATE restaurants SET owner_id = p_new_owner_id WHERE id = p_restaurant_id;

  -- Degradar al ex-owner a admin
  UPDATE restaurant_members
  SET role = 'admin'
  WHERE user_id = v_old_owner_id AND restaurant_id = p_restaurant_id;

  -- Insertar o promover al nuevo owner
  INSERT INTO restaurant_members (user_id, restaurant_id, role)
  VALUES (p_new_owner_id, p_restaurant_id, 'owner')
  ON CONFLICT (user_id, restaurant_id)
  DO UPDATE SET role = 'owner', is_active = true;

  -- Actualizar contexto del nuevo owner
  UPDATE users SET active_context = 'owner'
  WHERE id = p_new_owner_id AND active_context = 'visitor';
END;
$$;


-- ── Cambiar plan de un restaurante (con registro de downgrade) ────────────────
-- Registra el cambio en subscriptions con previous_plan_id y downgrade_at.
-- La política de qué hacer con recursos excedentes se maneja en la app.
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

  -- Expirar suscripción activa/trial actual
  UPDATE subscriptions
  SET status = 'expired', updated_at = now()
  WHERE restaurant_id = p_restaurant_id
    AND status IN ('active', 'trial');

  -- Crear nueva suscripción
  INSERT INTO subscriptions (
    restaurant_id, plan_id, previous_plan_id,
    status, expires_at, downgrade_at
  ) VALUES (
    p_restaurant_id,
    p_new_plan_id,
    v_current_plan_id,
    'active',
    NULL,
    CASE WHEN v_is_downgrade THEN now() ELSE NULL END
  );

  -- Actualizar plan en el restaurante
  UPDATE restaurants SET plan_id = p_new_plan_id WHERE id = p_restaurant_id;
END;
$$;


-- ── Registrar visita de un comensal ───────────────────────────────────────────
-- Uso: SELECT fn_register_visit('user-uuid', 'branch-uuid', 'checkin', ST_Point(-77.03, -12.04)::geography, 150.5);
CREATE OR REPLACE FUNCTION fn_register_visit(
  p_user_id         UUID,
  p_branch_id       UUID,
  p_visit_type      TEXT DEFAULT 'view',
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


-- ══════════════════════════════════════════════════════════════════════════════
--  VISTAS
-- ══════════════════════════════════════════════════════════════════════════════

-- Vista: restaurantes con plan, suscripción y conteo de sucursales
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
GROUP BY r.id, u.email, u.active_context, p.name, p.max_branches,
         p.max_products, p.max_banners, p.max_combos, p.max_promotions,
         s.status, s.expires_at, s.downgrade_at, s.previous_plan_id;


-- Vista: uso actual de recursos vs límites del plan (por sucursal)
CREATE OR REPLACE VIEW v_plan_usage AS
SELECT
  r.id              AS restaurant_id,
  r.name            AS restaurant_name,
  b.id              AS branch_id,
  b.name            AS branch_name,
  b.is_main,
  p.name            AS plan_name,
  -- Banners
  p.max_banners,
  (SELECT COUNT(*) FROM banners    WHERE branch_id = b.id) AS used_banners,
  -- Combos
  p.max_combos,
  (SELECT COUNT(*) FROM combos     WHERE branch_id = b.id) AS used_combos,
  -- Promociones
  p.max_promotions,
  (SELECT COUNT(*) FROM promotions WHERE branch_id = b.id) AS used_promotions,
  -- Productos (a través de categorías y menús)
  p.max_products,
  (SELECT COUNT(*) FROM products pr
   JOIN categories c ON c.id = pr.category_id
   JOIN menus m ON m.id = c.menu_id
   WHERE m.branch_id = b.id) AS used_products,
  -- Categorías
  p.max_categories,
  (SELECT COUNT(*) FROM categories c
   JOIN menus m ON m.id = c.menu_id
   WHERE m.branch_id = b.id) AS used_categories,
  -- Sucursales (total por restaurante)
  p.max_branches,
  (SELECT COUNT(*) FROM branches WHERE restaurant_id = r.id AND is_active = true) AS used_branches
FROM restaurants r
JOIN branches b    ON b.restaurant_id = r.id AND b.is_active = true
LEFT JOIN plans p  ON p.id = r.plan_id;


-- Vista: todos los permisos de un usuario (globales + internos)
-- NO incluye visitas de comensal — eso es restaurant_visits.
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


-- Vista: historial de visitas de comensales con datos del branch
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
LEFT JOIN users u      ON u.id  = rv.user_id
JOIN branches b        ON b.id  = rv.branch_id
JOIN restaurants r     ON r.id  = b.restaurant_id
ORDER BY rv.visited_at DESC;


-- Vista: menú completo desnormalizado (reporting y exports)
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
  p.display_order AS product_order
FROM restaurants r
JOIN branches b          ON b.restaurant_id = r.id  AND b.is_active = true
JOIN menus m             ON m.branch_id = b.id       AND m.is_active = true
JOIN categories c        ON c.menu_id = m.id         AND c.is_active = true
LEFT JOIN category_types ct ON ct.id = c.type_id
LEFT JOIN products p     ON p.category_id = c.id     AND p.is_available = true
WHERE r.is_active = true
ORDER BY r.id, b.is_main DESC, m.display_order, c.display_order, p.display_order;


-- Vista: combos con sus productos
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


-- Vista: promociones vigentes
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


-- ══════════════════════════════════════════════════════════════════════════════
--  DATOS DE PRUEBA
-- ══════════════════════════════════════════════════════════════════════════════

-- 1. Super admin
INSERT INTO users (firebase_uid, email, display_name, active_context)
VALUES ('firebase-superadmin-001', 'superadmin@platform.com', 'Super Admin', 'visitor');

INSERT INTO user_global_roles (user_id, role_id)
VALUES (
  (SELECT id FROM users WHERE email = 'superadmin@platform.com'),
  (SELECT id FROM global_roles WHERE name = 'super_admin')
);

-- 2. Usuario dueño — empieza como visitor, pasa a owner al crear el restaurante
INSERT INTO users (firebase_uid, email, display_name, active_context)
VALUES ('df47R6nUfYUgXnQFZ4FjLsA1vq12', 'alejandroleonpedro7@gmail.com', 'Alejandro León', 'visitor');

-- 3. Crear restaurante
--    Triggers generan automáticamente:
--      restaurant_settings (con defaults JSONB)
--      branches (Sucursal Principal, is_main=true)
--        → branch_settings + menus (Menú Principal)
--      restaurant_members (Alejandro como owner)
--      users.active_context → 'owner'
--      subscriptions (trial 14 días)
INSERT INTO restaurants (name, slug, owner_id, plan_id)
VALUES (
  'La Hacienda',
  'la-hacienda',
  (SELECT id FROM users WHERE email = 'alejandroleonpedro7@gmail.com'),
  (SELECT id FROM plans WHERE name = 'Free')
);

-- 4. Asignar template 'polleria' a la sucursal principal
UPDATE branches
SET template_id = (SELECT id FROM templates WHERE slug = 'polleria')
WHERE restaurant_id = (SELECT id FROM restaurants WHERE slug = 'la-hacienda')
  AND is_main = true;

-- 5. Actualizar configuración del restaurante
UPDATE restaurant_settings
SET
  whatsapp_config = '{"number": "924932128", "message_template": "Hola, me gustaría ordenar:"}',
  order_config = '{
    "enabled": true,
    "delivery_fee": 5.0,
    "pickup_enabled": true,
    "delivery_enabled": false,
    "payment_methods": ["cash", "card", "yape", "plin"],
    "max_order_quantity": 15,
    "accepts_reservations": true
  }',
  business_config = '{
    "social_media": {
      "tiktok":    "@lahacienda_oficial",
      "facebook":  "https://facebook.com/lahacienda",
      "instagram": "@lahacienda_chef"
    },
    "business_hours": {
      "monday":    {"open": "09:00", "close": "22:00", "isOpen": true},
      "tuesday":   {"open": "09:00", "close": "22:00", "isOpen": true},
      "wednesday": {"open": "09:00", "close": "22:00", "isOpen": true},
      "thursday":  {"open": "09:00", "close": "22:00", "isOpen": true},
      "friday":    {"open": "10:00", "close": "23:00", "isOpen": true},
      "saturday":  {"open": "10:00", "close": "23:00", "isOpen": true},
      "sunday":    {"open": "10:00", "close": "18:00", "isOpen": true}
    },
    "delivery_zones": []
  }'
WHERE restaurant_id = (SELECT id FROM restaurants WHERE slug = 'la-hacienda');

-- 6. Categorías y productos
INSERT INTO category_types (name, metadata)
VALUES ('Bebidas', '{"icon": "drink", "color": "#3B82F6"}');

INSERT INTO categories (menu_id, type_id, name)
VALUES (
  (SELECT m.id FROM menus m
   JOIN branches b ON b.id = m.branch_id
   JOIN restaurants r ON r.id = b.restaurant_id
   WHERE r.slug = 'la-hacienda' AND b.is_main = true LIMIT 1),
  (SELECT id FROM category_types WHERE name = 'Bebidas'),
  'Bebidas Calientes'
);

INSERT INTO products (category_id, name, price, description)
VALUES
  ((SELECT id FROM categories WHERE name = 'Bebidas Calientes' LIMIT 1),
   'Café Americano', 12.50, 'Espresso con agua caliente'),
  ((SELECT id FROM categories WHERE name = 'Bebidas Calientes' LIMIT 1),
   'Té Verde', 8.00, 'Té verde japonés');

-- 7. Combo de prueba
INSERT INTO combos (branch_id, name, description, price)
VALUES (
  (SELECT id FROM branches
   WHERE restaurant_id = (SELECT id FROM restaurants WHERE slug = 'la-hacienda')
     AND is_main = true),
  'Combo Mañanero', 'Café + Té a precio especial', 18.00
);

INSERT INTO combo_products (combo_id, product_id, quantity)
VALUES
  ((SELECT id FROM combos WHERE name = 'Combo Mañanero' LIMIT 1),
   (SELECT id FROM products WHERE name = 'Café Americano' LIMIT 1), 1),
  ((SELECT id FROM combos WHERE name = 'Combo Mañanero' LIMIT 1),
   (SELECT id FROM products WHERE name = 'Té Verde' LIMIT 1), 1);

-- 8. Promoción de prueba
INSERT INTO promotions (branch_id, name, description, discount_type, discount_value, applies_to, target_id, start_date, end_date)
VALUES (
  (SELECT id FROM branches
   WHERE restaurant_id = (SELECT id FROM restaurants WHERE slug = 'la-hacienda')
     AND is_main = true),
  '20% OFF Bebidas Calientes', 'Descuento especial',
  'percentage', 20, 'category',
  (SELECT id FROM categories WHERE name = 'Bebidas Calientes' LIMIT 1),
  now(), now() + INTERVAL '30 days'
);

-- 9. Usuario que es comensal en La Hacienda
--    (podría ser dueño de otro restaurante — no hay conflicto)
INSERT INTO users (firebase_uid, email, display_name, active_context)
VALUES ('visitor-uid-001', 'comensal@email.com', 'María García', 'visitor');

-- Registrar visita como checkin con ubicación (Miraflores, Lima)
SELECT fn_register_visit(
  (SELECT id FROM users WHERE email = 'comensal@email.com'),
  (SELECT id FROM branches
   WHERE restaurant_id = (SELECT id FROM restaurants WHERE slug = 'la-hacienda')
     AND is_main = true),
  'checkin',
  ST_Point(-77.0282, -12.1191)::geography,
  85.5,
  '{"device": "mobile", "channel": "app"}'
);

-- Alejandro también visita otro restaurante como comensal (contexto visitor)
-- Esto demuestra que un owner puede ser comensal en otro lugar
SELECT fn_register_visit(
  (SELECT id FROM users WHERE email = 'alejandroleonpedro7@gmail.com'),
  (SELECT id FROM branches
   WHERE restaurant_id = (SELECT id FROM restaurants WHERE slug = 'la-hacienda')
     AND is_main = true),
  'view',
  NULL, NULL,
  '{"channel": "web", "referrer": "google"}'
);

-- 10. Segunda sucursal (branch_settings y menú se crean automáticamente)
--     El trigger de límite de branches verificará: 1 < max_branches(Free=1) → FALLA
--     Para probar sin error, usar plan Starter o Pro primero:
-- SELECT fn_change_plan((SELECT id FROM restaurants WHERE slug = 'la-hacienda'), (SELECT id FROM plans WHERE name = 'Starter'));
-- Luego:
-- INSERT INTO branches (restaurant_id, name, address, is_main)
-- VALUES ((SELECT id FROM restaurants WHERE slug = 'la-hacienda'), 'Sucursal Miraflores', 'Av. Larco 800, Miraflores, Lima', false);


-- ══════════════════════════════════════════════════════════════════════════════
--  CONSULTAS DE VERIFICACIÓN
-- ══════════════════════════════════════════════════════════════════════════════

-- Todo lo generado automáticamente por los triggers
SELECT
  r.name                  AS restaurante,
  b.name                  AS sucursal,
  b.is_main,
  bs.id IS NOT NULL       AS tiene_branch_settings,
  m.name                  AS menu,
  rs.id IS NOT NULL       AS tiene_restaurant_settings,
  sub.status              AS suscripcion,
  rm.role                 AS rol_owner,
  u.active_context        AS contexto_owner
FROM restaurants r
JOIN branches b             ON b.restaurant_id = r.id
JOIN branch_settings bs     ON bs.branch_id = b.id
JOIN menus m                ON m.branch_id = b.id
JOIN restaurant_settings rs ON rs.restaurant_id = r.id
JOIN subscriptions sub      ON sub.restaurant_id = r.id
JOIN restaurant_members rm  ON rm.restaurant_id = r.id AND rm.role = 'owner'
JOIN users u                ON u.id = rm.user_id
WHERE r.slug = 'la-hacienda';

-- Uso de recursos vs límites del plan
SELECT * FROM v_plan_usage WHERE restaurant_slug = (
  SELECT slug FROM restaurants WHERE slug = 'la-hacienda'
);
-- Forma directa:
SELECT * FROM v_plan_usage;

-- Configuración efectiva de la sucursal principal
SELECT * FROM get_effective_settings(
  (SELECT id FROM branches
   WHERE restaurant_id = (SELECT id FROM restaurants WHERE slug = 'la-hacienda')
     AND is_main = true)
);

-- JSON completo de la sucursal
SELECT get_branch_data(
  (SELECT id FROM branches
   WHERE restaurant_id = (SELECT id FROM restaurants WHERE slug = 'la-hacienda')
     AND is_main = true)
);

-- ¿Puede la sucursal crear más combos?
SELECT branch_within_plan_limit(
  (SELECT id FROM branches
   WHERE restaurant_id = (SELECT id FROM restaurants WHERE slug = 'la-hacienda')
     AND is_main = true),
  'combos'
);

-- ¿Alejandro tiene acceso como owner o admin?
SELECT user_has_access(
  (SELECT id FROM users WHERE email = 'alejandroleonpedro7@gmail.com'),
  (SELECT id FROM restaurants WHERE slug = 'la-hacienda'),
  ARRAY['owner', 'admin']
);

-- Permisos globales y locales de todos los usuarios
SELECT * FROM v_user_permissions;

-- Historial de visitas al restaurante
SELECT * FROM v_visit_history WHERE restaurant_slug = 'la-hacienda';

-- Resumen de restaurantes con plan y uso
SELECT * FROM v_restaurants_overview;

-- Menú completo
SELECT * FROM v_menu_full WHERE restaurant_slug = 'la-hacienda';

-- Combos con productos
SELECT * FROM v_combos_full;

-- Promociones vigentes
SELECT * FROM v_active_promotions;