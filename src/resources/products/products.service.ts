import { Injectable } from '@nestjs/common';
import { DatabaseService } from '../../config/database/database.service';

@Injectable()
export class ProductsService {
  constructor(private readonly db: DatabaseService) {}

  async findByCategoryId(categoryId: string) {
    const res = await this.db.query(
      'SELECT id, name, description, price, image_url, cloudinary_id, is_available, is_recommended FROM products WHERE category_id = $1 AND is_available = true ORDER BY name ASC',
      [categoryId],
    );
    return res.rows;
  }
}
