-- ══════════════════════════════════════════════════════════════════════════════
--  04_triggers_bootstrap.sql
--  Triggers de creación automática en cascada.
--
--  Cadena al insertar un restaurant:
--    INSERT restaurants
--      → restaurant_settings  (con defaults JSONB documentados)
--      → branches             (Sucursal Principal, is_main=true)
--          → branch_settings  (vacía, hereda todo del restaurante)
--          → menus            (Menú Principal)
--      → restaurant_members   (owner)
--      → users.active_context (cambia a 'owner' si era 'visitor')
--      → subscriptions        (trial 14 días, si tiene plan)
--
--  Cadena al insertar una branch:
--    INSERT branches
--      → branch_settings      (vacía, hereda todo del restaurante)
--      → menus                (Menú Principal)
--
--  Ejecutar después de 03_triggers_plan_limits.sql.
-- ══════════════════════════════════════════════════════════════════════════════


-- ── Bootstrap al crear un restaurant ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_bootstrap_restaurant()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  -- 1. Configuración global con defaults estructurados
  --    La app puede sobreescribir estos valores después del onboarding.
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

  -- 2. Sucursal principal
  --    Dispara fn_bootstrap_branch → branch_settings + menus.
  --    También dispara trg_check_branch_limit, pero como es la primera branch
  --    del restaurante, el conteo es 0 → siempre pasa.
  INSERT INTO branches (restaurant_id, name, is_main)
  VALUES (NEW.id, 'Sucursal Principal', true);

  -- 3. Registrar al owner en restaurant_members (rol interno)
  INSERT INTO restaurant_members (user_id, restaurant_id, role)
  VALUES (NEW.owner_id, NEW.id, 'owner');

  -- 4. Cambiar el contexto del owner a 'owner' si aún estaba como 'visitor'
  UPDATE users
  SET active_context = 'owner'
  WHERE id = NEW.owner_id AND active_context = 'visitor';

  -- 5. Suscripción trial 14 días si el restaurante tiene plan asignado
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


-- ── Bootstrap al crear una branch ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_bootstrap_branch()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  -- 1. Configuración local vacía (JSONB {}) → hereda todo del restaurante
  INSERT INTO branch_settings (branch_id)
  VALUES (NEW.id);

  -- 2. Menú principal de la sucursal
  INSERT INTO menus (branch_id, name, display_order)
  VALUES (NEW.id, 'Menú Principal', 0);

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_bootstrap_branch
  AFTER INSERT ON branches
  FOR EACH ROW EXECUTE FUNCTION fn_bootstrap_branch();
