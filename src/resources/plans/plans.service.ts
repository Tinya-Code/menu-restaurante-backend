import { Injectable } from '@nestjs/common';
import { DatabaseService } from '../../config/database/database.service';

@Injectable()
export class PlansService {
  constructor(private readonly db: DatabaseService) {}

  async findAll() {
    const res = await this.db.query(
      'SELECT id, name, description, price, max_branches, max_products, max_categories, max_banners, max_combos, max_promotions, features FROM plans WHERE is_active = true ORDER BY price ASC',
    );
    return res.rows;
  }

  async findOne(id: string) {
    const res = await this.db.query('SELECT * FROM plans WHERE id = $1', [id]);
    return res.rows[0];
  }
}
