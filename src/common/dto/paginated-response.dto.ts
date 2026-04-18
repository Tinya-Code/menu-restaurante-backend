import { ApiProperty } from '@nestjs/swagger';

export class PaginationMetadata {
  @ApiProperty({ description: 'Total number of items' })
  totalItems: number;

  @ApiProperty({ description: 'Number of items per page' })
  itemCount: number;

  @ApiProperty({ description: 'Items per page' })
  itemsPerPage: number;

  @ApiProperty({ description: 'Total number of pages' })
  totalPages: number;

  @ApiProperty({ description: 'Current page number' })
  currentPage: number;
}

export class PaginatedResponseDto<T> {
  @ApiProperty({ description: 'List of items for the current page', isArray: true })
  items: T[];

  @ApiProperty({ description: 'Pagination metadata' })
  meta: PaginationMetadata;
}
