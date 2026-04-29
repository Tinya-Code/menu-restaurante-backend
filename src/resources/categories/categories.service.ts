import { Injectable, Logger, NotFoundException } from '@nestjs/common';
import { DatabaseService } from '../../config/database/database.service';
import { CategoryResponseDto } from './dto/category-response.dto';

@Injectable()
export class CategoriesService {
  private readonly logger = new Logger(CategoriesService.name);

  constructor(private readonly db: DatabaseService) {}

  async findByMenuId(menuId: string): Promise<CategoryResponseDto[]> {
    this.logger.log(`Finding categories for menu: ${menuId}`);

    // Verify menu exists
    const menuExists = await this.db.query(
      'SELECT id FROM menus WHERE id = $1',
      [menuId],
    );
    if (menuExists.rows.length === 0) {
      throw new NotFoundException(`Menu with ID ${menuId} not found`);
    }

    const result = await this.db.query(
      `SELECT 
        c.id,
        c.menu_id,
        c.name,
        c.description,
        t.name as type,
        c.display_order,
        c.is_active,
        c.created_at,
        c.updated_at
      FROM categories c
      LEFT JOIN category_types t ON c.type_id = t.id
      WHERE c.menu_id = $1 AND c.is_active = true
      ORDER BY c.display_order ASC, c.name ASC`,
      [menuId],
    );

    return result.rows;
  }

  async findById(id: string): Promise<CategoryResponseDto> {
    this.logger.log(`Finding category by ID: ${id}`);

    const result = await this.db.query(
      `SELECT 
        c.id,
        c.menu_id,
        c.name,
        c.description,
        t.name as type,
        c.display_order,
        c.is_active,
        c.created_at,
        c.updated_at
      FROM categories c
      LEFT JOIN category_types t ON c.type_id = t.id
      WHERE c.id = $1 AND c.is_active = true`,
      [id],
    );

    if (result.rows.length === 0) {
      throw new NotFoundException(`Category with ID ${id} not found`);
    }

    return result.rows[0];
  }
}
