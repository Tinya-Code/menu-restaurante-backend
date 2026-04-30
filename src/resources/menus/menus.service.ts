import { Injectable, Logger, NotFoundException } from '@nestjs/common';
import { DatabaseService } from '../../config/database/database.service';
import { FullMenuResponseDto, MenuResponseDto } from './dto';

@Injectable()
export class MenusService {
  private readonly logger = new Logger(MenusService.name);

  constructor(private readonly db: DatabaseService) {}

  async findByBranchId(branchId: string): Promise<MenuResponseDto[]> {
    this.logger.log(`Finding menus for branch: ${branchId}`);

    const res = await this.db.query(
      'SELECT id, branch_id, name, description, display_order, is_active, created_at, updated_at FROM menus WHERE branch_id = $1 AND is_active = true ORDER BY display_order ASC',
      [branchId],
    );
    return res.rows;
  }

  async findFullMenu(menuId: string): Promise<FullMenuResponseDto[]> {
    this.logger.log(`Finding full menu: ${menuId}`);

    // Verificar que el menú existe
    const menuExists = await this.db.query('SELECT id FROM menus WHERE id = $1', [
      menuId,
    ]);
    if (menuExists.rows.length === 0) {
      throw new NotFoundException(`Menu with ID ${menuId} not found`);
    }

    // Obtener categorías con productos y restaurant_id
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
        c.updated_at,
        r.id as restaurant_id,
        COALESCE(
          json_agg(
            json_build_object(
              'id', p.id,
              'branch_id', p.branch_id,
              'category_id', p.category_id,
              'name', p.name,
              'description', p.description,
              'price', p.price,
              'image_url', p.image_url,
              'cloudinary_id', p.cloudinary_id,
              'is_available', p.is_available,
              'is_recommended', p.is_recommended,
              'created_at', p.created_at,
              'updated_at', p.updated_at
            ) ORDER BY p.created_at ASC
          ) FILTER (WHERE p.id IS NOT NULL),
          '[]'
        ) as products
      FROM categories c
      LEFT JOIN category_types t ON c.type_id = t.id
      LEFT JOIN menus m ON c.menu_id = m.id
      LEFT JOIN branches b ON m.branch_id = b.id
      LEFT JOIN restaurants r ON b.restaurant_id = r.id
      LEFT JOIN products p ON p.category_id = c.id AND p.is_available = true
      WHERE c.menu_id = $1 AND c.is_active = true
      GROUP BY c.id, t.name, r.id
      ORDER BY c.display_order ASC`,
      [menuId],
    );

    // Transformar al formato que espera el frontend
    const formattedData = result.rows.map((row) => ({
      category: {
        id: row.id,
        menu_id: row.menu_id,
        name: row.name,
        description: row.description,
        type: row.type,
        display_order: row.display_order,
        is_active: row.is_active,
        created_at: row.created_at,
        updated_at: row.updated_at,
        restaurant_id: row.restaurant_id,
      },
      products: row.products,
    }));

    return formattedData;
  }
}
