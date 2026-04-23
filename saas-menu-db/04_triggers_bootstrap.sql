
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
