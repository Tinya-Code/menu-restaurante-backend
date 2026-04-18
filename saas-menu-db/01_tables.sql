-- ══════════════════════════════════════════════════════════════════════════════
--  01_tables.sql
--  Todas las tablas en orden de dependencias (sin FKs antes que sus padres).
--  Incluye triggers de updated_at y datos de catálogo (planes, templates, roles).
--
--  Orden de creación:
--    global_roles → category_types → tags → plans → templates
--    → users → user_global_roles → restaurants → restaurant_settings
--    → restaurant_members → restaurant_tags → subscriptions
--    → branches → branch_settings → menus → categories
--    → products → banners → combos → combo_products
--    → promotions → restaurant_visits
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
-- Catálogo de tipos de categoría (Bebidas, Postres, Entradas…).
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
  id             UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  name           TEXT          NOT NULL,
  description    TEXT,
  price          NUMERIC(10,2) NOT NULL CHECK (price >= 0),
  max_branches   INTEGER       NOT NULL DEFAULT 1,
  max_products   INTEGER,
  max_categories INTEGER,
  max_banners    INTEGER,
  max_combos     INTEGER,
  max_promotions INTEGER,
  features       JSONB         NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(features) = 'object'),
  is_active      BOOLEAN       NOT NULL DEFAULT true,
  created_at     TIMESTAMPTZ   NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ   NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_plans_updated_at
  BEFORE UPDATE ON plans
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- Free:    1 banner, 2 combos, 2 promociones, 1 sucursal
-- Starter: 5 banners, 10 combos, 10 promociones, 3 sucursales
-- Pro:     sin límite
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
   59.90, 999, NULL, NULL, NULL, NULL, NULL,
   '{"whatsapp":true,"banners":true,"combos":true,"promotions":true,"analytics":true}');


-- ── templates ─────────────────────────────────────────────────────────────────
-- Se asocian a planes pero se aplican por branch (template_id vive en branches).
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
-- Equivalen a: TEMPLATE_IDS = { POLLERIA, CHIFA, CEVICHERIA, COMIDA_RAPIDA }
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
--
-- active_context: qué interfaz muestra la app en la sesión actual.
--   'owner'   → dashboard de gestión (su restaurante)
--   'visitor' → interfaz de comensal (explorar y visitar restaurantes)
-- El usuario puede cambiar de contexto en cualquier momento desde la app.
-- Al crear un restaurante, el trigger lo cambia automáticamente a 'owner'.
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
-- Pivote entre users y global_roles.
CREATE TABLE user_global_roles (
  user_id    UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role_id    UUID        NOT NULL REFERENCES global_roles(id) ON DELETE CASCADE,
  granted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  granted_by UUID        REFERENCES users(id) ON DELETE SET NULL,
  PRIMARY KEY (user_id, role_id)
);


-- ── restaurants ───────────────────────────────────────────────────────────────
-- Entidad raíz de negocio.
-- owner_id: referencia directa al dueño (no depende de restaurant_members).
-- ON DELETE RESTRICT: no borrar el restaurante si el usuario se borra sin
-- transferir ownership primero (usar fn_transfer_ownership).
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
--
-- Un mismo usuario puede ser owner/admin/staff aquí
-- y simultáneamente comensal en otro restaurante (restaurant_visits).
-- Son contextos completamente separados.
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
-- Historial de planes del restaurante.
-- previous_plan_id + downgrade_at: rastreo de downgrades para grandfathering.
-- Regla de negocio: solo una suscripción activa/trial por restaurante.
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
-- Sucursales del restaurante. Al crear el restaurante se genera una automáticamente.
-- template_id: apariencia visual por sucursal (no por restaurante).
-- slug: URL amigable, único dentro del restaurante (nullable).
-- Límite de creación controlado por trigger en 03_triggers_plan_limits.sql.
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
  -- Solo una sucursal principal por restaurante
  CONSTRAINT unique_main_branch_per_restaurant
    EXCLUDE USING btree (restaurant_id WITH =) WHERE (is_main = true),
  -- Slug único dentro del restaurante (nullable permitido)
  CONSTRAINT unique_branch_slug_per_restaurant
    UNIQUE NULLS NOT DISTINCT (restaurant_id, slug)
);

CREATE TRIGGER trg_branches_updated_at
  BEFORE UPDATE ON branches
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();


-- ── branch_settings ───────────────────────────────────────────────────────────
-- Configuración LOCAL de la sucursal.
-- Herencia: config_efectiva = restaurant_settings || branch_settings (JSONB merge).
-- JSONB vacío ({}) = heredar del restaurante sin sobreescribir nada.
-- TEXT NULL = heredar del restaurante.
CREATE TABLE branch_settings (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id       UUID        NOT NULL UNIQUE REFERENCES branches(id) ON DELETE CASCADE,
  whatsapp_config JSONB       NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(whatsapp_config) = 'object'),
  display_config  JSONB       NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(display_config)  = 'object'),
  order_config    JSONB       NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(order_config)    = 'object'),
  business_config JSONB       NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(business_config) = 'object'),
  logo_url        TEXT,        -- NULL = heredar del restaurante
  description     TEXT,        -- NULL = heredar del restaurante
  schedule        JSONB       NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(schedule) = 'object'),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_branch_settings_updated_at
  BEFORE UPDATE ON branch_settings
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();


-- ── menus ─────────────────────────────────────────────────────────────────────
-- Los menús pertenecen a branches. Cada branch nace con un 'Menú Principal'.
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
-- image_url     → URL pública (Cloudinary CDN).
-- cloudinary_id → para borrar/actualizar el asset en Cloudinary.
-- Límite de creación controlado por trigger en 03_triggers_plan_limits.sql.
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
-- Producto compuesto con precio propio. Pertenece a una branch.
-- Los productos que lo componen se detallan en combo_products.
-- image_url     → URL pública (Cloudinary CDN).
-- cloudinary_id → para gestión del asset en Cloudinary.
-- Límite de creación controlado por trigger en 03_triggers_plan_limits.sql.
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
-- Pivote entre combos y products con cantidad incluida.
CREATE TABLE combo_products (
  id         UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  combo_id   UUID    NOT NULL REFERENCES combos(id)   ON DELETE CASCADE,
  product_id UUID    NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  quantity   INTEGER NOT NULL DEFAULT 1 CHECK (quantity > 0),
  CONSTRAINT unique_product_per_combo UNIQUE (combo_id, product_id)
);


-- ── promotions ────────────────────────────────────────────────────────────────
-- Regla lógica de descuento. Sin imagen propia — usar banners para lo visual.
-- Límite de creación controlado por trigger en 03_triggers_plan_limits.sql.
--
-- applies_to + target_id:
--   'product'  → target_id = products.id
--   'category' → target_id = categories.id
--   'combo'    → target_id = combos.id
--   'branch'   → target_id = NULL (aplica a toda la sucursal)
--
-- discount_type:
--   'percentage' → discount_value es un % (0–100)
--   'fixed'      → discount_value es un monto fijo en la moneda del restaurante
CREATE TABLE promotions (
  id             UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id      UUID          NOT NULL REFERENCES branches(id) ON DELETE CASCADE,
  name           TEXT          NOT NULL,
  description    TEXT,
  discount_type  TEXT          NOT NULL CHECK (discount_type IN ('percentage', 'fixed')),
  discount_value NUMERIC(10,2) NOT NULL CHECK (discount_value > 0),
  applies_to     TEXT          NOT NULL DEFAULT 'branch'
                               CHECK (applies_to IN ('product', 'category', 'combo', 'branch')),
  target_id      UUID,          -- NULL cuando applies_to = 'branch'
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
-- Registra interacciones de comensales con sucursales.
-- user_id nullable → permite visitas anónimas.
-- Un usuario puede tener registros aquí incluso si es owner en otro restaurante.
--
-- visit_type:
--   'view'     → vio el menú online
--   'checkin'  → estuvo físicamente cerca (geofence)
--   'order'    → realizó un pedido (WhatsApp u otro canal)
--   'favorite' → marcó el restaurante como favorito
CREATE TABLE restaurant_visits (
  id              UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID          REFERENCES users(id) ON DELETE SET NULL,
  branch_id       UUID          NOT NULL REFERENCES branches(id) ON DELETE CASCADE,
  visit_type      TEXT          NOT NULL DEFAULT 'view'
                                CHECK (visit_type IN ('view', 'checkin', 'order', 'favorite')),
  visited_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
  user_location   GEOGRAPHY(Point, 4326), -- Ubicación del usuario al visitar
  distance_meters NUMERIC(10,2),          -- Distancia calculada al branch en metros
  metadata        JSONB         NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(metadata) = 'object')
);
