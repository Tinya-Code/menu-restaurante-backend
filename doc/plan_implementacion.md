# Plan de Implementación: API de Restaurante (PRO)

Este plan detalla la estructura de la API para la consulta de datos de restaurantes, menús y la lógica crítica de registro.

## 1. Configuración Inicial
- [x] Configuración de variables de entorno (`.env`).
- [x] Conexión a base de datos (`DatabaseModule`).
- [x] Inicialización de Firebase Admin SDK.

## 2. Módulo de Autenticación y Registro (`auth`) [ALTA PRIORIDAD]
Este módulo maneja la creación de la cuenta de usuario y el restaurante inicial en un solo flujo atómico.

### `POST /resources/auth/register`
- **Descripción**: Valida el token de Firebase, crea el usuario y su restaurante asociado.
- **Seguridad**: Se debe enviar el `Bearer <id_token>` en el header `Authorization`.
- **Entrada (Body)**:
  ```json
  {
    "display_name": "Alejandro Pérez",
    "phone": "987654321",
    "restaurant_name": "La Pizzería Gourmet",
    "address": "Av. Larco 123",
    "phone_restaurant": "014445566",
    "lat": -12.123456,
    "lng": -77.012345,
    "slug": "la-pizzeria-gourmet"
  }
  ```
- **Lógica Interna**:
  1. **Validación Firebase**: Extraer `uid` y `email` del token del header.
  2. **Usuario**: Insertar en la tabla `users`.
  3. **Restaurante**: Insertar en la tabla `restaurants` vinculando al `owner_id`. El trigger `fn_bootstrap_restaurant` creará automáticamente la sucursal principal ("Sucursal Principal") y la configuración inicial (`branch_settings`).
  4. **Plan**: Se asigna por defecto el plan 'Free'.
  5. **Sincronización de Sucursal**: Se actualizan los datos específicos de la sucursal principal (`branches`) con los del formulario (`phone`, `address` y `location` mediante `GEOGRAPHY`).
  6. **Sincronización de Ajustes**: Se inyecta el `phone_restaurant` dentro de la propiedad nativa de `whatsapp_config.number` en el `branch_settings` creado.
- **Salida (201 Created)**:
  ```json
  {
    "success": true,
    "message": "Registro completado exitosamente",
    "data": {
      "user_id": "uuid",
      "restaurant_id": "uuid",
      "branch_id": "uuid",
      "slug": "la-pizzeria-gourmet"
    },
    "redirect_url": "/dashboard"
  }
  ```

---

## 3. Módulos de Consulta y Endpoints

### A. Módulo de Restaurantes (`restaurants`)
#### `GET /resources/restaurants/:slug/full`
- **Descripción**: Retorno masivo de info para el perfil del restaurante.
- **Contenido**: Info básica + Configuración completa + Menús con Categorías y Productos anidados.
- **Regla**: Solo traer productos con `is_available = true`.

#### `GET /resources/restaurants/:slug/location`
- **Descripción**: Geo-ubicación específica.
- **Salida**: `{ "lat": number, "lng": number }`

### B. Módulo de Banners (`banners`)
#### `GET /resources/banners/restaurant/:id`
- **Descripción**: Banners activos ordenados por `display_order`.

### C. Módulo de Planes (`plans`) [Fuente: db/db.sql]
#### `GET /resources/plans`
- **Descripción**: Lista los planes según la tabla `plans` (Gratis, Premium, etc.).
- **Atributos**: ID, nombre, precio, límites (max_restaurants, max_products), etc.

---

## 4. Arquitectura de Servicios
- Los servicios de `categories` y `products` deben permitir filtros por `restaurant_id` y `is_active`.
- El `RestaurantsService` agregará los datos de los otros servicios para la respuesta `/full`.
