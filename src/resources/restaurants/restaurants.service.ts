import { Injectable, NotFoundException } from '@nestjs/common';
import { DatabaseService } from '../../config/database/database.service';
import { MenusService } from '../menus/menus.service';
import { CategoriesService } from '../categories/categories.service';
import { ProductsService } from '../products/products.service';
import { BranchesService } from '../branches/branches.service';
import { BannersService } from '../banners/banners.service';

@Injectable()
export class RestaurantsService {
  constructor(
    private readonly db: DatabaseService,
    private readonly menusService: MenusService,
    private readonly categoriesService: CategoriesService,
    private readonly productsService: ProductsService,
    private readonly branchesService: BranchesService,
    private readonly bannersService: BannersService,
  ) {}

  async findOneBySlugFull(slug: string) {
    // 1. Basic info and settings
    const restaurantRes = await this.db.query(
      `SELECT r.id, r.name, r.slug, r.phone, r.address, r.plan_id,
              s.whatsapp_config, s.display_config, s.order_config, s.business_config, s.logo_url, s.description
       FROM restaurants r
       LEFT JOIN restaurant_settings s ON r.id = s.restaurant_id
       WHERE r.slug = $1 AND r.is_active = true`,
      [slug],
    );

    if (restaurantRes.rows.length === 0) {
      throw new NotFoundException(`Restaurant with slug ${slug} not found`);
    }

    const restaurant = restaurantRes.rows[0];

    // 2. Fetch Plan
    const planRes = await this.db.query('SELECT name, features FROM plans WHERE id = $1', [restaurant.plan_id]);
    restaurant.plan = planRes.rows[0] || null;

    // 3. Fetch Branches
    const branches = await this.branchesService.findByRestaurantId(restaurant.id);
    restaurant.branches = branches;

    // 4. Focus on Main Branch for nested data (for now)
    const mainBranch = branches.find((b) => b.is_main) || branches[0];

    if (mainBranch) {
      // Fetch Template for main branch
      const templatesRes = await this.db.query(
        'SELECT name, config FROM templates WHERE id = $1',
        [mainBranch.template_id],
      );
      restaurant.template = templatesRes.rows[0] || null;

      // Fetch Banners for main branch
      restaurant.banners = await this.bannersService.findByBranchId(mainBranch.id);

      // 3. Menus -> Categories -> Products nested structure for main branch
      const menus = await this.menusService.findByBranchId(mainBranch.id);

      for (const menu of menus) {
        const categories = await this.categoriesService.findByMenuId(menu.id);
        for (const category of categories) {
          category.products = await this.productsService.findByCategoryId(category.id);
        }
        menu.categories = categories;
      }
      restaurant.menus = menus;
    }

    return restaurant;
  }

  async getLocationBySlug(slug: string) {
    const res = await this.db.query(
      'SELECT ST_X(location::geometry) as lng, ST_Y(location::geometry) as lat FROM restaurants WHERE slug = $1 AND is_active = true',
      [slug],
    );

    if (res.rows.length === 0) {
      throw new NotFoundException(`Restaurant with slug ${slug} not found`);
    }

    return res.rows[0];
  }
}
