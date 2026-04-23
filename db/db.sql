-- ══════════════════════════════════════════════════════════════════════════════
--  00_extensions.sql
--  Extensiones de PostgreSQL requeridas por el sistema.
--  Ejecutar PRIMERO, antes que cualquier otro archivo SQL.
--
--  Extensiones:
--    · pg_trgm    → búsqueda difusa por trigramas; habilita índices GIN sobre
--                   columnas de texto para LIKE/ILIKE y similitud (similarity())
--    · postgis    → tipo GEOGRAPHY y funciones espaciales (ST_Distance, etc.)
--    · btree_gist → permite EXCLUDE USING btree, necesario para la constraint
--                   de unicidad condicional de la sucursal principal en branches
-- ══════════════════════════════════════════════════════════════════════════════

CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS btree_gist;


-- ── fn_set_updated_at ─────────────────────────────────────────────────────────
-- Trigger BEFORE UPDATE reutilizable que estampa now() en updated_at.
-- Se adjunta como trigger en todas las tablas que exponen ese campo.
CREATE OR REPLACE FUNCTION fn_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


-- ══════════════════════════════════════════════════════════════════════════════
--  01_tables.sql
--  Tablas del sistema en orden estricto de dependencias (FK-safe).
--
--  Jerarquía de entidades:
--    global_roles · category_types · tags · plans · templates
--    → users → user_global_roles
--    → restaurants → restaurant_members → restaurant_tags
--    → subscriptions
--    → branches → branch_settings → menus → categories
--    → products → banners → combos → combo_products
--    → promotions → restaurant_visits
--
--  Decisiones de diseño:
--    · restaurant_settings fue eliminada. La configuración raíz del restaurante
--      solo existía para ser copiada al crear cada sucursal. Ese bootstrap
--      ahora usa constantes en fn_bootstrap_restaurant. branch_settings es la
--      única fuente de verdad de configuración desde el primer INSERT.
--    · products.branch_id reemplaza al anterior products.restaurant_id.
--      La desnormalización era innecesaria: la sucursal ya se obtiene
--      trivialmente por category → menu → branch. Eliminarla alinea el modelo
--      con la jerarquía real y evita inconsistencias entre ambas FKs.
-- ══════════════════════════════════════════════════════════════════════════════


-- ── global_roles ──────────────────────────────────────────────────────────────
-- Roles administrativos de la plataforma (distintos a los roles de restaurante).
-- Controlan el acceso al backoffice y herramientas internas.
-- Son asignados manualmente por super_admins.
--   · super_admin → acceso total sin restricciones
--   · developer   → acceso técnico: logs, debug, configuración interna
--   · support     → atención al cliente y resolución de incidencias
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
-- Catálogo de tipos semánticos para clasificar las categorías de un menú.
-- metadata contiene el número de sección y un array de nombres sugeridos
-- (entradas, fondos, postres, bebidas, etc.) que orientan al restaurante
-- al crear sus propias categorías.
CREATE TABLE category_types (
  id       UUID  PRIMARY KEY DEFAULT gen_random_uuid(),
  name     TEXT  NOT NULL UNIQUE,
  metadata JSONB NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(metadata) = 'object')
);


-- ── tags ──────────────────────────────────────────────────────────────────────
-- Etiquetas libres asociadas a restaurantes para facilitar búsqueda y
-- clasificación en la plataforma (ej: "familiar", "vegetariano", "delivery 24h").
-- La relación N:M se gestiona en restaurant_tags.
CREATE TABLE tags (
  id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL UNIQUE
);


-- ── plans ─────────────────────────────────────────────────────────────────────
-- Planes de suscripción disponibles en la plataforma.
-- Todos los límites (max_*) aplican POR SUCURSAL, no por restaurante.
-- NULL en cualquier límite indica recurso ilimitado para ese plan.
--
--  Free    (S/  0.00) · billing_cycle='forever' · 1 sucursal · nunca vence
--  Starter (S/ 25.00) · billing_cycle='monthly' · 1 sucursal · renueva c/30d
--  Pro     (S/ 64.00) · billing_cycle='monthly' · 3 sucursales · renueva c/30d
--
-- billing_cycle:
--   'forever' → plan gratuito permanente; expires_at = NULL en subscriptions
--   'monthly' → se renueva cada 30 días; si no se paga, el status pasa a 'expired'
CREATE TABLE plans (
  id             UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  name           TEXT          NOT NULL UNIQUE,
  description    TEXT,
  price          NUMERIC(10,2) NOT NULL CHECK (price >= 0),
  billing_cycle  TEXT          NOT NULL DEFAULT 'monthly'
                               CHECK (billing_cycle IN ('forever', 'monthly')),
  max_branches   INTEGER       NOT NULL DEFAULT 1,
  max_products   INTEGER,        -- NULL = sin límite
  max_categories INTEGER,        -- NULL = sin límite
  max_banners    INTEGER,        -- NULL = sin límite
  max_combos     INTEGER,        -- NULL = sin límite
  max_promotions INTEGER,        -- NULL = sin límite
  features       JSONB         NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(features) = 'object'),
  is_active      BOOLEAN       NOT NULL DEFAULT true,
  created_at     TIMESTAMPTZ   NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ   NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_plans_updated_at
  BEFORE UPDATE ON plans
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

INSERT INTO plans
  (name, description, price, billing_cycle, max_branches, max_products,
   max_categories, max_banners, max_combos, max_promotions, features)
VALUES
  (
    'Free',
    'Plan gratuito permanente — 1 sucursal, sin fecha de vencimiento',
    0.00, 'forever', 1, 30, 5, 1, 2, 2,
    '{"whatsapp":true,"banners":true,"combos":true,"promotions":true,"analytics":false,"custom_domain":false}'
  ),
  (
    'Starter',
    'Plan mensual — 1 sucursal, renovación cada 30 días',
    25.00, 'monthly', 1, 100, 20, 5, 10, 10,
    '{"whatsapp":true,"banners":true,"combos":true,"promotions":true,"analytics":false,"custom_domain":false}'
  ),
  (
    'Pro',
    'Plan mensual profesional — hasta 3 sucursales, renovación cada 30 días',
    64.00, 'monthly', 3, 500, 50, 20, 50, 50,
    '{"whatsapp":true,"banners":true,"combos":true,"promotions":true,"analytics":true,"custom_domain":true}'
  );


-- ── templates ─────────────────────────────────────────────────────────────────
-- Plantillas visuales para la interfaz pública de cada sucursal
-- (colores, fuentes, layout). Se asignan a una sucursal al crearla
-- y pueden cambiarse después desde el dashboard.
-- plan_id = NULL indica que la plantilla está disponible para todos los planes.
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

INSERT INTO templates (plan_id, slug, name, description, config)
VALUES
  (
    (SELECT id FROM plans WHERE name = 'Free'),
    'polleria', 'Pollería',
    'Template optimizado para pollerías y parrillas',
    '{"theme":"warm","primary_color":"#D97706","font":"Montserrat","layout":"grid"}'
  ),
  (
    (SELECT id FROM plans WHERE name = 'Free'),
    'chifa', 'Chifa',
    'Template para restaurantes de comida chino-peruana',
    '{"theme":"dark","primary_color":"#DC2626","font":"Poppins","layout":"list"}'
  ),
  (
    (SELECT id FROM plans WHERE name = 'Free'),
    'cevicheria', 'Cevichería',
    'Template para cevicherías y marisquerías',
    '{"theme":"ocean","primary_color":"#0284C7","font":"Inter","layout":"card"}'
  ),
  (
    (SELECT id FROM plans WHERE name = 'Free'),
    'comida-rapida', 'Comida Rápida',
    'Template para fast food y comida rápida',
    '{"theme":"vibrant","primary_color":"#16A34A","font":"Nunito","layout":"grid"}'
  );


-- ── users ─────────────────────────────────────────────────────────────────────
-- Usuarios del sistema: propietarios de restaurante, personal y comensales.
-- La autenticación se delega a Firebase; firebase_uid es el identificador externo.
-- active_context determina la interfaz que el usuario ve al iniciar sesión:
--   'owner'   → dashboard de gestión del restaurante
--   'visitor' → interfaz pública de comensal
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
-- Asignación de roles administrativos de plataforma a usuarios específicos.
-- granted_by registra quién otorgó el rol para trazabilidad de auditoría.
CREATE TABLE user_global_roles (
  user_id    UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role_id    UUID        NOT NULL REFERENCES global_roles(id) ON DELETE CASCADE,
  granted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  granted_by UUID        REFERENCES users(id) ON DELETE SET NULL,
  PRIMARY KEY (user_id, role_id)
);


-- ── restaurants ───────────────────────────────────────────────────────────────
-- Entidad raíz del sistema. Representa el negocio de un restaurante.
-- Al insertar aquí, el trigger fn_bootstrap_restaurant crea en cascada:
--   branches (principal) → branch_settings → menus (principal)
--   → restaurant_members (owner) → subscriptions (según el plan)
-- La configuración operativa no reside en restaurants sino en branch_settings
-- de cada sucursal, que es configuracionalmente independiente desde su creación.
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


-- ── restaurant_members ────────────────────────────────────────────────────────
-- Miembros del equipo de un restaurante con su rol interno de gestión.
-- Un usuario puede pertenecer a múltiples restaurantes con distintos roles.
-- Roles disponibles:
--   'owner' → propietario; acceso total, puede transferir el ownership
--   'admin' → gestión completa de menú, sucursales y configuración
--   'staff' → acceso limitado: consulta y operaciones básicas
-- is_active permite suspender a un miembro sin borrarlo del historial.
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
-- Relación N:M entre restaurantes y tags.
-- Permite etiquetar restaurantes para filtrado y descubrimiento en la plataforma.
CREATE TABLE restaurant_tags (
  restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  tag_id        UUID NOT NULL REFERENCES tags(id)        ON DELETE CASCADE,
  PRIMARY KEY (restaurant_id, tag_id)
);


-- ── subscriptions ─────────────────────────────────────────────────────────────
-- Historial completo de suscripciones de cada restaurante.
-- Cada cambio de plan genera un registro nuevo; el anterior queda como 'expired'.
--
-- Lógica de vencimiento según billing_cycle del plan:
--   'forever' → expires_at = NULL (Free, nunca vence)
--   'monthly' → expires_at = started_at + 30 días
--
-- Cuando un plan mensual no se renueva, su status pasa a 'expired' y el
-- restaurante pierde acceso a funciones premium, pero conserva todos sus datos.
-- previous_plan_id y downgrade_at permiten auditar cambios y degradaciones de plan.
CREATE TABLE subscriptions (
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id    UUID        NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  plan_id          UUID        NOT NULL REFERENCES plans(id) ON DELETE RESTRICT,
  previous_plan_id UUID        REFERENCES plans(id) ON DELETE SET NULL,
  status           TEXT        NOT NULL DEFAULT 'active'
                               CHECK (status IN ('active', 'cancelled', 'expired')),
  started_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at       TIMESTAMPTZ,          -- NULL = plan Free (permanente)
  cancelled_at     TIMESTAMPTZ,
  downgrade_at     TIMESTAMPTZ,          -- registra cuándo ocurrió un downgrade de plan
  metadata         JSONB       NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(metadata) = 'object'),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_subscriptions_updated_at
  BEFORE UPDATE ON subscriptions
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();


-- ── branches ──────────────────────────────────────────────────────────────────
-- Sucursales físicas de un restaurante. Cada restaurante tiene al menos una
-- sucursal principal (is_main = true), creada automáticamente en el bootstrap.
-- Sucursales adicionales requieren un plan que lo permita (Pro: hasta 3).
-- Cada sucursal es configuracionalmente independiente: tiene su propio
-- branch_settings, menús, banners, combos y promociones.
-- El slug es único dentro del mismo restaurante (NULLS NOT DISTINCT permite
-- múltiples sucursales sin slug mientras no haya duplicados entre las nombradas).
-- La constraint EXCLUDE garantiza que solo exista una sucursal principal por restaurante.
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
-- Configuración operativa completa e independiente de cada sucursal.
-- Es la ÚNICA fuente de verdad para la configuración: no existe herencia ni
-- fusión con ninguna tabla padre. Los valores se inicializan desde las
-- constantes de bootstrap en fn_bootstrap_restaurant al crear la primera
-- sucursal, y desde branch_settings del restaurante al crear sucursales
-- adicionales (snapshot en el momento de la creación, sin sincronización posterior).
--
-- logo_cloudinary_id: public_id del asset en Cloudinary, necesario para
-- actualizar o eliminar la imagen sin depender de la URL pública.
--
-- Estructura de los campos JSONB:
--   whatsapp_config → { number, message_template }
--   display_config  → { currency, language }
--   order_config    → { enabled, delivery_fee, pickup_enabled, delivery_enabled,
--                        payment_methods, max_order_quantity, accepts_reservations }
--   business_config → { social_media: {tiktok, facebook, instagram},
--                        business_hours: { [day]: {open, close, isOpen} },
--                        delivery_zones: [] }
--   schedule        → { [day]: { open, close, isOpen } }
--                     Horario específico de esta sucursal; puede diferir del
--                     horario base definido en business_config.
CREATE TABLE branch_settings (
  id                   UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id            UUID        NOT NULL UNIQUE REFERENCES branches(id) ON DELETE CASCADE,
  whatsapp_config      JSONB       NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(whatsapp_config) = 'object'),
  display_config       JSONB       NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(display_config)  = 'object'),
  order_config         JSONB       NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(order_config)    = 'object'),
  business_config      JSONB       NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(business_config) = 'object'),
  logo_url             TEXT,
  logo_cloudinary_id   TEXT,
  description          TEXT,
  schedule             JSONB       NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(schedule) = 'object'),
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_branch_settings_updated_at
  BEFORE UPDATE ON branch_settings
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();


-- ── menus ─────────────────────────────────────────────────────────────────────
-- Menús que pertenecen a una sucursal específica. Una sucursal puede tener
-- múltiples menús (desayuno, almuerzo, carta nocturna, etc.), cada uno con
-- sus propias categorías y productos. Al crear una sucursal, el bootstrap
-- genera automáticamente un "Menú Principal".
-- El nombre del menú es único dentro de la misma sucursal.
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
-- Categorías que agrupan productos dentro de un menú (ej: Entradas, Fondos,
-- Bebidas). Pertenecen a un menú específico y se ordenan mediante display_order.
-- type_id referencia category_types para clasificación semántica y sugerencias
-- de nombre al crear nuevas categorías.
-- El límite de categorías por sucursal lo aplica trg_check_category_limit.
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
-- Platos o ítems del menú pertenecientes a una categoría específica.
-- branch_id está desnormalizado intencionalmente para agilizar consultas
-- que listan todos los productos de una sucursal sin recorrer la jerarquía
-- completa menu → category → product. Se mantiene en sincronía garantizada
-- porque category → menu → branch es una cadena de FKs inmutable: al borrar
-- una branch en cascada se borran también sus products.
--
-- image_url es la URL pública de CDN entregada por Cloudinary.
-- cloudinary_id es el public_id del asset en Cloudinary, necesario para
-- actualizar o eliminar la imagen desde la aplicación.
--
-- El límite de productos por sucursal lo aplica trg_check_product_limit.
-- El orden de los productos no se persiste en la tabla; se define en la
-- capa de aplicación según los requerimientos del restaurante en runtime.
CREATE TABLE products (
  id             UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id      UUID          NOT NULL REFERENCES branches(id)    ON DELETE CASCADE,
  category_id    UUID          NOT NULL REFERENCES categories(id)  ON DELETE CASCADE,
  name           TEXT          NOT NULL,
  description    TEXT,
  price          NUMERIC(10,2) NOT NULL CHECK (price >= 0),
  image_url      TEXT,
  cloudinary_id  TEXT,
  is_available   BOOLEAN       NOT NULL DEFAULT true,
  is_recommended BOOLEAN       NOT NULL DEFAULT false,
  created_at     TIMESTAMPTZ   NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ   NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_products_updated_at
  BEFORE UPDATE ON products
  FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();


-- ── banners ───────────────────────────────────────────────────────────────────
-- Imágenes promocionales mostradas en la interfaz pública de la sucursal
-- (carrusel, cabecera, etc.). Pertenecen a una sucursal específica.
-- cloudinary_id permite eliminar o reemplazar el asset en Cloudinary.
-- El límite de banners por sucursal lo aplica trg_check_banner_limit.
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
-- Ofertas combinadas que agrupan múltiples productos a un precio especial.
-- Pertenecen a una sucursal. Los productos que los componen se detallan en
-- combo_products. cloudinary_id permite gestionar la imagen del combo en Cloudinary.
-- El límite de combos por sucursal lo aplica trg_check_combo_limit.
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
-- Relación N:M entre combos y los productos que los integran.
-- quantity indica cuántas unidades de ese producto incluye el combo.
-- Un producto puede aparecer en múltiples combos, pero solo una vez por combo.
CREATE TABLE combo_products (
  id         UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  combo_id   UUID    NOT NULL REFERENCES combos(id)   ON DELETE CASCADE,
  product_id UUID    NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  quantity   INTEGER NOT NULL DEFAULT 1 CHECK (quantity > 0),
  CONSTRAINT unique_product_per_combo UNIQUE (combo_id, product_id)
);


-- ── promotions ────────────────────────────────────────────────────────────────
-- Descuentos aplicables a distintos recursos de una sucursal.
-- discount_type: 'percentage' (valor <= 100) | 'fixed' (monto absoluto)
-- applies_to determina el alcance del descuento:
--   'product'  → target_id = products.id
--   'category' → target_id = categories.id (aplica a todos sus productos)
--   'combo'    → target_id = combos.id
--   'branch'   → target_id = NULL (descuento general en toda la sucursal)
-- Una promoción está vigente si is_active = true y now() ∈ [start_date, end_date]
-- (extremos nulos significan sin límite en esa dirección).
-- El límite de promociones por sucursal lo aplica trg_check_promotion_limit.
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
-- Registro de interacciones de comensales con sucursales.
-- Permite analizar tráfico, popularidad y engagement por sucursal.
-- user_id es nullable para admitir visitas de usuarios anónimos (no registrados).
-- Tipos de visita:
--   'view'     → el comensal visualizó el menú online
--   'checkin'  → el comensal estuvo físicamente cerca (geofence activo)
--   'order'    → el comensal realizó un pedido via WhatsApp u otro canal
--   'favorite' → el comensal marcó la sucursal como favorita
-- user_location y distance_meters se usan principalmente en eventos 'checkin'.
CREATE TABLE restaurant_visits (
  id              UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID          REFERENCES users(id) ON DELETE SET NULL,
  branch_id       UUID          NOT NULL REFERENCES branches(id) ON DELETE CASCADE,
  visit_type      TEXT          NOT NULL DEFAULT 'view'
                                CHECK (visit_type IN ('view', 'checkin', 'order', 'favorite')),
  visited_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
  user_location   GEOGRAPHY(Point, 4326),
  distance_meters NUMERIC(10,2),
  metadata        JSONB         NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(metadata) = 'object')
);


-- ── category_types: datos de catálogo ────────────────────────────────────────
INSERT INTO category_types (name, metadata) VALUES
  ('Sección del menú 1', '{
    "section": 1,
    "suggestions": [
      "entradas","sopas","ensaladas","aperitivos",
      "piqueos","rollitos","carpaccio","ceviche",
      "bruschetta","caldos","cremas","tabla de quesos"
    ]
  }'),
  ('Sección del menú 2', '{
    "section": 2,
    "suggestions": [
      "platos de fondo","especialidades","pastas","arroces",
      "carnes","pollos","pescados","mariscos",
      "makis","tacos","hamburguesas","paellas"
    ]
  }'),
  ('Sección del menú 3', '{
    "section": 3,
    "suggestions": [
      "piqueos","antipastos","nachos","alitas",
      "croquetas","quesadillas","brochetas","patacones",
      "chips","tequeños","tablas mixtas","snacks"
    ]
  }'),
  ('Sección del menú 4', '{
    "section": 4,
    "suggestions": [
      "guarniciones","papas","arroces","purés",
      "verduras","ensaladas simples","salsas picantes","salsas dulces",
      "salsas cremosas","chimichurri","guacamole","panes"
    ]
  }'),
  ('Sección del menú 5', '{
    "section": 5,
    "suggestions": [
      "postres fríos","postres calientes","helados","tortas",
      "cheesecake","flanes","mousses","pies",
      "dulces típicos","brownies","gelatinas","frutas"
    ]
  }'),
  ('Sección del menú 6', '{
    "section": 6,
    "suggestions": [
      "bebidas frías","bebidas calientes","jugos naturales","limonadas",
      "cafés","tés","infusiones","smoothies",
      "aguas saborizadas","kombucha","chicha morada","emolientes"
    ]
  }'),
  ('Sección del menú 7', '{
    "section": 7,
    "suggestions": [
      "cervezas","vinos","cocteles","whiskies",
      "rones","vodkas","gins","champagnes",
      "aperitivos","tequilas","fernet","tragos largos"
    ]
  }');


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


-- ══════════════════════════════════════════════════════════════════════════════
--  04_triggers_bootstrap.sql
--  Triggers de creación automática en cascada para restaurants y branches.
--  Ejecutar después de 03_triggers_plan_limits.sql.
--
--  Al insertar un restaurante, todo lo necesario se crea automáticamente:
--
--    INSERT restaurants
--      → branches (sucursal principal: is_main = true)
--          → branch_settings   (configuración inicial con valores constantes)
--          → menus             (Menú Principal)
--      → restaurant_members    (owner registrado con rol 'owner')
--      → users.active_context  (cambia a 'owner' si el usuario era 'visitor')
--      → subscriptions         (suscripción activa según el plan asignado)
--
--  Al insertar una sucursal adicional (INSERT branches):
--      → branch_settings   (copia snapshot de la sucursal principal del mismo restaurante)
--      → menus             (Menú Principal vacío)
--
--  restaurant_settings fue eliminada. Sus valores de bootstrap ahora son
--  constantes en fn_bootstrap_restaurant. Para sucursales adicionales,
--  fn_bootstrap_branch copia el branch_settings de la sucursal principal,
--  que es la referencia más actualizada disponible en ese momento.
--
--  Cada sucursal es INDEPENDIENTE desde su creación. Los valores copiados
--  son un snapshot puntual; no existe sincronización posterior entre sucursales.
-- ══════════════════════════════════════════════════════════════════════════════


-- ── fn_bootstrap_restaurant ───────────────────────────────────────────────────
-- Se ejecuta AFTER INSERT en restaurants.
-- Orden: branches (principal) → restaurant_members → active_context → subscriptions.
-- La creación de la branch dispara fn_bootstrap_branch automáticamente,
-- que a su vez crea branch_settings (con valores constantes) y el Menú Principal.
CREATE OR REPLACE FUNCTION fn_bootstrap_restaurant()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_billing_cycle TEXT;
  v_expires_at    TIMESTAMPTZ;
BEGIN
  -- 1. Crear la sucursal principal.
  --    Esto dispara trg_bootstrap_branch → branch_settings + Menú Principal.
  --    trg_check_branch_limit también se dispara pero pasa (conteo = 0).
  INSERT INTO branches (restaurant_id, name, is_main)
  VALUES (NEW.id, 'Sucursal Principal', true);

  -- 2. Registrar al creador como 'owner' en restaurant_members.
  INSERT INTO restaurant_members (user_id, restaurant_id, role)
  VALUES (NEW.owner_id, NEW.id, 'owner');

  -- 3. Cambiar el contexto del owner a 'owner' si aún era 'visitor'.
  UPDATE users
  SET active_context = 'owner'
  WHERE id = NEW.owner_id AND active_context = 'visitor';

  -- 4. Crear la suscripción inicial si el restaurante tiene plan asignado.
  --    Vencimiento según billing_cycle:
  --      'forever' → expires_at = NULL (Free, nunca expira)
  --      'monthly' → expires_at = now() + 30 días
  IF NEW.plan_id IS NOT NULL THEN
    SELECT billing_cycle INTO v_billing_cycle
    FROM plans WHERE id = NEW.plan_id;

    v_expires_at := CASE
      WHEN v_billing_cycle = 'forever' THEN NULL
      ELSE now() + INTERVAL '30 days'
    END;

    INSERT INTO subscriptions (restaurant_id, plan_id, status, expires_at)
    VALUES (NEW.id, NEW.plan_id, 'active', v_expires_at);
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_bootstrap_restaurant
  AFTER INSERT ON restaurants
  FOR EACH ROW EXECUTE FUNCTION fn_bootstrap_restaurant();


-- ── fn_bootstrap_branch ───────────────────────────────────────────────────────
-- Se ejecuta AFTER INSERT en branches (para cualquier sucursal, incluida la principal).
--
-- Para la sucursal principal (primera en crearse durante el bootstrap):
--   branch_settings no existe aún para este restaurante → se usan los valores
--   constantes de configuración inicial definidos en el propio trigger.
--
-- Para sucursales adicionales:
--   Se copia el branch_settings de la sucursal principal como punto de partida,
--   dando al nuevo local la misma configuración base que el local original.
--   El schedule arranca vacío porque cada sucursal define su propio horario.
--
-- Después de este punto, el branch_settings de cada sucursal es completamente
-- independiente: los cambios en una sucursal no afectan a las demás.
CREATE OR REPLACE FUNCTION fn_bootstrap_branch()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_source branch_settings%ROWTYPE;
BEGIN
  -- Intentar obtener el branch_settings de la sucursal principal como fuente
  SELECT bs.* INTO v_source
  FROM branch_settings bs
  JOIN branches b ON b.id = bs.branch_id
  WHERE b.restaurant_id = NEW.restaurant_id AND b.is_main = true
  LIMIT 1;

  -- Si no existe aún (estamos creando la sucursal principal), usar constantes
  INSERT INTO branch_settings (
    branch_id,
    whatsapp_config,
    display_config,
    order_config,
    business_config,
    logo_url,
    logo_cloudinary_id,
    description,
    schedule
  ) VALUES (
    NEW.id,
    COALESCE(v_source.whatsapp_config,
      '{"number": "", "message_template": "Hola, me gustaría ordenar:"}'),
    COALESCE(v_source.display_config,
      '{"currency": "PEN", "language": "es"}'),
    COALESCE(v_source.order_config,
      '{"enabled": true, "delivery_fee": 0, "pickup_enabled": true,
        "delivery_enabled": false, "payment_methods": ["cash", "yape"],
        "max_order_quantity": 15, "accepts_reservations": false}'),
    COALESCE(v_source.business_config,
      '{"social_media": {"tiktok": "", "facebook": "", "instagram": ""},
        "business_hours": {
          "monday":    {"open": "09:00", "close": "22:00", "isOpen": true},
          "tuesday":   {"open": "09:00", "close": "22:00", "isOpen": true},
          "wednesday": {"open": "09:00", "close": "22:00", "isOpen": true},
          "thursday":  {"open": "09:00", "close": "22:00", "isOpen": true},
          "friday":    {"open": "09:00", "close": "23:00", "isOpen": true},
          "saturday":  {"open": "10:00", "close": "23:00", "isOpen": true},
          "sunday":    {"open": "10:00", "close": "18:00", "isOpen": false}
        },
        "delivery_zones": []}'),
    v_source.logo_url,
    v_source.logo_cloudinary_id,
    v_source.description,
    '{}'   -- schedule vacío: cada sucursal define su propio horario operativo
  );

  -- Crear el menú inicial de la sucursal
  INSERT INTO menus (branch_id, name, display_order)
  VALUES (NEW.id, 'Menú Principal', 0);

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_bootstrap_branch
  AFTER INSERT ON branches
  FOR EACH ROW EXECUTE FUNCTION fn_bootstrap_branch();


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