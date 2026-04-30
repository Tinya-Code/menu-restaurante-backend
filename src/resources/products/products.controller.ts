import {
  Controller,
  Get,
  HttpException,
  HttpStatus,
  Logger,
  Param,
} from '@nestjs/common';
import { ApiOperation, ApiParam, ApiResponse, ApiTags } from '@nestjs/swagger';
import { ApiResponseDto } from '../../common/dto/api-response.dto';
import { ProductsService } from './products.service';
import { ProductResponseDto } from './dto';

@ApiTags('Products')
@Controller('products')
export class ProductsController {
  private readonly logger = new Logger(ProductsController.name);

  constructor(private readonly productsService: ProductsService) {}

  @Get('category/:categoryId')
  @ApiOperation({
    summary: 'Get products by category ID',
    description: 'Retrieves all available products for a specific category',
  })
  @ApiParam({
    name: 'categoryId',
    type: String,
    description: 'ID of the category to get products from',
  })
  @ApiResponse({
    status: 200,
    description: 'Products retrieved successfully',
    type: ApiResponseDto<ProductResponseDto[]>,
  })
  @ApiResponse({
    status: 404,
    description: 'Category not found',
    schema: {
      example: {
        success: false,
        message: 'Category not found',
        timestamp: '2026-02-28T03:28:24.097Z',
      },
    },
  })
  @ApiResponse({
    status: 500,
    description: 'Internal server error',
    schema: {
      example: {
        success: false,
        message: 'Error retrieving products',
        timestamp: '2026-02-28T03:28:24.097Z',
      },
    },
  })
  async findByCategoryId(
    @Param('categoryId') categoryId: string,
  ): Promise<ApiResponseDto<ProductResponseDto[]>> {
    try {
      this.logger.log(`Getting products for category: ${categoryId}`);
      const products =
        await this.productsService.findByCategoryId(categoryId);
      return new ApiResponseDto(
        true,
        'Products retrieved successfully',
        products,
      );
    } catch (error) {
      if (error instanceof HttpException) {
        throw error;
      }
      this.logger.error('Error retrieving products', error);
      throw new HttpException(
        {
          success: false,
          message: 'Error retrieving products',
          timestamp: new Date().toISOString(),
        },
        HttpStatus.INTERNAL_SERVER_ERROR,
      );
    }
  }
}
