import { Injectable, Logger, NotFoundException } from '@nestjs/common';
import { DatabaseService } from '../../config/database/database.service';
import { ProductResponseDto } from './dto';

@Injectable()
export class ProductsService {
  private readonly logger = new Logger(ProductsService.name);

  constructor(private readonly db: DatabaseService) {}

  async findByCategoryId(categoryId: string): Promise<ProductResponseDto[]> {
    this.logger.log(`Finding products for category: ${categoryId}`);

    // Verify category exists
    const categoryExists = await this.db.query(
      'SELECT id FROM categories WHERE id = $1',
      [categoryId],
    );
    if (categoryExists.rows.length === 0) {
      throw new NotFoundException(`Category with ID ${categoryId} not found`);
    }

    const res = await this.db.query(
      'SELECT id, branch_id, category_id, name, description, price, image_url, cloudinary_id, is_available, is_recommended, created_at, updated_at FROM products WHERE category_id = $1 AND is_available = true ORDER BY name ASC',
      [categoryId],
    );
    return res.rows;
  }
}
