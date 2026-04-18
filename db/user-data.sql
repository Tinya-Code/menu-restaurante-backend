WITH 
-- Primero, obtener datos planos para evitar repeticiones costosas
users_data AS (
  SELECT 
    u.*,
    (SELECT jsonb_agg(
        jsonb_build_object(
          'role_id', gr.id,
          'role_name', gr.name,
          'granted_at', ugr.granted_at,
          'granted_by', ugr.granted_by
        )
      )
      FROM user_global_roles ugr
      JOIN global_roles gr ON gr.id = ugr.role_id
      WHERE ugr.user_id = u.id
    ) AS global_roles_json,
    (SELECT jsonb_agg(
        jsonb_build_object(
          'restaurant_id', r.id,
          'restaurant_name', r.name,
          'restaurant_slug', r.slug,
          'role', rm.role,
          'is_active', rm.is_active,
          'joined_at', rm.created_at
        )
      )
      FROM restaurant_members rm
      JOIN restaurants r ON r.id = rm.restaurant_id
      WHERE rm.user_id = u.id
    ) AS memberships_json,
    (SELECT jsonb_agg(
        jsonb_build_object(
          'visit_id', rv.id,
          'visit_type', rv.visit_type,
          'visited_at', rv.visited_at,
          'distance_meters', rv.distance_meters,
          'metadata', rv.metadata,
          'user_location', CASE WHEN rv.user_location IS NOT NULL THEN ST_AsGeoJSON(rv.user_location)::jsonb ELSE NULL END,
          'branch_id', b.id,
          'branch_name', b.name,
          'restaurant_id', r.id,
          'restaurant_name', r.name,
          'restaurant_slug', r.slug
        )
        ORDER BY rv.visited_at DESC
      )
      FROM restaurant_visits rv
      JOIN branches b ON b.id = rv.branch_id
      JOIN restaurants r ON r.id = b.restaurant_id
      WHERE rv.user_id = u.id
    ) AS visits_json
  FROM users u
),

restaurants_data AS (
  SELECT 
    r.*,
    -- restaurant_settings
    (SELECT to_jsonb(rs) FROM restaurant_settings rs WHERE rs.restaurant_id = r.id) AS settings_json,
    -- members (con información del usuario)
    (SELECT jsonb_agg(
        jsonb_build_object(
          'user_id', u.id,
          'user_email', u.email,
          'user_display_name', u.display_name,
          'role', rm.role,
          'is_active', rm.is_active,
          'joined_at', rm.created_at
        )
      )
      FROM restaurant_members rm
      JOIN users u ON u.id = rm.user_id
      WHERE rm.restaurant_id = r.id
    ) AS members_json,
    -- subscriptions
    (SELECT jsonb_agg(to_jsonb(s)) FROM subscriptions s WHERE s.restaurant_id = r.id) AS subscriptions_json,
    -- tags
    (SELECT jsonb_agg(to_jsonb(t))
      FROM restaurant_tags rt
      JOIN tags t ON t.id = rt.tag_id
      WHERE rt.restaurant_id = r.id
    ) AS tags_json,
    -- branches (con todo dentro)
    (SELECT jsonb_agg(
        jsonb_build_object(
          'id', b.id,
          'name', b.name,
          'slug', b.slug,
          'phone', b.phone,
          'address', b.address,
          'location', CASE WHEN b.location IS NOT NULL THEN ST_AsGeoJSON(b.location)::jsonb ELSE NULL END,
          'is_main', b.is_main,
          'is_active', b.is_active,
          'created_at', b.created_at,
          'updated_at', b.updated_at,
          'template', (SELECT to_jsonb(t) FROM templates t WHERE t.id = b.template_id),
          'branch_settings', (SELECT to_jsonb(bs) FROM branch_settings bs WHERE bs.branch_id = b.id),
          'menus', (SELECT jsonb_agg(
                      jsonb_build_object(
                        'id', m.id,
                        'name', m.name,
                        'description', m.description,
                        'is_active', m.is_active,
                        'display_order', m.display_order,
                        'categories', (SELECT jsonb_agg(
                                        jsonb_build_object(
                                          'id', c.id,
                                          'name', c.name,
                                          'description', c.description,
                                          'display_order', c.display_order,
                                          'is_active', c.is_active,
                                          'type', (SELECT to_jsonb(ct) FROM category_types ct WHERE ct.id = c.type_id),
                                          'products', (SELECT jsonb_agg(to_jsonb(p) ORDER BY p.created_at)
                                                       FROM products p
                                                       WHERE p.category_id = c.id AND p.is_available = true)
                                        ) ORDER BY c.display_order
                                      )
                                      FROM categories c
                                      WHERE c.menu_id = m.id AND c.is_active = true
                        )
                      ) ORDER BY m.display_order
                    )
                    FROM menus m
                    WHERE m.branch_id = b.id AND m.is_active = true
          ),
          'combos', (SELECT jsonb_agg(
                      jsonb_build_object(
                        'id', co.id,
                        'name', co.name,
                        'description', co.description,
                        'price', co.price,
                        'image_url', co.image_url,
                        'is_active', co.is_active,
                        'display_order', co.display_order,
                        'products', (SELECT jsonb_agg(
                                      jsonb_build_object(
                                        'product_id', p.id,
                                        'product_name', p.name,
                                        'product_price', p.price,
                                        'quantity', cp.quantity
                                      )
                                    )
                                    FROM combo_products cp
                                    JOIN products p ON p.id = cp.product_id
                                    WHERE cp.combo_id = co.id
                        )
                      ) ORDER BY co.display_order
                    )
                    FROM combos co
                    WHERE co.branch_id = b.id AND co.is_active = true
          ),
          'banners', (SELECT jsonb_agg(
                        jsonb_build_object(
                          'id', bn.id,
                          'image_url', bn.image_url,
                          'link_url', bn.link_url,
                          'description', bn.description,
                          'display_order', bn.display_order,
                          'is_active', bn.is_active
                        ) ORDER BY bn.display_order
                      )
                      FROM banners bn
                      WHERE bn.branch_id = b.id AND bn.is_active = true
          ),
          'promotions', (SELECT jsonb_agg(to_jsonb(pr))
                         FROM promotions pr
                         WHERE pr.branch_id = b.id AND pr.is_active = true
          ),
          'visits', (SELECT jsonb_agg(
                        jsonb_build_object(
                          'visit_id', rv.id,
                          'user_id', rv.user_id,
                          'user_email', vu.email,
                          'visit_type', rv.visit_type,
                          'visited_at', rv.visited_at,
                          'distance_meters', rv.distance_meters,
                          'metadata', rv.metadata,
                          'user_location', CASE WHEN rv.user_location IS NOT NULL THEN ST_AsGeoJSON(rv.user_location)::jsonb ELSE NULL END
                        )
                      )
                      FROM restaurant_visits rv
                      LEFT JOIN users vu ON vu.id = rv.user_id
                      WHERE rv.branch_id = b.id
          )
        )
      )
      FROM branches b
      WHERE b.restaurant_id = r.id AND b.is_active = true
    ) AS branches_json
  FROM restaurants r
)

-- Construcción final del JSON completo
SELECT jsonb_pretty(
  jsonb_build_object(
    'users', (SELECT jsonb_agg(
                jsonb_build_object(
                  'id', u.id,
                  'firebase_uid', u.firebase_uid,
                  'email', u.email,
                  'phone', u.phone,
                  'display_name', u.display_name,
                  'active_context', u.active_context,
                  'is_active', u.is_active,
                  'created_at', u.created_at,
                  'updated_at', u.updated_at,
                  'global_roles', COALESCE(u.global_roles_json, '[]'::jsonb),
                  'restaurant_memberships', COALESCE(u.memberships_json, '[]'::jsonb),
                  'restaurant_visits', COALESCE(u.visits_json, '[]'::jsonb)
                )
              )
              FROM users_data u
    ),
    'restaurants', (SELECT jsonb_agg(
                      jsonb_build_object(
                        'id', r.id,
                        'name', r.name,
                        'slug', r.slug,
                        'owner_id', r.owner_id,
                        'plan_id', r.plan_id,
                        'phone', r.phone,
                        'address', r.address,
                        'location', CASE WHEN r.location IS NOT NULL THEN ST_AsGeoJSON(r.location)::jsonb ELSE NULL END,
                        'is_active', r.is_active,
                        'created_at', r.created_at,
                        'updated_at', r.updated_at,
                        'settings', r.settings_json,
                        'members', COALESCE(r.members_json, '[]'::jsonb),
                        'subscriptions', COALESCE(r.subscriptions_json, '[]'::jsonb),
                        'tags', COALESCE(r.tags_json, '[]'::jsonb),
                        'branches', COALESCE(r.branches_json, '[]'::jsonb)
                      )
                    )
                    FROM restaurants_data r
    ),
    'plans', (SELECT jsonb_agg(to_jsonb(p)) FROM plans p),
    'templates', (SELECT jsonb_agg(to_jsonb(t)) FROM templates t),
    'global_roles', (SELECT jsonb_agg(to_jsonb(gr)) FROM global_roles gr),
    'category_types', (SELECT jsonb_agg(to_jsonb(ct)) FROM category_types ct),
    'tags', (SELECT jsonb_agg(to_jsonb(tg)) FROM tags tg)
  )
) AS full_database_json;