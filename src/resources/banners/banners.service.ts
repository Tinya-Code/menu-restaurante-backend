import { Injectable } from '@nestjs/common';
import { DatabaseService } from '../../config/database/database.service';

@Injectable()
export class BannersService {
  constructor(private readonly db: DatabaseService) {}

  async findByBranchId(branchId: string) {
    const res = await this.db.query(
      'SELECT id, image_url, description, display_order FROM banners WHERE branch_id = $1 AND is_active = true ORDER BY display_order ASC',
      [branchId],
    );
    return res.rows;
  }
}
