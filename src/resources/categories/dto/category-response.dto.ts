import { ApiProperty } from '@nestjs/swagger';
import { ProductResponseDto } from '../../products/dto';

export class CategoryResponseDto {
  @ApiProperty({
    description: 'Unique identifier for the category',
    example: 'cat-entradas-1',
  })
  id: string;

  @ApiProperty({
    description: 'ID of the restaurant this category belongs to',
    example: 'res-uuid-1',
  })
  restaurant_id: string;

  @ApiProperty({
    description: 'ID of the menu this category belongs to',
    example: 'menu-uuid-1',
  })
  menu_id: string;

  @ApiProperty({ description: 'Name of the category', example: 'Entradas' })
  name: string;

  @ApiProperty({
    description: 'Description of the category',
    example: null,
    nullable: true,
  })
  description: string | null;

  @ApiProperty({ description: 'Type of the category', example: 'entrada' })
  type: string;

  @ApiProperty({ description: 'Display order for sorting', example: 0 })
  display_order: number;

  @ApiProperty({ description: 'Whether the category is active', example: true })
  is_active: boolean;

  @ApiProperty({
    description: 'Creation timestamp',
    example: '2026-02-28T03:28:24.097231+00:00',
  })
  created_at: string;

  @ApiProperty({
    description: 'Last update timestamp',
    example: '2026-02-28T03:28:24.097231+00:00',
  })
  updated_at: string;

  @ApiProperty({
    description: 'List of products in this category (populated dynamically)',
    type: [ProductResponseDto],
    required: false,
  })
  products?: ProductResponseDto[];
}
