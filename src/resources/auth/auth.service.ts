import { Injectable, ConflictException, ServiceUnavailableException } from '@nestjs/common';
import { DatabaseService } from '../../config/database/database.service';
import { RegisterDto } from './dto/register.dto';

@Injectable()
export class AuthService {
  constructor(
    private readonly db: DatabaseService,
  ) {}

  async register(authData: { uid: string; email: string }, dto: RegisterDto) {
    const { uid, email } = authData;
    const client = await this.db.getClient();

    try {
      await client.query('BEGIN');

      // 1. Check if user already exists
      const userCheck = await client.query('SELECT id FROM users WHERE firebase_uid = $1 OR email = $2', [uid, email]);
      if (userCheck.rows.length > 0) {
        throw new ConflictException('User already registered');
      }

      // 2. Insert User
      const userRes = await client.query(
        'INSERT INTO users (firebase_uid, email, phone, display_name) VALUES ($1, $2, $3, $4) RETURNING id',
        [uid, email, dto.phone, dto.display_name],
      );
      const userId = userRes.rows[0].id;

      // 3. Get Default Plan (Free)
      const planRes = await client.query("SELECT id FROM plans WHERE name = 'Free' LIMIT 1");
      if (planRes.rows.length === 0) {
        throw new ServiceUnavailableException('Default plan not found in database');
      }
      const planId = planRes.rows[0].id;

      // 4. Insert Restaurant
      // El trigger 'trg_bootstrap_restaurant' automáticamente:
      // - Crea la sucursal 'Sucursal Principal' (la cual dispara a su vez 'trg_bootstrap_branch')
      // - El trigger de la sucursal crea un 'branch_settings' default y el 'Menú Principal'
      // - Define al usuario localmente en 'restaurant_members'
      // - Actualiza 'users.active_context = owner'
      // - Crea una suscripción por defecto con base en free.
      const restaurantRes = await client.query(
        `INSERT INTO restaurants (name, slug, owner_id, plan_id, phone, address, location) 
         VALUES ($1, $2, $3, $4, $5, $6, ST_SetSRID(ST_MakePoint($7, $8), 4326)) 
         RETURNING id, slug`,
        [dto.restaurant_name, dto.slug, userId, planId, dto.phone_restaurant, dto.address, dto.lng, dto.lat],
      );
      const restaurantId = restaurantRes.rows[0].id;

      // 5. Explicitly sync the Main Branch data & GET BRANCH ID
      // Forzamos que la configuración regional básica se aplique al branch que originó el boot y sacamos su ID.
      const branchRes = await client.query(
        `UPDATE branches 
         SET phone = $2, address = $3, location = ST_SetSRID(ST_MakePoint($4, $5), 4326)
         WHERE restaurant_id = $1 AND is_main = true
         RETURNING id`,
        [restaurantId, dto.phone_restaurant, dto.address, dto.lng, dto.lat],
      );
      const branchId = branchRes.rows[0].id;

      // 6. Update implicit branch_settings
      // Inyectamos el teléfono de registro en la configuración de whatsapp para alinear el order_config nativo.
      if (dto.phone_restaurant) {
        await client.query(
          `UPDATE branch_settings 
           SET whatsapp_config = jsonb_set(whatsapp_config, '{number}', to_jsonb($2::text))
           WHERE branch_id = $1`,
          [branchId, dto.phone_restaurant],
        );
      }

      await client.query('COMMIT');

      return {
        success: true,
        message: 'Registro completado exitosamente',
        data: {
          user_id: userId,
          restaurant_id: restaurantId,
          branch_id: branchId,
          slug: restaurantRes.rows[0].slug,
        },
        redirect_url: '/dashboard',
      };
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally {
      client.release();
    }
  }
}
