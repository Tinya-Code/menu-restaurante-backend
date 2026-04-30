import { ApiProperty } from '@nestjs/swagger';

export class ProductResponseDto {
  @ApiProperty({ description: 'Product ID', example: '550e8400-e29b-41d4-a716-446655440013' })
  id: string;

  @ApiProperty({ description: 'Branch ID', example: '550e8400-e29b-41d4-a716-446655440003' })
  branch_id: string;

  @ApiProperty({ description: 'Category ID', example: '550e8400-e29b-41d4-a716-446655440006' })
  category_id: string;

  @ApiProperty({ description: 'Product name', example: 'Tequeños Crujientes' })
  name: string;

  @ApiProperty({
    description: 'Product description',
    example: 'Con salsa de palta especial.',
    nullable: true,
  })
  description: string | null;

  @ApiProperty({ description: 'Product price', example: 16.0 })
  price: number;

  @ApiProperty({
    description: 'Image URL',
    example: null,
    nullable: true,
  })
  image_url: string | null;

  @ApiProperty({
    description: 'Cloudinary public ID for image management',
    example: null,
    nullable: true,
  })
  cloudinary_id: string | null;

  @ApiProperty({
    description: 'Whether the product is available',
    example: true,
  })
  is_available: boolean;

  @ApiProperty({
    description: 'Whether the product is recommended',
    example: true,
  })
  is_recommended: boolean;

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
}
