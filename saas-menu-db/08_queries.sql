-- ══════════════════════════════════════════════════════════════════════════════
--  08_queries.sql
--  Consultas de verificación y ejemplos de uso.
--  Ejecutar después de 07_seed.sql para comprobar que todo está bien.
-- ══════════════════════════════════════════════════════════════════════════════


-- ── Verificar bootstrap automático ───────────────────────────────────────────
-- Muestra todo lo que se creó automáticamente por los triggers al insertar
-- el restaurante: settings, branch, branch_settings, menú, member, suscripción
-- y el contexto del owner actualizado.
SELECT
  r.name                  AS restaurante,
  b.name                  AS sucursal,
  b.is_main,
  bs.id IS NOT NULL       AS tiene_branch_settings,
  m.name                  AS menu,
  rs.id IS NOT NULL       AS tiene_restaurant_settings,
  sub.status              AS suscripcion,
  sub.expires_at          AS trial_expira,
  rm.role                 AS rol_owner,
  u.active_context        AS contexto_owner  -- Debe ser 'owner' tras el bootstrap
FROM restaurants r
JOIN branches b             ON b.restaurant_id  = r.id
JOIN branch_settings bs     ON bs.branch_id     = b.id
JOIN menus m                ON m.branch_id      = b.id
JOIN restaurant_settings rs ON rs.restaurant_id = r.id
JOIN subscriptions sub      ON sub.restaurant_id = r.id
JOIN restaurant_members rm  ON rm.restaurant_id = r.id AND rm.role = 'owner'
JOIN users u                ON u.id = rm.user_id
WHERE r.slug = 'la-hacienda';


-- ── Uso de recursos vs límites del plan ──────────────────────────────────────
-- Muestra cuánto está usando cada sucursal comparado con los límites del plan.
SELECT
  branch_name,
  plan_name,
  used_banners    || ' / ' || COALESCE(max_banners::TEXT,    '∞') AS banners,
  used_combos     || ' / ' || COALESCE(max_combos::TEXT,     '∞') AS combos,
  used_promotions || ' / ' || COALESCE(max_promotions::TEXT, '∞') AS promociones,
  used_products   || ' / ' || COALESCE(max_products::TEXT,   '∞') AS productos,
  used_branches   || ' / ' || COALESCE(max_branches::TEXT,   '∞') AS sucursales
FROM v_plan_usage;


-- ── Configuración efectiva de la sucursal principal ──────────────────────────
-- Muestra la config fusionada: restaurant_settings || branch_settings.
SELECT * FROM get_effective_settings(
  (SELECT id FROM branches
   WHERE restaurant_id = (SELECT id FROM restaurants WHERE slug = 'la-hacienda')
     AND is_main = true)
);


-- ── JSON completo de la sucursal (payload para la app cliente) ───────────────
SELECT get_branch_data(
  (SELECT id FROM branches
   WHERE restaurant_id = (SELECT id FROM restaurants WHERE slug = 'la-hacienda')
     AND is_main = true)
);


-- ── Verificar límites de plan ─────────────────────────────────────────────────
-- ¿Puede la sucursal crear más combos?
SELECT branch_within_plan_limit(
  (SELECT id FROM branches
   WHERE restaurant_id = (SELECT id FROM restaurants WHERE slug = 'la-hacienda')
     AND is_main = true),
  'combos'
) AS puede_crear_combo;  -- false si ya tiene 2 (límite Free)

-- ¿Puede crear más banners?
SELECT branch_within_plan_limit(
  (SELECT id FROM branches
   WHERE restaurant_id = (SELECT id FROM restaurants WHERE slug = 'la-hacienda')
     AND is_main = true),
  'banners'
) AS puede_crear_banner;  -- false si ya tiene 1 (límite Free)


-- ── Verificar acceso de un usuario ───────────────────────────────────────────
-- ¿Alejandro es owner o admin de La Hacienda?
SELECT user_has_access(
  (SELECT id FROM users WHERE email = 'alejandroleonpedro7@gmail.com'),
  (SELECT id FROM restaurants WHERE slug = 'la-hacienda'),
  ARRAY['owner', 'admin']
) AS tiene_acceso;  -- true


-- ── Permisos de todos los usuarios ───────────────────────────────────────────
SELECT * FROM v_user_permissions;

-- Solo el super admin
SELECT * FROM v_user_permissions WHERE email = 'superadmin@platform.com';

-- Solo roles de gestión de La Hacienda
SELECT * FROM v_user_permissions
WHERE restaurant_name = 'La Hacienda';


-- ── Historial de visitas ──────────────────────────────────────────────────────
-- Todas las visitas al restaurante
SELECT
  user_name,
  user_email,
  visit_type,
  visited_at,
  distance_meters,
  branch_name
FROM v_visit_history
WHERE restaurant_slug = 'la-hacienda';

-- Solo checkins (usuario estuvo físicamente cerca)
SELECT * FROM v_visit_history
WHERE restaurant_slug = 'la-hacienda'
  AND visit_type = 'checkin';

-- Visitas de un usuario específico
SELECT * FROM v_visit_history
WHERE user_email = 'comensal@email.com';


-- ── Resumen general de restaurantes ──────────────────────────────────────────
SELECT
  restaurant_name,
  owner_email,
  owner_context,
  plan_name,
  subscription_status,
  subscription_expires,
  branch_count,
  downgrade_at   -- NULL si no hubo downgrade
FROM v_restaurants_overview;


-- ── Menú completo desnormalizado ──────────────────────────────────────────────
SELECT * FROM v_menu_full WHERE restaurant_slug = 'la-hacienda';


-- ── Combos con sus productos ──────────────────────────────────────────────────
SELECT * FROM v_combos_full;


-- ── Promociones vigentes ahora ────────────────────────────────────────────────
SELECT
  name,
  discount_type,
  discount_value,
  applies_to,
  start_date,
  end_date,
  branch_name,
  restaurant_name
FROM v_active_promotions;


-- ── Ejemplo: cambiar de plan (upgrade a Starter) ──────────────────────────────
-- SELECT fn_change_plan(
--   (SELECT id FROM restaurants WHERE slug = 'la-hacienda'),
--   (SELECT id FROM plans WHERE name = 'Starter')
-- );
-- Verificar historial:
-- SELECT plan_id, previous_plan_id, status, downgrade_at FROM subscriptions
-- WHERE restaurant_id = (SELECT id FROM restaurants WHERE slug = 'la-hacienda')
-- ORDER BY created_at DESC;


-- ── Ejemplo: transferir ownership ─────────────────────────────────────────────
-- SELECT fn_transfer_ownership(
--   (SELECT id FROM restaurants WHERE slug = 'la-hacienda'),
--   (SELECT id FROM users WHERE email = 'comensal@email.com')
-- );
-- Verificar:
-- SELECT owner_id, name FROM restaurants WHERE slug = 'la-hacienda';
-- SELECT user_id, role FROM restaurant_members WHERE restaurant_id = (SELECT id FROM restaurants WHERE slug = 'la-hacienda');


INSERT INTO category_types (name, metadata)
VALUES
  -- Sección 1: Inicio del menú
  ('Sección del menú 1', '{
    "section": 1,
    "suggestions": [
      "entradas", "sopas", "ensaladas", "aperitivos",
      "piqueos", "rollitos", "carpaccio", "ceviche",
      "bruschetta", "caldos", "cremas", "tabla de quesos"
    ]
  }'),

  -- Sección 2: Platos principales
  ('Sección del menú 2', '{
    "section": 2,
    "suggestions": [
      "platos de fondo", "especialidades", "pastas", "arroces",
      "carnes", "pollos", "pescados", "mariscos",
      "makis", "tacos", "hamburguesas", "paellas"
    ]
  }'),

  -- Sección 3: Para compartir
  ('Sección del menú 3', '{
    "section": 3,
    "suggestions": [
      "piqueos", "antipastos", "nachos", "alitas",
      "croquetas", "quesadillas", "brochetas", "patacones",
      "chips", "tequeños", "tablas mixtas", "snacks"
    ]
  }'),

  -- Sección 4: Acompañamientos / Salsas
  ('Sección del menú 4', '{
    "section": 4,
    "suggestions": [
      "guarniciones", "papas", "arroces", "purés",
      "verduras", "ensaladas simples", "salsas picantes", "salsas dulces",
      "salsas cremosas", "chimichurri", "guacamole", "panes"
    ]
  }'),

  -- Sección 5: Postres
  ('Sección del menú 5', '{
    "section": 5,
    "suggestions": [
      "postres fríos", "postres calientes", "helados", "tortas",
      "cheesecake", "flanes", "mousses", "pies",
      "dulces típicos", "brownies", "gelatinas", "frutas"
    ]
  }'),

  -- Sección 6: Bebidas
  ('Sección del menú 6', '{
    "section": 6,
    "suggestions": [
      "bebidas frías", "bebidas calientes", "jugos naturales", "limonadas",
      "cafés", "tés", "infusiones", "smoothies",
      "aguas saborizadas", "kombucha", "chicha morada", "emolientes"
    ]
  }'),

  -- Sección 7: Licores
  ('Sección del menú 7', '{
    "section": 7,
    "suggestions": [
      "cervezas", "vinos", "cocteles", "whiskies",
      "rones", "vodkas", "gins", "champagnes",
      "aperitivos", "tequilas", "fernet", "tragos largos"
    ]
  }');
