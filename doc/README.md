# Schema v4 — SaaS Multi-Restaurante con Sucursales

## Orden de ejecución

Los archivos deben ejecutarse en orden numérico. Cada uno depende del anterior.

```
00_extensions.sql        → Extensiones de PostgreSQL + fn_set_updated_at()
01_tables.sql            → Todas las tablas + datos de catálogo (planes, templates, roles)
02_indexes.sql           → Índices de todas las tablas
03_triggers_plan_limits.sql → Triggers BEFORE INSERT para límites de plan
04_triggers_bootstrap.sql   → Triggers AFTER INSERT para creación en cascada
05_functions.sql         → Funciones de utilidad de la app
06_views.sql             → Vistas
07_seed.sql              → Datos de prueba (solo desarrollo)
08_queries.sql           → Consultas de verificación (solo desarrollo)
```

En psql:
```bash
psql -d tu_base -f 00_extensions.sql
psql -d tu_base -f 01_tables.sql
psql -d tu_base -f 02_indexes.sql
psql -d tu_base -f 03_triggers_plan_limits.sql
psql -d tu_base -f 04_triggers_bootstrap.sql
psql -d tu_base -f 05_functions.sql
psql -d tu_base -f 06_views.sql
psql -d tu_base -f 07_seed.sql       # solo desarrollo
psql -d tu_base -f 08_queries.sql    # solo desarrollo
```

---

## Descripción de archivos

### `00_extensions.sql`
- `pg_trgm` — búsqueda por trigramas (GIN)
- `postgis` — tipos y funciones geoespaciales
- `btree_gist` — necesario para EXCLUDE en branches
- `fn_set_updated_at()` — función global usada por todos los triggers de timestamp

### `01_tables.sql`
Todas las tablas en orden de dependencias. Incluye triggers `updated_at` y datos de catálogo iniciales:
- Roles globales: `super_admin`, `developer`, `support`
- Planes: `Free`, `Starter`, `Pro` con sus límites
- Templates por defecto: `polleria`, `chifa`, `cevicheria`, `comida-rapida`

### `02_indexes.sql`
Índices optimizados para las consultas más frecuentes:
- Búsqueda de texto por trigramas (GIN) en `restaurants.name`, `categories.name`, `products.name`
- Índices geoespaciales (GIST) en `branches.location` y `restaurant_visits.user_location`
- Índices parciales donde aplica (ej. solo filas con `firebase_uid NOT NULL`)

### `03_triggers_plan_limits.sql`
Enforcement de límites de plan a nivel de base de datos (doble seguro junto con la app):
- `branch_within_plan_limit(branch_id, resource)` → verifica banners/combos/promotions/products
- `restaurant_within_branch_limit(restaurant_id)` → verifica cantidad de sucursales
- Triggers `BEFORE INSERT` en `banners`, `combos`, `promotions` y `branches`
- Si se supera el límite: `RAISE EXCEPTION 'PLAN_LIMIT_EXCEEDED: ...'`

### `04_triggers_bootstrap.sql`
Creación automática en cascada al insertar un restaurante o sucursal:

**Al insertar en `restaurants`:**
1. Crea `restaurant_settings` con defaults JSONB estructurados
2. Crea `branches` (Sucursal Principal) → dispara bootstrap de branch
3. Crea `restaurant_members` (owner)
4. Actualiza `users.active_context` a `'owner'`
5. Crea `subscriptions` (trial 14 días)

**Al insertar en `branches`:**
1. Crea `branch_settings` (vacía, hereda del restaurante)
2. Crea `menus` (Menú Principal)

### `05_functions.sql`
Funciones de utilidad:

| Función | Descripción |
|---|---|
| `get_effective_settings(branch_id)` | Config fusionada restaurant + branch |
| `get_branch_data(branch_id)` | JSON completo para la app cliente |
| `user_has_access(user_id, restaurant_id, roles[])` | Verificación de permisos |
| `fn_transfer_ownership(restaurant_id, new_owner_id)` | Transferir restaurante |
| `fn_change_plan(restaurant_id, new_plan_id)` | Cambiar plan con historial |
| `fn_register_visit(...)` | Registrar visita de comensal |

### `06_views.sql`

| Vista | Descripción |
|---|---|
| `v_restaurants_overview` | Resumen con plan, suscripción y sucursales |
| `v_plan_usage` | Recursos usados vs límites del plan por sucursal |
| `v_user_permissions` | Permisos globales y locales por usuario |
| `v_visit_history` | Historial de visitas de comensales |
| `v_menu_full` | Menú desnormalizado (reporting) |
| `v_combos_full` | Combos con productos detallados |
| `v_active_promotions` | Promociones vigentes filtradas por fecha |

### `07_seed.sql`
Datos de prueba que demuestran:
- Creación de restaurante con bootstrap completo
- Distinción entre contexto `owner` y `visitor` en el mismo usuario
- Registro de visitas de comensales con geolocalización
- Template asignado por sucursal

### `08_queries.sql`
Consultas de verificación con ejemplos comentados de:
- Cambio de plan (`fn_change_plan`)
- Transferencia de ownership (`fn_transfer_ownership`)
- Verificación de límites del plan

---

## Contextos de usuario

Un mismo usuario puede ser dueño de su restaurante y comensal en otro simultáneamente. El campo `users.active_context` indica qué interfaz muestra la app:

| Contexto | Interfaz |
|---|---|
| `owner` | Dashboard de gestión del restaurante |
| `visitor` | Explorador de restaurantes como comensal |

El usuario cambia de contexto desde la app. La DB no restringe esto — es responsabilidad de la UI mostrar la interfaz correcta según el contexto activo.

## Roles internos vs comensales

| Tabla | Quién va aquí |
|---|---|
| `restaurant_members` | `owner`, `admin`, `staff` — gestión interna |
| `restaurant_visits` | Comensales — interacciones externas con el restaurante |

Un usuario puede estar en ambas tablas para distintos restaurantes sin conflicto.
