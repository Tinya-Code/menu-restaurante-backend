import { ApiProperty } from '@nestjs/swagger';
import { CategoryResponseDto } from '../../categories/dto';
import { ProductResponseDto } from '../../products/dto';

export class MenuResponseDto {
  @ApiProperty({ description: 'Menu ID', example: '550e8400-e29b-41d4-a716-446655440005' })
  id: string;

  @ApiProperty({ description: 'Branch ID', example: '550e8400-e29b-41d4-a716-446655440003' })
  branch_id: string;

  @ApiProperty({ description: 'Menu name', example: 'Carta General' })
  name: string;

  @ApiProperty({
    description: 'Menu description',
    example: null,
    nullable: true,
  })
  description: string | null;

  @ApiProperty({ description: 'Display order for sorting', example: 0 })
  display_order: number;

  @ApiProperty({ description: 'Whether the menu is active', example: true })
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
    description: 'List of categories in this menu (populated dynamically)',
    type: [CategoryResponseDto],
    required: false,
  })
  categories?: CategoryResponseDto[];
}

export class FullMenuResponseDto {
  @ApiProperty({
    description: 'Category information',
    type: CategoryResponseDto,
  })
  category: CategoryResponseDto;

  @ApiProperty({
    description: 'Products in this category',
    type: [ProductResponseDto],
  })
  products: ProductResponseDto[];
}
