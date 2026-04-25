export class Category {
  id: string;
  restaurant_id: string;
  menu_id: string;
  name: string;
  description: string | null;
  type: string;
  display_order: number;
  is_active: boolean;
  created_at: string;
  updated_at: string;
}
