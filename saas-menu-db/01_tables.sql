
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

