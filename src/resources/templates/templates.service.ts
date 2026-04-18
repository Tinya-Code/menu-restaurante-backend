import { Injectable } from '@nestjs/common';
import { DatabaseService } from '../../config/database/database.service';

@Injectable()
export class TemplatesService {
  constructor(private readonly db: DatabaseService) {}

  async findAll() {
    const res = await this.db.query(
      'SELECT id, plan_id, slug, name, description, preview_url, config FROM templates WHERE is_active = true',
    );
    return res.rows;
  }

  async findOne(id: string) {
    const res = await this.db.query('SELECT * FROM templates WHERE id = $1', [id]);
    return res.rows[0];
  }
}
