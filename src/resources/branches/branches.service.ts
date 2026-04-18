import { Injectable } from '@nestjs/common';
import { DatabaseService } from '../../config/database/database.service';

@Injectable()
export class BranchesService {
  constructor(private readonly db: DatabaseService) {}

  async findByRestaurantId(restaurantId: string) {
    const res = await this.db.query(
      `SELECT id, name, slug, phone, address, location, is_main, is_active, template_id
       FROM branches 
       WHERE restaurant_id = $1 AND is_active = true 
       ORDER BY is_main DESC, created_at ASC`,
      [restaurantId],
    );
    return res.rows;
  }

  async findOne(id: string) {
    const res = await this.db.query(
      'SELECT * FROM branches WHERE id = $1',
      [id],
    );
    return res.rows[0];
  }
}
