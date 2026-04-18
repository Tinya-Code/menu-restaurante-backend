import { Injectable } from '@nestjs/common';
import { DatabaseService } from '../../config/database/database.service';

@Injectable()
export class CategoriesService {
  constructor(private readonly db: DatabaseService) {}

  async findByMenuId(menuId: string) {
    const res = await this.db.query(
      'SELECT id, name, description, display_order, type_id FROM categories WHERE menu_id = $1 AND is_active = true ORDER BY display_order ASC',
      [menuId],
    );
    return res.rows;
  }
}
