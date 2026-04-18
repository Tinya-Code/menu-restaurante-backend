-- ══════════════════════════════════════════════════════════════════════════════
--  07_seed.sql
--  Datos de prueba. Demuestra el funcionamiento de los triggers encadenados
--  y los distintos contextos de usuario (owner vs visitor).
--
--  Ejecutar después de 06_views.sql.
--  ⚠️  Solo para entornos de desarrollo — no ejecutar en producción.
-- ══════════════════════════════════════════════════════════════════════════════


-- ── 1. Super admin del sistema ────────────────────────────────────────────────
INSERT INTO users (firebase_uid, email, display_name, active_context)
VALUES ('firebase-superadmin-001', 'superadmin@platform.com', 'Super Admin', 'visitor');

INSERT INTO user_global_roles (user_id, role_id)
VALUES (
  (SELECT id FROM users WHERE email = 'superadmin@platform.com'),
  (SELECT id FROM global_roles WHERE name = 'super_admin')
);


-- ── 2. Usuario dueño del restaurante ─────────────────────────────────────────
-- Empieza como 'visitor'. El trigger fn_bootstrap_restaurant lo cambia
-- automáticamente a 'owner' cuando crea su restaurante.
INSERT INTO users (firebase_uid, email, display_name, active_context)
VALUES ('df47R6nUfYUgXnQFZ4FjLsA1vq12', 'alejandroleonpedro7@gmail.com', 'Alejandro León', 'visitor');


-- ── 3. Crear el restaurante con plan Free ─────────────────────────────────────
-- El trigger fn_bootstrap_restaurant genera automáticamente:
--   · restaurant_settings (con defaults JSONB documentados)
--   · branches             (Sucursal Principal, is_main=true)
--     → fn_bootstrap_branch genera:
--         · branch_settings  (vacía, hereda del restaurante)
--         · menus            (Menú Principal)
--   · restaurant_members   (Alejandro como 'owner')
--   · users.active_context → cambia de 'visitor' a 'owner'
--   · subscriptions        (trial 14 días)
INSERT INTO restaurants (name, slug, owner_id, plan_id)
VALUES (
  'La Hacienda',
  'la-hacienda',
  (SELECT id FROM users WHERE email = 'alejandroleonpedro7@gmail.com'),
  (SELECT id FROM plans WHERE name = 'Free')
);


-- ── 4. Asignar template 'polleria' a la sucursal principal ────────────────────
UPDATE branches
SET template_id = (SELECT id FROM templates WHERE slug = 'polleria')
WHERE restaurant_id = (SELECT id FROM restaurants WHERE slug = 'la-hacienda')
  AND is_main = true;


-- ── 5. Actualizar configuración del restaurante ───────────────────────────────
-- La app hace esto durante el onboarding del dueño.
UPDATE restaurant_settings
SET
  whatsapp_config = '{"number": "924932128", "message_template": "Hola, me gustaría ordenar:"}',
  order_config    = '{
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


-- ── 6. Categorías y productos ─────────────────────────────────────────────────
INSERT INTO category_types (name, metadata)
VALUES ('Bebidas', '{"icon": "drink", "color": "#3B82F6"}');

INSERT INTO categories (menu_id, type_id, name)
VALUES (
  (
    SELECT m.id FROM menus m
    JOIN branches b     ON b.id  = m.branch_id
    JOIN restaurants r  ON r.id  = b.restaurant_id
    WHERE r.slug = 'la-hacienda' AND b.is_main = true
    LIMIT 1
  ),
  (SELECT id FROM category_types WHERE name = 'Bebidas'),
  'Bebidas Calientes'
);

INSERT INTO products (category_id, name, price, description)
VALUES
  (
    (SELECT id FROM categories WHERE name = 'Bebidas Calientes' LIMIT 1),
    'Café Americano', 12.50, 'Espresso con agua caliente'
  ),
  (
    (SELECT id FROM categories WHERE name = 'Bebidas Calientes' LIMIT 1),
    'Té Verde', 8.00, 'Té verde japonés'
  );


-- ── 7. Combo de prueba ────────────────────────────────────────────────────────
-- El plan Free permite 2 combos — este es el primero.
INSERT INTO combos (branch_id, name, description, price)
VALUES (
  (
    SELECT id FROM branches
    WHERE restaurant_id = (SELECT id FROM restaurants WHERE slug = 'la-hacienda')
      AND is_main = true
  ),
  'Combo Mañanero',
  'Café Americano + Té Verde a precio especial',
  18.00
);

INSERT INTO combo_products (combo_id, product_id, quantity)
VALUES
  (
    (SELECT id FROM combos WHERE name = 'Combo Mañanero' LIMIT 1),
    (SELECT id FROM products WHERE name = 'Café Americano' LIMIT 1),
    1
  ),
  (
    (SELECT id FROM combos WHERE name = 'Combo Mañanero' LIMIT 1),
    (SELECT id FROM products WHERE name = 'Té Verde' LIMIT 1),
    1
  );


-- ── 8. Promoción de prueba ────────────────────────────────────────────────────
-- El plan Free permite 2 promociones — esta es la primera.
INSERT INTO promotions (
  branch_id, name, description,
  discount_type, discount_value,
  applies_to, target_id,
  start_date, end_date
)
VALUES (
  (
    SELECT id FROM branches
    WHERE restaurant_id = (SELECT id FROM restaurants WHERE slug = 'la-hacienda')
      AND is_main = true
  ),
  '20% OFF Bebidas Calientes',
  'Descuento especial en todas las bebidas calientes',
  'percentage', 20,
  'category',
  (SELECT id FROM categories WHERE name = 'Bebidas Calientes' LIMIT 1),
  now(),
  now() + INTERVAL '30 days'
);


-- ── 9. Comensal — contexto visitor ───────────────────────────────────────────
-- María es una usuaria que solo visita restaurantes.
-- No es dueña de ningún restaurante (active_context = 'visitor').
INSERT INTO users (firebase_uid, email, display_name, active_context)
VALUES ('visitor-uid-001', 'comensal@email.com', 'María García', 'visitor');

-- Registrar un checkin en la sucursal principal (Miraflores, Lima)
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

-- Marcar como favorito
SELECT fn_register_visit(
  (SELECT id FROM users WHERE email = 'comensal@email.com'),
  (SELECT id FROM branches
   WHERE restaurant_id = (SELECT id FROM restaurants WHERE slug = 'la-hacienda')
     AND is_main = true),
  'favorite',
  NULL, NULL,
  '{"source": "search_results"}'
);


-- ── 10. Owner visitando como comensal ─────────────────────────────────────────
-- Alejandro (owner de La Hacienda) puede cambiar su contexto a 'visitor'
-- y visitar otros restaurantes. Aquí registramos una visita anónima tipo 'view'
-- en su propio restaurante (válido, son contextos separados).
SELECT fn_register_visit(
  (SELECT id FROM users WHERE email = 'alejandroleonpedro7@gmail.com'),
  (SELECT id FROM branches
   WHERE restaurant_id = (SELECT id FROM restaurants WHERE slug = 'la-hacienda')
     AND is_main = true),
  'view',
  NULL, NULL,
  '{"channel": "web", "referrer": "google"}'
);


-- ── 11. Segunda sucursal (comentado — plan Free tiene límite de 1) ─────────────
-- Para probar, primero subir de plan:
--   SELECT fn_change_plan(
--     (SELECT id FROM restaurants WHERE slug = 'la-hacienda'),
--     (SELECT id FROM plans WHERE name = 'Starter')
--   );
-- Luego crear la sucursal (branch_settings + menú se crean solos):
--   INSERT INTO branches (restaurant_id, name, address, is_main)
--   VALUES (
--     (SELECT id FROM restaurants WHERE slug = 'la-hacienda'),
--     'Sucursal Miraflores',
--     'Av. Larco 800, Miraflores, Lima',
--     false
--   );
-- Sobreescribir WhatsApp solo en esa sucursal:
--   UPDATE branch_settings
--   SET whatsapp_config = '{"number": "51987654321", "message_template": "Hola desde Miraflores"}'
--   WHERE branch_id = (
--     SELECT id FROM branches
--     WHERE restaurant_id = (SELECT id FROM restaurants WHERE slug = 'la-hacienda')
--       AND is_main = false
--     LIMIT 1
--   );
